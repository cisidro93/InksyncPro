#![cfg_attr(
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

// Tauri command to get local IP and server state
#[tauri::command]
fn get_connection_info() -> String {
    if let Ok(ip) = local_ip_address::local_ip() {
        format!("{}:8080", ip)
    } else {
        "127.0.0.1:8080".to_string()
    }
}

#[tokio::main]
async fn main() {
    // Obtain computer name using standard Windows env var
    let hostname = std::env::var("COMPUTERNAME")
        .unwrap_or_else(|_| "Windows-PC".to_string());

    println!("Starting Inksync Desktop on host: {}", hostname);

    // 1. Initialize Directories
    let app_dir = dirs::document_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("InksyncLibrary");
    std::fs::create_dir_all(&app_dir).unwrap();
    let db_path = app_dir.join("library.db");

    // 2. Initialize database schema
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

    // 3. Start mDNS Discovery Advertising
    let discovery = DiscoveryManager::new().expect("Failed to initialize mDNS");
    discovery.advertise_calibre(9090, &hostname).ok();
    discovery.advertise_sync(8080, &hostname).ok();

    // 4. Start HTTP/Websocket Server
    let server_state = ServerState {
        library_dir: app_dir.clone(),
        db_path: db_path.clone(),
    };
    server::start_server(8080, server_state).await;

    // 5. Start Calibre Smart-Device Protocol TCP Socket Server (Port 9090)
    tokio::spawn(async move {
        let listener = TcpListener::bind("0.0.0.0:9090").await.unwrap();
        println!("Calibre TCP: Listening on 0.0.0.0:9090");
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut session = CalibreSession::new(stream);
                println!("Calibre TCP: Client connected!");
                
                // Handle initial Calibre smart-device handshake
                // Opcode 9 is getInitializationInfo. We must send this first.
                if let Err(e) = session.send_packet(&serde_json::json!({ "op": 9 })).await {
                    println!("Calibre Handshake: failed sending initial op 9: {}", e);
                    return;
                }

                while let Ok(packet) = session.receive_packet().await {
                    let op = packet["op"].as_i64().unwrap_or(-1);
                    println!("Calibre TCP: Received op {}", op);
                    
                    // Simple server emulation loop:
                    // If device sends setup info (opcode 1) or device info (opcode 3), acknowledge.
                    match op {
                        1 | 2 | 19 => {
                            // Acknowledge setCalibreDeviceInfo, setCalibreDeviceName, setLibraryInfo
                            if let Err(e) = session.send_ok(serde_json::json!({})).await {
                                println!("Calibre TCP: error sending OK: {}", e);
                                break;
                            }
                        }
                        3 => {
                            // Acknowledge getDeviceInformation with space details
                            let device_info = serde_json::json!({
                                "op": 0,
                                "info": {
                                    "device_name": "Inksync Server",
                                    "device_store_uuid": "inksync-server-uuid",
                                    "total_space": 100_000_000_000u64,
                                    "free_space": 50_000_000_000u64
                                }
                            });
                            if let Err(e) = session.send_packet(&device_info).await {
                                println!("Calibre TCP: error sending device info: {}", e);
                                break;
                            }
                        }
                        6 => {
                            // getBookCount: report 0 for simplicity so client doesn't upload device catalog
                            if let Err(e) = session.send_ok(serde_json::json!({
                                "count": 0, "willStream": false, "willScan": false
                            })).await {
                                println!("Calibre TCP: error sending book count: {}", e);
                                break;
                            }
                        }
                        7 => {
                            // sendBooklists: acknowledge
                            if let Err(e) = session.send_ok(serde_json::json!({})).await {
                                println!("Calibre TCP: error acking booklists: {}", e);
                                break;
                            }
                        }
                        12 => {
                            // noop
                            if let Err(e) = session.send_ok(serde_json::json!({})).await {
                                println!("Calibre TCP: error acking noop: {}", e);
                                break;
                            }
                        }
                        _ => {
                            // Default fallback
                            if let Err(e) = session.send_ok(serde_json::json!({})).await {
                                println!("Calibre TCP: fallback error: {}", e);
                                break;
                            }
                        }
                    }
                }
                println!("Calibre TCP: Session ended.");
            });
        }
    });

    // 6. Launch Tauri GUI Interface
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![get_connection_info])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
