use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use serde_json::{json, Value};
use std::error::Error;
use std::path::Path;
use tokio::fs::File;

pub struct CalibreSession {
    stream: TcpStream,
}

impl CalibreSession {
    pub fn new(stream: TcpStream) -> Self {
        Self { stream }
    }

    /// Read length-prefixed JSON packet
    pub async fn receive_packet(&mut self) -> Result<Value, Box<dyn Error + Send + Sync>> {
        let mut length_buf = [0u8; 4];
        self.stream.read_exact(&mut length_buf).await?;
        let length = u32::from_be_bytes(length_buf) as usize;

        if length == 0 || length > 1_000_000 {
            return Err("Packet length safety violation".into());
        }

        let mut payload_buf = vec![0u8; length];
        self.stream.read_exact(&mut payload_buf).await?;
        
        let json: Value = serde_json::from_slice(&payload_buf)?;
        Ok(json)
    }

    /// Write length-prefixed JSON packet
    pub async fn send_packet(&mut self, payload: &Value) -> Result<(), Box<dyn Error + Send + Sync>> {
        let bytes = serde_json::to_vec(payload)?;
        let length = bytes.len() as u32;
        
        self.stream.write_all(&length.to_be_bytes()).await?;
        self.stream.write_all(&bytes).await?;
        self.stream.flush().await?;
        Ok(())
    }

    /// Helper to send an OK response
    pub async fn send_ok(&mut self, extra: Value) -> Result<(), Box<dyn Error + Send + Sync>> {
        let mut payload = json!({ "op": 0 }); // OK opcode is 0
        if let Value::Object(map) = extra {
            for (k, v) in map {
                payload[k] = v;
            }
        }
        self.send_packet(&payload).await
    }

    /// Sends a book to the connected device (iOS app)
    /// Opcode: SEND_BOOK (8)
    pub async fn send_book(&mut self, file_path: &Path, title: &str) -> Result<(), Box<dyn Error + Send + Sync>> {
        let mut file = File::open(file_path).await?;
        let file_len = file.metadata().await?.len();
        let filename = file_path.file_name().and_then(|s| s.to_str()).unwrap_or("book.epub");

        // Send metadata first
        let send_book_payload = json!({
            "op": 8, // SEND_BOOK opcode
            "length": file_len,
            "lpath": filename,
            "metadata": {
                "title": title,
                "authors": ["Unknown"],
                "uuid": uuid::Uuid::new_v4().to_string(),
            }
        });
        
        self.send_packet(&send_book_payload).await?;

        // Wait for device to acknowledge ready-to-receive
        let ack = self.receive_packet().await?;
        if ack["op"].as_i64() != Some(0) {
            return Err("Device did not acknowledge book download request".into());
        }

        // Stream the file bytes
        let mut buffer = vec![0u8; 65536];
        loop {
            let n = file.read(&mut buffer).await?;
            if n == 0 { break; }
            self.stream.write_all(&buffer[..n]).await?;
        }
        self.stream.flush().await?;

        // Wait for book done ack (opcode 11 or 0)
        let done_ack = self.receive_packet().await?;
        println!("mDNS/TCP: Book transfer complete ack: {:?}", done_ack);

        Ok(())
    }
}
