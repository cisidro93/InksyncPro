#[cfg_attr(
  all(not(debug_assertions), target_os = "windows"),
  windows_subsystem = "windows"
)]

mod discovery;
mod protocol;
mod server;

use std::path::PathBuf;
use tokio::net::TcpListener;
use crate::discovery::DiscoveryManager;
use crate::protocol::CalibreSession;
use crate::server::ServerState;
use tokio::net::TcpStream;
use tokio::io::AsyncWriteExt;
use mdns_sd::{ServiceDaemon, ServiceEvent};

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct Book {
    id: String,
    title: String,
    path: String,
    format: String,
    size: String,
    status: String,
}

struct AppState {
    db_path: PathBuf,
    library_dir: std::sync::Arc<tokio::sync::Mutex<PathBuf>>,
    logs: std::sync::Arc<tokio::sync::Mutex<Vec<String>>>,
    mdns_daemon: mdns_sd::ServiceDaemon,
    pairing_pin: String,
}

#[tauri::command]
fn get_connection_info() -> String {
    if let Ok(ip) = local_ip_address::local_ip() {
        format!("{}:8080", ip)
    } else {
        "127.0.0.1:8080".to_string()
    }
}

#[tauri::command]
async fn get_library_dir(state: tauri::State<'_, AppState>) -> Result<String, String> {
    let lib_dir = state.library_dir.lock().await.clone();
    Ok(lib_dir.to_string_lossy().to_string())
}

#[tauri::command]
async fn set_library_dir(dir: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let path = PathBuf::from(&dir);
    if !path.exists() {
        return Err("Directory does not exist".to_string());
    }
    
    *state.library_dir.lock().await = path;
    
    let conn = rusqlite::Connection::open(&state.db_path).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT OR REPLACE INTO settings (key, value) VALUES ('library_dir', ?1)",
        [&dir],
    ).map_err(|e| e.to_string())?;
    
    let log_msg = format!("Settings: Library watched folder updated to: {}", dir);
    state.logs.lock().await.insert(0, log_msg);
    
    Ok(())
}

#[tauri::command]
async fn get_logs(state: tauri::State<'_, AppState>) -> Result<Vec<String>, String> {
    let logs = state.logs.lock().await.clone();
    Ok(logs)
}

#[tauri::command]
async fn get_books(state: tauri::State<'_, AppState>) -> Result<Vec<Book>, String> {
    let lib_dir = state.library_dir.lock().await.clone();
    let mut books = Vec::new();
    
    if !lib_dir.exists() {
        return Ok(books);
    }
    
    let entries = std::fs::read_dir(&lib_dir).map_err(|e| e.to_string())?;
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
                        
                        let clean_name = filename.split('_').last().unwrap_or(&filename).to_string();
                        
                        books.push(Book {
                            id: filename.clone(),
                            title: clean_name,
                            path: path.to_string_lossy().to_string(),
                            format: ext_lower.to_uppercase(),
                            size: format!("{:.1} MB", size_mb),
                            status: "ready".to_string(),
                        });
                    }
                }
            }
        }
    }
    books.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(books)
}

#[tauri::command]
async fn delete_book(path: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let file_path = PathBuf::from(&path);
    if file_path.exists() {
        std::fs::remove_file(&file_path).map_err(|e| e.to_string())?;
    }
    
    let conn = rusqlite::Connection::open(&state.db_path).map_err(|e| e.to_string())?;
    conn.execute(
        "DELETE FROM books WHERE path = ?1",
        [&path],
    ).ok();
    
    let filename = file_path.file_name().unwrap_or_default().to_string_lossy().to_string();
    let log_msg = format!("Library: Deleted file {}", filename);
    state.logs.lock().await.insert(0, log_msg);
    
    Ok(())
}

