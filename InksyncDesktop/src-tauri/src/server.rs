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
    pub pairing_pin: String,
}

pub async fn start_server(port: u16, state: ServerState) {
    let app = Router::new()
        .route("/", get(serve_index))
        .route("/opds", get(serve_opds))
        .route("/sync", get(ws_handler))
        .route("/api/books", get(list_books))
        .route("/api/sync/annotations", axum::routing::post(sync_annotations))
        .route("/upload/:filename", axum::routing::post(upload_file))
        .route("/login", axum::routing::post(handle_login))
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

async fn serve_index(State(state): State<Arc<ServerState>>) -> impl IntoResponse {
    let lib_dir = state.library_dir.lock().await.clone();
    let mut books_list_html = String::new();
    
    if let Ok(entries) = std::fs::read_dir(&lib_dir) {
        let mut count = 0;
        for entry in entries {
            if let Ok(entry) = entry {
                let path = entry.path();
                if path.is_file() {
                    if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                        let ext_lower = ext.to_lowercase();
                        if ext_lower == "cbz" || ext_lower == "cbr" || ext_lower == "pdf" || ext_lower == "epub" {
                            let filename = path.file_name().and_then(|s| s.to_str()).unwrap_or("").to_string();
                            let size_bytes = entry.metadata().map(|m| m.len()).unwrap_or(0);
                            let size_mb = size_bytes as f64 / (1024.0 * 1024.0);
                            
                            books_list_html.push_str(&format!(
                                "<div style='background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.05); padding:12px; border-radius:8px; margin-bottom:8px; display:flex; justify-content:space-between; align-items:center;'>\
                                   <div>\
                                     <div style='font-weight:bold; color:#fff;'>{}</div>\
                                     <div style='font-size:11px; color:#888;'>{}</div>\
                                   </div>\
                                   <div style='font-size:11px; background:rgba(255,149,0,0.1); border:1px solid rgba(255,149,0,0.2); color:#ff9500; padding:2px 6px; border-radius:4px; font-weight:bold;'>{}</div>\
                                 </div>",
                                filename,
                                format!("{:.1} MB", size_mb),
                                ext_lower.to_uppercase()
                            ));
                            count += 1;
                        }
                    }
                }
            }
        }
        if count == 0 {
            books_list_html = "<div style='color:#666; font-style:italic;'>No books on the library shelf yet. Click 'Add Books' on the companion dashboard.</div>".to_string();
        }
    } else {
        books_list_html = "<div style='color:#ef4444;'>Failed to scan library directory.</div>".to_string();
    }

    let html = format!(
        r#"<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Inksync Sync Server</title>
  <style>
    body {{
      font-family: system-ui, -apple-system, sans-serif;
      background-color: #0d0d12;
      color: #fff;
      margin: 0;
      padding: 40px 20px;
      display: flex;
      justify-content: center;
    }}
    .card {{
      background-color: #13131a;
      border: 1px solid rgba(255, 255, 255, 0.06);
      border-radius: 14px;
      padding: 30px;
      max-width: 600px;
      width: 100%;
      box-shadow: 0 8px 32px rgba(0,0,0,0.5);
    }}
    .header {{
      display: flex;
      align-items: center;
      gap: 15px;
      margin-bottom: 25px;
      border-bottom: 1px solid rgba(255,255,255,0.06);
      padding-bottom: 20px;
    }}
    .status-badge {{
      background-color: rgba(52, 199, 89, 0.1);
      border: 1px solid rgba(52, 199, 89, 0.2);
      color: #34c759;
      padding: 4px 10px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: bold;
      margin-left: auto;
    }}
    .title {{
      font-size: 20px;
      font-weight: bold;
      margin: 0;
    }}
    .subtitle {{
      color: #888;
      font-size: 13px;
      margin-top: 4px;
    }}
    h3 {{
      font-size: 14px;
      color: #ff9500;
      text-transform: uppercase;
      margin-top: 25px;
      margin-bottom: 12px;
      letter-spacing: 0.5px;
    }}
    .instructions {{
      background: rgba(255,255,255,0.02);
      border-left: 3px solid #ff9500;
      padding: 12px 16px;
      border-radius: 4px;
      font-size: 13px;
      color: #aaa;
      line-height: 1.5;
    }}
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <div style="background:#ff9500; color:#000; width:36px; height:36px; border-radius:8px; display:flex; align-items:center; justify-content:center; font-weight:bold; font-size:20px;">I</div>
      <div>
        <div class="title">Inksync Sync Service</div>
        <div class="subtitle">Active Wireless Transfer & OPDS Catalog Node</div>
      </div>
      <div class="status-badge">ONLINE</div>
    </div>
    
    <h3>OPDS Feed Endpoint</h3>
    <div class="instructions">
      Connect your e-reader app (like Marvin, KyBook, or KOReader) to:<br>
      <code style="color:#ff9500; font-size:14px; font-weight:bold; display:block; margin-top:6px;">http://[ServerIP]:8080/opds</code>
    </div>

    <h3>Library Shelf Files</h3>
    <div style="max-height: 250px; overflow-y: auto; padding-right: 4px;">
      {}
    </div>
  </div>
</body>
</html>
"#,
        books_list_html
    );

    (
        [(axum::http::header::CONTENT_TYPE, "text/html;charset=utf-8")],
        html,
    )
}

#[derive(serde::Deserialize)]
struct AnnotationDTO {
    id: String,
    pdfID: String,
    pageIndex: i32,
    chapterTitle: Option<String>,
    kind: String,
    createdAt: i64,
    modifiedAt: i64,
    colorHex: Option<String>,
    selectedText: Option<String>,
    noteText: Option<String>,
    tags: Option<Vec<String>>,
    readwiseBookTitle: Option<String>,
}

async fn sync_annotations(
    State(state): State<Arc<ServerState>>,
    Json(payload): Json<Vec<AnnotationDTO>>,
) -> impl IntoResponse {
    let conn = match rusqlite::Connection::open(&state.db_path) {
        Ok(c) => c,
        Err(e) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to open DB: {}", e)).into_response(),
    };
    
    for a in payload {
        let tags_str = a.tags.map(|t| t.join(","));
        
        let res = conn.execute(
            "INSERT OR REPLACE INTO annotations (id, pdf_id, page_index, chapter_title, kind, created_at, modified_at, color_hex, selected_text, note_text, tags, readwise_book_title) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            rusqlite::params![
                a.id,
                a.pdfID,
                a.pageIndex,
                a.chapterTitle,
                a.kind,
                a.createdAt,
                a.modifiedAt,
                a.colorHex,
                a.selectedText,
                a.noteText,
                tags_str,
                a.readwiseBookTitle
            ],
        );
        if let Err(e) = res {
            eprintln!("Failed to save annotation: {}", e);
            return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to save annotation: {}", e)).into_response();
        }
    }
    
    (axum::http::StatusCode::OK, "Annotations synced successfully").into_response()
}

#[derive(serde::Deserialize)]
struct LoginPayload {
    pin: String,
}

async fn handle_login(
    State(state): State<Arc<ServerState>>,
    axum::extract::Form(payload): axum::extract::Form<LoginPayload>,
) -> impl IntoResponse {
    if state.pairing_pin == payload.pin {
        (
            axum::http::StatusCode::OK,
            [
                (axum::http::header::SET_COOKIE, "session=authorized_session_token_value; Path=/"),
            ],
            "Authenticated",
        ).into_response()
    } else {
        (axum::http::StatusCode::UNAUTHORIZED, "Invalid PIN").into_response()
    }
}
