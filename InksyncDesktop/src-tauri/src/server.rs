use axum::{
    routing::get,
    Router,
    extract::{ws::{WebSocket, WebSocketUpgrade, Message}, State, Path as AxumPath},
    response::IntoResponse,
    Json,
};
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::cors::CorsLayer;
use serde::Serialize;
use std::path::PathBuf;

#[derive(Clone)]
pub struct ServerState {
    pub library_dir: std::sync::Arc<tokio::sync::Mutex<PathBuf>>,
    pub db_path: PathBuf,
}

pub async fn start_server(port: u16, state: ServerState) {
    let app = Router::new()
        .route("/opds", get(serve_opds))
        .route("/sync", get(ws_handler))
        .route("/api/books", get(list_books))
        .route("/upload/:filename", axum::routing::post(upload_file))
        .with_state(Arc::new(state))
        .layer(CorsLayer::permissive());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("Web Server: Listening on {}", addr);
    
    tokio::spawn(async move {
        axum::Server::bind(&addr)
            .serve(app.into_make_service())
            .await
            .unwrap();
    });
}

async fn serve_opds(State(_state): State<Arc<ServerState>>) -> impl IntoResponse {
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

    (
        [(axum::http::header::CONTENT_TYPE, "application/atom+xml;charset=utf-8")],
        xml.to_string(),
    )
}

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<Arc<ServerState>>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(mut socket: WebSocket, _state: Arc<ServerState>) {
    println!("WebSocket: Client connected");
    while let Some(Ok(msg)) = socket.recv().await {
        if let Message::Text(text) = msg {
            println!("WebSocket: Received event: {}", text);
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

async fn list_books(State(state): State<Arc<ServerState>>) -> Json<Vec<BookInfo>> {
    let lib_dir = state.library_dir.lock().await.clone();
    let mut books = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&lib_dir) {
        for entry in entries {
            if let Ok(entry) = entry {
                let path = entry.path();
                if path.is_file() {
                    if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                        let ext_lower = ext.to_lowercase();
                        if ext_lower == "cbz" || ext_lower == "cbr" || ext_lower == "pdf" || ext_lower == "epub" {
                            let filename = path.file_name().and_then(|s| s.to_str()).unwrap_or("").to_string();
                            books.push(BookInfo {
                                title: filename.clone(),
                                path: filename,
                            });
                        }
                    }
                }
            }
        }
    }
    Json(books)
}

async fn upload_file(
    AxumPath(filename): AxumPath<String>,
    headers: axum::http::HeaderMap,
    State(state): State<Arc<ServerState>>,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    let lib_dir = state.library_dir.lock().await.clone();
    
    // Extract real filename or relative path from headers if available
    let explicit_name = headers
        .get("x-file-name")
        .or_else(|| headers.get("X-File-Name"))
        .and_then(|val| val.to_str().ok())
        .map(|s| s.to_string());

    let relative_path = headers
        .get("x-relative-path")
        .or_else(|| headers.get("X-Relative-Path"))
        .and_then(|val| val.to_str().ok())
        .map(|s| s.to_string());

    let final_filename = relative_path.unwrap_or_else(|| {
        explicit_name.unwrap_or(filename)
    });
    
    // Prevent directory traversal attacks
    let safe_filename = final_filename.replace("..", "");
    let file_path = lib_dir.join(&safe_filename);
    
    // Create any parent directories if writing a nested file structure
    if let Some(parent) = file_path.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            eprintln!("Web Server Error: Failed to create directories: {}", e);
            return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to create directories: {}", e)).into_response();
        }
    }
    
    match tokio::fs::write(&file_path, body).await {
        Ok(_) => {
            println!("Web Server: Received uploaded file saved to: {}", file_path.to_string_lossy());
            (axum::http::StatusCode::OK, "Upload successful").into_response()
        }
        Err(e) => {
            eprintln!("Web Server Error: Failed to save uploaded file: {}", e);
            (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to save file: {}", e)).into_response()
        }
    }
}