#[tauri::command]
async fn transcode_book(
    path: String,
    format: String,
    state: tauri::State<'_, AppState>
) -> Result<String, String> {
    let input_path = PathBuf::from(&path);
    if !input_path.exists() {
        return Err("Input file does not exist".to_string());
    }
    
    let format_lower = format.to_lowercase();
    let ext = format!("{}.py", if format_lower == "epub" { "cbz_to_epub" } else { "cbz_to_pdf" });
    
    let mut script_path = PathBuf::from(&ext);
    let mut found = false;
    for depth in 0..4 {
        let mut check_path = PathBuf::from(".");
        for _ in 0..depth {
            check_path.push("..");
        }
        check_path.push(&ext);
        if check_path.exists() {
            script_path = check_path;
            found = true;
            break;
        }
    }
    
    if !found {
        return Err(format!("Transcoder script {} not found in project paths", ext));
    }
    
    let log_msg = format!("Transcoder: Spawning Python worker for {} -> {}", input_path.file_name().unwrap().to_string_lossy(), format.to_uppercase());
    state.logs.lock().await.insert(0, log_msg);
    
    let output_path = input_path.with_extension(&format_lower);
    
    let mut cmd = tokio::process::Command::new("python");
    #[cfg(target_os = "windows")]
    cmd.as_std_mut().creation_flags(0x08000000); // CREATE_NO_WINDOW
    
    let output = cmd
        .arg(script_path)
        .arg(&path)
        .arg(output_path.to_string_lossy().to_string())
        .output()
        .await
        .map_err(|e| format!("Failed to spawn Python: {}", e))?;
        
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let log_msg = format!("Transcoder Error: {}", stderr);
        state.logs.lock().await.insert(0, log_msg);
        return Err(stderr);
    }
    
    let log_msg = format!("Transcoder Success: Created optimized {} file", format.to_uppercase());
    state.logs.lock().await.insert(0, log_msg);
    
    Ok("Success".to_string())
}

async fn post_file(ip: &str, port: u16, filename: &str, file_bytes: &[u8]) -> Result<(), String> {
    let addr = format!("{}:{}", ip, port);
    let mut stream = TcpStream::connect(&addr).await.map_err(|e| format!("Connection to {} failed: {}", addr, e))?;
    
    let request_header = format!(
        "POST /upload/{} HTTP/1.1\r\n\
         Host: {}\r\n\
         Content-Length: {}\r\n\
         X-File-Name: {}\r\n\
         Connection: close\r\n\r\n",
        uuid::Uuid::new_v4().simple(),
        addr,
        file_bytes.len(),
        filename
    );
    
    stream.write_all(request_header.as_bytes()).await.map_err(|e| e.to_string())?;
    stream.write_all(file_bytes).await.map_err(|e| e.to_string())?;
    stream.flush().await.map_err(|e| e.to_string())?;
    
    let mut response = [0u8; 1024];
    use tokio::io::AsyncReadExt;
    let n = stream.read(&mut response).await.map_err(|e| e.to_string())?;
    let resp_str = String::from_utf8_lossy(&response[..n]);
    if resp_str.contains("200 OK") || resp_str.contains("200") {
        Ok(())
    } else {
        Err(format!("Server returned error: {}", resp_str.split("\r\n").next().unwrap_or("Unknown")))
    }
}

#[tauri::command]
async fn discover_devices(state: tauri::State<'_, AppState>) -> Result<Vec<serde_json::Value>, String> {
    let receiver = state.mdns_daemon.browse("_inksync._tcp.local.").map_err(|e| e.to_string())?;
    
    let mut devices = std::collections::HashMap::new();
    let start = std::time::Instant::now();
    while start.elapsed() < std::time::Duration::from_millis(1500) {
        if let Ok(event) = receiver.recv_timeout(std::time::Duration::from_millis(100)) {
            match event {
                ServiceEvent::ServiceResolved(info) => {
                    let name = info.get_fullname().to_string();
                    let ip = info.get_addresses().iter().next().map(|ip| ip.to_string()).unwrap_or_default();
                    let port = info.get_port();
                    let alias = info.get_property_val_str("alias")
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| {
                            info.get_fullname().replace("._inksync._tcp.local.", "")
                        });
                    
                    if !ip.is_empty() {
                        devices.insert(name, serde_json::json!({
                            "ip": ip,
                            "port": port,
                            "alias": alias,
                        }));
                    }
                }
                _ => {}
            }
        }
    }
    
    Ok(devices.into_values().collect())
}

#[tauri::command]
fn get_pairing_pin(state: tauri::State<'_, AppState>) -> String {
    state.pairing_pin.clone()
}


