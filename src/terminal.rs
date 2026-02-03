use std::process::Stdio;

use anyhow::Context;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{ChildStdin, Command};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

#[derive(Clone)]
pub struct Terminal {
    stdin_tx: UnboundedSender<String>,
}

impl Terminal {
    pub fn open() -> anyhow::Result<(Self, UnboundedReceiver<Vec<u8>>)> {
        let mut command = Command::new("zsh")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let stdin = command.stdin.take().context("stdin is nill")?;
        let stdout = command.stdout.take().context("stdout is nill")?;
        let stderr = command.stderr.take().context("stderr is nill")?;

        let (stdout_tx, stdout_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let (stdin_tx, stdin_rx) = tokio::sync::mpsc::unbounded_channel::<String>();

        tokio::spawn(Self::writer_listener(stdin, stdin_rx));

        tokio::spawn(Self::reader_listener(
            stdout,
            stdout_tx.clone(),
            "stdout",
        ));
        tokio::spawn(Self::reader_listener(
            stderr,
            stdout_tx.clone(),
            "stderr",
        ));

        Ok((Terminal { stdin_tx }, stdout_rx))
    }

    pub async fn write(&self, input: &str) {
        let result = self.stdin_tx
            .send(input.to_string());
        if let Err(e) = result {
            tracing::error!("Failed to send input to terminal: {}", e);
        }
    }

    async fn writer_listener(
        mut stdin: ChildStdin,
        mut in_rx: UnboundedReceiver<String>,
    ) {
        while let Some(input) = in_rx.recv().await {
            if let Err(e) = stdin.write_all(format!("{}\n", input).as_bytes()).await {
                tracing::error!("Failed to write to terminal stdin: {}", e);
                continue;
            }
            if let Err(e) = stdin.flush().await {
                tracing::error!("Failed to flush terminal stdin: {}", e);
                continue;
            }
        }
    }

    async fn reader_listener<R>(
        mut reader: R,
        out_tx: UnboundedSender<Vec<u8>>,
        name: &'static str,
    ) where
        R: AsyncRead + Unpin,
    {
        tracing::info!("Starting {} reader...", name);
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf).await {
                Ok(0) => {
                    tracing::info!("{} reader finished", name);
                    break;
                }
                Err(e) => {
                    tracing::error!("Error reading from {}: {}", name, e);
                    break;
                }
                Ok(n) => {
                    tracing::debug!("Read {} bytes from {}", n, name);
                    let _ = out_tx.send(buf[..n].to_vec());
                }
            }
        }
    }
}
