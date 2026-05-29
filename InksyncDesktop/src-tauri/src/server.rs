use axum::{
    routing::get,
    Router,
    extract::{ws::{WebSocket, WebSocketUpgrade, Message}, State},
    response::{IntoResponse, Response},
    Json,
};
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::cors::CorsLayer;
use serde::Serialize;
use std::path::PathBuf;

#[derive(Clone)]
pub struct ServerState {
    pub library_dir: PathBuf,
    pub db_path: PathBuf,
}

pub async fn start_server(port: u16, state: ServerState) {
    let app = Router::new()
        .route("/opds", get(serve_opds))
        .route("/sync", get(ws_handler))
        .route("/api/books", get(list_books))
        .with_state(Arc::new(state))
        .layer(CorsLayer::permissive());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("Web Server: Listening on {}", addr);
    
    // Launch server in background tokio loop
    tokio::spawn(async move {
        axum::Server::bind(&addr)
            .serve(app.into_make_service())
            .await
            .unwrap();
    });
}

async fn serve_opds(State(_state): State<Arc<ServerState>>) -> impl IntoResponse {
    // Generate a simple OPDS XML Catalog Feed
    let xml = r#"<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:uuid:inksyncdesktop-catalog</id>
  <title>Inksync Desktop Catalog</title>
  <updated>2026-05-29T12:00:00Z</updated>
  <author>
    <name>InksyncPro</name>
    <uri>https://github.com/cisidro93/InksyncPro</uri>
  </author>
  <link rel="self" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  <link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  
  <entry>
    <title>Inksync Desktop Guide</title>
    <id>urn:uuid:inksync-guide</id>
    <updated>2026-05-29T12:00:00Z</updated>
    <content type="text">Welcome to your desktop companion server! Configure sync directories to stream CBZ/CBR/PDF files.</content>
    <link rel="http://opds-spec.org/image" href="https://raw.githubusercontent.com/cisidro93/InksyncPro/main/docs/icon.png" type="image/png"/>
  </entry>
</feed>"#;

    Response::builder()
        .header("Content-Type", "application/atom+xml;charset=utf-8")
        .body(xml.to_string())
        .unwrap()
}

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<Arc<ServerState>>) -> impl IntoResponse {
    ws.on_upgrade(|socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, _state: Arc<ServerState>) {
    println!("WebSocket: Client connected");
    while let Some(Ok(msg)) = socket.recv().await {
        if let Message::Text(text) = msg {
            println!("WebSocket: Received event: {}", text);
            // Echo acknowledgment
            if let Err(e) = socket.send(Message::Text(format!("{{\"status\":\"acknowledged\",\"event\":{}}}", text))).await {
                println!("WebSocket Error: {}", e);
                break;
            }
        }
    }
    println!("WebSocket: Client disconnected");
}

#[derive(Serialize)]
struct BookInfo {
    title: String,
    path: String,
}

async fn list_books(State(_state): State<Arc<ServerState>>) -> Json<Vec<BookInfo>> {
    let mock = vec![
        BookInfo { title: "Inksync Desktop Guide".to_string(), path: "guide.epub".to_string() }
    ];
    Json(mock)
}