#[tauri::command]
async fn send_book_to_device(
    path: String,
    device_ip: String,
    device_port: u16,
    state: tauri::State<'_, AppState>
) -> Result<String, String> {
    let file_path = PathBuf::from(&path);
    if !file_path.exists() {
        return Err("File does not exist".to_string());
    }
    
    let filename = file_path.file_name().and_then(|s| s.to_str()).unwrap_or("book.cbz").to_string();
    let file_bytes = tokio::fs::read(&file_path).await.map_err(|e| format!("Failed to read file: {}", e))?;
    
    let log_msg = format!("Sync: Sending {} to http://{}:{}", filename, device_ip, device_port);
    state.logs.lock().await.insert(0, log_msg);
    
    post_file(&device_ip, device_port, &filename, &file_bytes).await?;
    
    let log_msg = format!("Sync Success: Transferred {} successfully!", filename);
    state.logs.lock().await.insert(0, log_msg);
    
    Ok("Success".to_string())
}

#[tauri::command]
async fn add_books_to_library(paths: Vec<String>, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let lib_dir = state.library_dir.lock().await.clone();
    if !lib_dir.exists() {
        return Err("Library directory does not exist".to_string());
    }
    
    for path in paths {
        let src_path = std::path::Path::new(&path);
        if src_path.is_file() {
            if let Some(filename) = src_path.file_name() {
                let dest_path = lib_dir.join(filename);
                std::fs::copy(src_path, &dest_path)
                    .map_err(|e| format!("Failed to copy file {}: {}", filename.to_string_lossy(), e))?;
                
                let log_msg = format!("Library: Copied {} into watched folder", filename.to_string_lossy());
                state.logs.lock().await.insert(0, log_msg);
            }
        }
    }
    Ok(())
}

#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct Annotation {
    id: String,
    pdf_id: String,
    page_index: i32,
    chapter_title: Option<String>,
    kind: String,
    created_at: i64,
    modified_at: i64,
    color_hex: Option<String>,
    selected_text: Option<String>,
    note_text: Option<String>,
    tags: Option<String>,
    readwise_book_title: Option<String>,
}

#[tauri::command]
async fn get_annotations(state: tauri::State<'_, AppState>) -> Result<Vec<Annotation>, String> {
    let conn = rusqlite::Connection::open(&state.db_path).map_err(|e| e.to_string())?;
    let mut stmt = conn.prepare(
        "SELECT id, pdf_id, page_index, chapter_title, kind, created_at, modified_at, color_hex, selected_text, note_text, tags, readwise_book_title FROM annotations ORDER BY modified_at DESC"
    ).map_err(|e| e.to_string())?;
    
    let rows = stmt.query_map([], |row| {
        Ok(Annotation {
            id: row.get(0)?,
            pdf_id: row.get(1)?,
            page_index: row.get(2)?,
            chapter_title: row.get(3)?,
            kind: row.get(4)?,
            created_at: row.get(5)?,
            modified_at: row.get(6)?,
            color_hex: row.get(7)?,
            selected_text: row.get(8)?,
            note_text: row.get(9)?,
            tags: row.get(10)?,
            readwise_book_title: row.get(11)?,
        })
    }).map_err(|e| e.to_string())?;
    
    let mut list = Vec::new();
    for r in rows {
        if let Ok(item) = r {
            list.push(item);
        }
    }
    Ok(list)
}

#[tauri::command]
async fn get_obsidian_vault_path(state: tauri::State<'_, AppState>) -> Result<String, String> {
    let conn = rusqlite::Connection::open(&state.db_path).map_err(|e| e.to_string())?;
    let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = 'obsidian_vault_path'").map_err(|e| e.to_string())?;
    let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
    if let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let val: String = row.get(0).map_err(|e| e.to_string())?;
        Ok(val)
    } else {
        Ok("".to_string())
    }
}

