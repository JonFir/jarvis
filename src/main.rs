use std::process::exit;

use std::env;
use teloxide::prelude::*;
use tracing_subscriber::EnvFilter;

mod terminal;

#[tokio::main]
async fn main() {
    {
        let file_name = env::var("HOME").unwrap_or_default();
        let file_name = format!("{file_name}/.jarvisbot.env");
        if let Err(e) = dotenvy::from_filename(&file_name) {
            tracing::error!("Failed to load config at path {}. Error - {}", file_name, e);
            exit(1);
        }
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .init();

    let Ok(token) = env::var("BOT_TOKEN") else {
        tracing::error!("BOT_TOKEN environment variable not set");
        exit(1)
    };
    let Ok(chat_id) = env::var("CHAT_ID").map(|s| s.parse::<i64>().unwrap()) else {
        tracing::error!("CHAT_ID environment variable not set or invalid");
        exit(1)
    };
    let chat_id = ChatId(chat_id);
    
    let bot = Bot::new(token);
    let (terminal, terminal_rx) = match terminal::Terminal::open() {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("Failed to open terminal: {}", e);
            exit(1)
        }
    };
    

    tokio::spawn(listen_stdout(bot.clone(), terminal_rx, chat_id));
    tracing::info!("Starting long-polling bot...");
    Dispatcher::builder(bot, Update::filter_message().endpoint(echo))
        .dependencies(teloxide::dptree::deps![terminal, chat_id])
        .build()
        .dispatch()
        .await;
}

async fn echo(_: Bot, msg: Message, terminal: terminal::Terminal, chat_id: ChatId) -> ResponseResult<()> {
    if chat_id != msg.chat.id {
        tracing::warn!("Received message from unknown chat: {})", msg.chat.id);
        return Ok(());
    }
    
    let Some(text) = msg.text() else {
        tracing::warn!("Received non-text message");
        return Ok(());
    };
    tracing::debug!("Received message {:?}", text);
    terminal.write(text).await;
    Ok(())
}

async fn listen_stdout(
    bot: Bot,
    mut terminal_rx: tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>,
    chat_id: ChatId,
) {
    tracing::info!("Terminal forwarder started");
    while let Some(bytes) = terminal_rx.recv().await {
        tracing::debug!("Terminal output received: {} bytes", bytes.len());
        let text = String::from_utf8_lossy(&bytes);
        if let Err(err) = bot.send_message(chat_id, text.as_ref()).await {
            tracing::error!("Failed to send message: {}", err);
        }
    }
}