#[tauri::command]
async fn set_obsidian_vault_path(path: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let conn = rusqlite::Connection::open(&state.db_path).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT OR REPLACE INTO settings (key, value) VALUES ('obsidian_vault_path', ?1)",
        [&path],
    ).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn export_to_obsidian(highlights: Vec<Annotation>, state: tauri::State<'_, AppState>) -> Result<String, String> {
    let vault_path = {
        let conn = rusqlite::Connection::open(&state.db_path).map_err(|e| e.to_string())?;
        let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = 'obsidian_vault_path'").map_err(|e| e.to_string())?;
        let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let val: String = row.get(0).map_err(|e| e.to_string())?;
            val
        } else {
            return Err("Obsidian Vault Path is not set".to_string());
        }
    };
    
    let path = std::path::Path::new(&vault_path);
    if !path.exists() {
        return Err(format!("Obsidian Vault path '{}' does not exist", vault_path));
    }
    
    // Group highlights by book title
    let mut grouped = std::collections::HashMap::new();
    for h in highlights {
        let book_title = h.readwise_book_title.clone().unwrap_or_else(|| "Unknown Book".to_string());
        grouped.entry(book_title).or_insert_with(Vec::new).push(h);
    }
    
    let mut exported_count = 0;
    for (book_title, notes) in grouped {
        // Build Obsidian Markdown content
        let mut markdown = format!(
            "---\nbook: \"{}\"\nsource: \"Inksync Companion\"\ntags: [zettelkasten, manga_highlight, inksyncpro]\n---\n\n# 📖 {}\n\n",
            book_title,
            book_title
        );
        
        let mut sorted = notes.clone();
        sorted.sort_by_key(|n| n.modified_at);
        
        for note in sorted {
            let page_lbl = if note.page_index >= 0 {
                format!("Page {}", note.page_index + 1)
            } else {
                "Unknown Page".to_string()
            };
            
            markdown.push_str(&format!("## {}\n", page_lbl));
            if let Some(text) = &note.selected_text {
                if !text.is_empty() {
                    markdown.push_str(&format!("> {}\n\n", text.replace("\n", "\n> ")));
                }
            }
            if let Some(user_note) = &note.note_text {
                if !user_note.is_empty() {
                    markdown.push_str(&format!("**Note:** {}\n\n", user_note));
                }
            }
            if let Some(tags_str) = &note.tags {
                if !tags_str.is_empty() {
                    let hashed: Vec<String> = tags_str.split(',')
                        .map(|t| format!("#{}", t.trim().replace(" ", "_")))
                        .collect();
                    markdown.push_str(&format!("🏷️ *Tags:* {}\n\n", hashed.join(", ")));
                }
            }
            markdown.push_str("---\n\n");
        }
        
        // Write to Obsidian markdown file
        let safe_title = book_title.chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect::<String>();
        let file_path = path.join(format!("{}.md", safe_title));
        tokio::fs::write(&file_path, markdown.as_bytes()).await.map_err(|e| format!("Failed to write {}.md: {}", safe_title, e))?;
        exported_count += 1;
    }
    
    let log_msg = format!("Obsidian: Exported {} book outlines to vault", exported_count);
    state.logs.lock().await.insert(0, log_msg);
    
    Ok(format!("Successfully exported {} books to Obsidian!", exported_count))
}



#[tokio::main]
async fn main() {
    let hostname = std::env::var("COMPUTERNAME")
        .unwrap_or_else(|_| "Windows-PC".to_string());

    println!("Starting Inksync Desktop on host: {}", hostname);

    let app_dir = dirs::document_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("InksyncLibrary");
    std::fs::create_dir_all(&app_dir).unwrap();
    let db_path = app_dir.join("library.db");

    let conn = rusqlite::Connection::open(&db_path).unwrap();
    conn.execute(
        "CREATE TABLE IF NOT EXISTS books (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            path TEXT NOT NULL,
            size INTEGER,
            page_count INTEGER,
            added_at INTEGER
        )",
        [],
    ).unwrap();

    conn.execute(
        "CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )",
        [],
    ).unwrap();

    conn.execute(
        "CREATE TABLE IF NOT EXISTS annotations (
            id TEXT PRIMARY KEY,
            pdf_id TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            chapter_title TEXT,
            kind TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            color_hex TEXT,
            selected_text TEXT,
            note_text TEXT,
            tags TEXT,
            readwise_book_title TEXT
        )",
        [],
    ).unwrap();

    let mut saved_dir = app_dir.clone();
    if let Ok(mut stmt) = conn.prepare("SELECT value FROM settings WHERE key = 'library_dir'") {
        if let Ok(mut rows) = stmt.query([]) {
            if let Ok(Some(row)) = rows.next() {
                if let Ok(dir_str) = row.get::<_, String>(0) {
                    let path = PathBuf::from(&dir_str);
                    if path.exists() {
                        saved_dir = path;
                    }
                }
            }
        }
    }

    let shared_lib_dir = std::sync::Arc::new(tokio::sync::Mutex::new(saved_dir));
    let logs_vec = std::sync::Arc::new(tokio::sync::Mutex::new(vec![
        "mDNS: Registered Calibre Wireless Service on port 9090".to_string(),
        "mDNS: Registered Inksync Sync Service on port 8080".to_string(),
        "Web Server: Listening on 0.0.0.0:8080".to_string(),
        "Calibre TCP: Listening on 0.0.0.0:9090".to_string(),
    ]));

    let discovery = DiscoveryManager::new().expect("Failed to initialize mDNS");
    discovery.advertise_calibre(9090, &hostname).ok();
    discovery.advertise_sync(8080, &hostname).ok();
    let mdns_daemon = discovery.get_daemon();

    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let pairing_pin = format!("{:04}", (seconds % 9000) + 1000);

    let app_state = AppState {
        db_path: db_path.clone(),
        library_dir: shared_lib_dir.clone(),
        logs: logs_vec.clone(),
        mdns_daemon,
        pairing_pin: pairing_pin.clone(),
    };

    let server_state = ServerState {
        library_dir: shared_lib_dir.clone(),
        db_path: db_path.clone(),
        pairing_pin: pairing_pin.clone(),
    };
    server::start_server(8080, server_state).await;

    // Start Calibre Smart-Device Protocol TCP Socket Server (Port 9090)
    let logs_clone = logs_vec.clone();
    tokio::spawn(async move {
        let listener = TcpListener::bind("0.0.0.0:9090").await.unwrap();
        println!("Calibre TCP: Listening on 0.0.0.0:9090");
        while let Ok((stream, _)) = listener.accept().await {
            let logs = logs_clone.clone();
            tokio::spawn(async move {
                let mut session = CalibreSession::new(stream);
                logs.lock().await.insert(0, "Calibre TCP: Client connected!".to_string());
                
                if let Err(e) = session.send_packet(&serde_json::json!({ "op": 9 })).await {
                    println!("Calibre Handshake: failed sending op 9: {}", e);
                    return;
                }

                while let Ok(packet) = session.receive_packet().await {
                    let op = packet["op"].as_i64().unwrap_or(-1);
                    logs.lock().await.insert(0, format!("Calibre TCP: Received op {}", op));
                    
                    match op {
                        1 | 2 | 19 => {
                            if let Err(_) = session.send_ok(serde_json::json!({})).await { break; }
                        }
                        3 => {
                            let device_info = serde_json::json!({
                                "op": 0,
                                "info": {
                                    "device_name": "Inksync Server",
                                    "device_store_uuid": "inksync-server-uuid",
                                    "total_space": 100_000_000_000u64,
                                    "free_space": 50_000_000_000u64
                                }
                            });
                            if let Err(_) = session.send_packet(&device_info).await { break; }
                        }
                        6 => {
                            if let Err(_) = session.send_ok(serde_json::json!({
                                "count": 0, "willStream": false, "willScan": false
                            })).await { break; }
                        }
                        7 => {
                            if let Err(_) = session.send_ok(serde_json::json!({})).await { break; }
                        }
                        12 => {
                            if let Err(_) = session.send_ok(serde_json::json!({})).await { break; }
                        }
                        _ => {
                            if let Err(_) = session.send_ok(serde_json::json!({})).await { break; }
                        }
                    }
                }
                logs.lock().await.insert(0, "Calibre TCP: Session ended.".to_string());
            });
        }
    });

    tauri::Builder::default()
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![
            get_connection_info,
            get_library_dir,
            set_library_dir,
            get_books,
            delete_book,
            transcode_book,
            get_logs,
            discover_devices,
            send_book_to_device,
            add_books_to_library,
            get_annotations,
            get_obsidian_vault_path,
            set_obsidian_vault_path,
            export_to_obsidian,
            get_pairing_pin
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
