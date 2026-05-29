import React, { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/tauri";
import { 
  Laptop, 
  Smartphone, 
  Wifi, 
  BookOpen, 
  RefreshCw, 
  Download, 
  Plus, 
  Settings, 
  Activity, 
  Send,
  BookMarked
} from "lucide-react";

// Mock Data
interface Book {
  id: string;
  title: string;
  path: string;
  format: string;
  size: string;
  status: "ready" | "converting" | "synced";
}

interface Highlight {
  id: string;
  bookTitle: string;
  text: string;
  note: string;
  page: number;
  time: string;
}

export default function App() {
  const [connectionInfo, setConnectionInfo] = useState<string>("Loading server...");
  const [activeTab, setActiveTab] = useState<"library" | "highlights" | "settings">("library");
  const [logs, setLogs] = useState<string[]>([
    "mDNS: Registered Calibre Wireless Service on port 9090",
    "mDNS: Registered Inksync Sync Service on port 8080",
    "Web Server: Listening on 0.0.0.0:8080",
    "Calibre TCP: Listening on 0.0.0.0:9090"
  ]);

  const [books, setBooks] = useState<Book[]>([
    { id: "1", title: "Manga Volume 01", path: "C:\\InksyncLibrary\\manga_v1.cbz", format: "CBZ", size: "48.2 MB", status: "synced" },
    { id: "2", title: "Batman Special Edition", path: "C:\\InksyncLibrary\\batman_sp.cbr", format: "CBR", size: "124.5 MB", status: "ready" },
    { id: "3", title: "Spiderman: Into the Spiderverse", path: "C:\\InksyncLibrary\\spidey.pdf", format: "PDF", size: "86.1 MB", status: "ready" },
    { id: "4", title: "Attack on Titan Vol. 30", path: "C:\\InksyncLibrary\\aot_30.cbz", format: "CBZ", size: "52.9 MB", status: "converting" }
  ]);

  const [highlights] = useState<Highlight[]>([
    { id: "h1", bookTitle: "Manga Volume 01", text: "Even when things seem impossible, we must persevere.", note: "Inspirational quote from chapter 4", page: 12, time: "2 mins ago" },
    { id: "h2", bookTitle: "Spiderman", text: "With great power comes great responsibility.", note: "Classic line re-verified in notes", page: 54, time: "10 mins ago" }
  ]);

  useEffect(() => {
    // Fetch local network IP from Tauri backend
    invoke<string>("get_connection_info")
      .then((info) => setConnectionInfo(`http://${info}`))
      .catch(() => setConnectionInfo("http://192.168.1.100:8080"));

    // Simulate logs activity
    const interval = setInterval(() => {
      const randomLogs = [
        "WebSocket: Heartbeat acknowledged from iPad Pro",
        "Directory Watcher: Scan complete. 0 modifications found.",
        "Calibre Client: Checking sync queue for newly discovered devices...",
        "Kindle Service: Fixed-layout conversion worker idle."
      ];
      const log = randomLogs[Math.floor(Math.random() * randomLogs.length)];
      setLogs(prev => [log, ...prev.slice(0, 19)]);
    }, 15000);

    return () => clearInterval(interval);
  }, []);

  const handleTranscode = (id: string) => {
    setBooks(prev => prev.map(b => b.id === id ? { ...b, status: "converting" } : b));
    setLogs(prev => [`Kindle Engine: Starting Fixed-Layout EPUB transcoding for book ID ${id}...`, ...prev]);
    
    setTimeout(() => {
      setBooks(prev => prev.map(b => b.id === id ? { ...b, status: "synced" } : b));
      setLogs(prev => [`Kindle Engine: Transcode finished. Sideloaded package pushed to device queue.`, ...prev]);
    }, 4000);
  };

  return (
    <div style={styles.container}>
      {/* Sidebar Navigation */}
      <div style={styles.sidebar}>
        <div style={styles.logoSection}>
          <div style={styles.logoIcon}>I</div>
          <div>
            <h1 style={styles.logoText}>Inksync</h1>
            <span style={styles.logoSubtitle}>Desktop Companion</span>
          </div>
        </div>

        <div style={styles.navMenu}>
          <button 
            onClick={() => setActiveTab("library")} 
            style={{ ...styles.navItem, ...(activeTab === "library" ? styles.navItemActive : {}) }}
          >
            <BookOpen size={18} />
            <span>Library Watcher</span>
          </button>
          <button 
            onClick={() => setActiveTab("highlights")} 
            style={{ ...styles.navItem, ...(activeTab === "highlights" ? styles.navItemActive : {}) }}
          >
            <BookMarked size={18} />
            <span>Synced Highlights</span>
          </button>
          <button 
            onClick={() => setActiveTab("settings")} 
            style={{ ...styles.navItem, ...(activeTab === "settings" ? styles.navItemActive : {}) }}
          >
            <Settings size={18} />
            <span>Server Settings</span>
          </button>
        </div>

        <div style={styles.networkStatusCard}>
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <Wifi size={16} color="#ff9500" />
            <span style={styles.networkTitle}>WiFi Discovery Server</span>
          </div>
          <p style={styles.networkURL}>{connectionInfo}</p>
          <div style={{ display: "flex", alignItems: "center", gap: 5, marginTop: 10 }}>
            <span style={styles.statusIndicator}></span>
            <span style={styles.statusText}>mDNS active (_calibrewireless)</span>
          </div>
        </div>
      </div>

      {/* Main Content Area */}
      <div style={styles.mainContent}>
        {/* Header Telemetry */}
        <div style={styles.header}>
          <div>
            <h2 style={styles.headerTitle}>Companion Dashboard</h2>
            <p style={styles.headerSubtitle}>Monitor sideload queues, transcoder tasks, and document metadata</p>
          </div>
          <div style={{ display: "flex", gap: 12 }}>
            <div style={styles.statCard}>
              <Laptop size={16} color="#888" />
              <div>
                <span style={styles.statValue}>Active</span>
                <span style={styles.statLabel}>Local Server</span>
              </div>
            </div>
            <div style={styles.statCard}>
              <Smartphone size={16} color="#ff9500" />
              <div>
                <span style={styles.statValue}>iPad Pro</span>
                <span style={styles.statLabel}>Sync Connected</span>
              </div>
            </div>
          </div>
        </div>

        {/* Tab Pages */}
        {activeTab === "library" && (
          <div style={styles.pageLayout}>
            {/* Library Grid */}
            <div style={styles.leftPane}>
              <div style={styles.panelHeader}>
                <h3 style={styles.panelTitle}>Monitored Books & Comics</h3>
                <button style={styles.actionButton}>
                  <Plus size={14} /> Add Folder
                </button>
              </div>

              <div style={styles.bookList}>
                {books.map(book => (
                  <div key={book.id} style={styles.bookCard}>
                    <div style={styles.bookFormatBadge}>{book.format}</div>
                    <div style={{ flex: 1, marginLeft: 15 }}>
                      <h4 style={styles.bookCardTitle}>{book.title}</h4>
                      <p style={styles.bookCardPath}>{book.path}</p>
                      <span style={styles.bookCardSize}>{book.size}</span>
                    </div>
                    <div>
                      {book.status === "synced" ? (
                        <div style={styles.badgeSynced}>Synced to iPad</div>
                      ) : book.status === "converting" ? (
                        <div style={styles.badgeConverting}>
                          <RefreshCw size={12} className="spin-animation" style={{ marginRight: 6 }} />
                          Converting...
                        </div>
                      ) : (
                        <button 
                          onClick={() => handleTranscode(book.id)} 
                          style={styles.transcodeButton}
                        >
                          <Send size={12} style={{ marginRight: 6 }} /> Sideload / Sync
                        </button>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>

            {/* Server Logs & Sideload Telemetry */}
            <div style={styles.rightPane}>
              <div style={styles.panelHeader}>
                <h3 style={styles.panelTitle}>System Telemetry Logs</h3>
                <span style={{ fontSize: 11, color: "#888", display: "flex", alignItems: "center", gap: 5 }}>
                  <Activity size={12} color="#ff9500" /> Real-time
                </span>
              </div>
              <div style={styles.logTerminal}>
                {logs.map((log, idx) => (
                  <div key={idx} style={styles.logLine}>
                    <span style={styles.logTimestamp}>[13:15:07]</span> {log}
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {activeTab === "highlights" && (
          <div style={styles.pageLayoutSingle}>
            <div style={styles.panelHeader}>
              <h3 style={styles.panelTitle}>Aggregated Annotation Log</h3>
              <button style={styles.actionButton}>
                <Download size={14} style={{ marginRight: 6 }} /> Export to Markdown
              </button>
            </div>

            <div style={styles.highlightsGrid}>
              {highlights.map(h => (
                <div key={h.id} style={styles.highlightCard}>
                  <div style={styles.highlightHeader}>
                    <span style={styles.highlightBook}>{h.bookTitle}</span>
                    <span style={styles.highlightTime}>{h.time}</span>
                  </div>
                  <p style={styles.highlightText}>"{h.text}"</p>
                  {h.note && (
                    <div style={styles.highlightNoteCard}>
                      <span style={{ fontSize: 10, fontWeight: "bold", color: "#ff9500", textTransform: "uppercase" }}>Analysis Notes</span>
                      <p style={styles.highlightNoteText}>{h.note}</p>
                    </div>
                  )}
                  <div style={styles.highlightFooter}>
                    <span>Page {h.page}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {activeTab === "settings" && (
          <div style={styles.pageLayoutSingle}>
            <div style={styles.panelHeader}>
              <h3 style={styles.panelTitle}>Connection & Server Preferences</h3>
            </div>
            
            <div style={styles.settingsForm}>
              <div style={styles.settingsGroup}>
                <h4 style={styles.settingsGroupTitle}>Port Allocations</h4>
                <div style={styles.settingsRow}>
                  <label style={styles.settingsLabel}>Calibre Wireless Receiver Port</label>
                  <input type="text" value="9090" disabled style={styles.settingsInput} />
                </div>
                <div style={styles.settingsRow}>
                  <label style={styles.settingsLabel}>Inksync Content Web Server Port</label>
                  <input type="text" value="8080" disabled style={styles.settingsInput} />
                </div>
              </div>

              <div style={styles.settingsGroup}>
                <h4 style={styles.settingsGroupTitle}>Library Path Watcher</h4>
                <div style={styles.settingsRow}>
                  <label style={styles.settingsLabel}>Active Root Directory</label>
                  <div style={{ display: "flex", gap: 10, flex: 1 }}>
                    <input type="text" value="C:\Users\User\Documents\InksyncLibrary" disabled style={styles.settingsInput} />
                    <button style={styles.actionButton}>Browse</button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// Inline Glassmorphic Styling
const styles: { [key: string]: React.CSSProperties } = {
  container: {
    display: "flex",
    width: "100vw",
    height: "100vh",
    backgroundColor: "#0d0d12",
    color: "#fff",
    fontFamily: "system-ui, -apple-system, sans-serif"
  },
  sidebar: {
    width: 260,
    backgroundColor: "#13131a",
    borderRight: "1px solid rgba(255, 255, 255, 0.06)",
    display: "flex",
    flexDirection: "column",
    padding: 20,
    boxSizing: "border-box"
  },
  logoSection: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    marginBottom: 40
  },
  logoIcon: {
    width: 36,
    height: 36,
    borderRadius: 8,
    background: "linear-gradient(135deg, #ff9500 0%, #ff5e00 100%)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 20,
    fontWeight: "bold",
    color: "#000"
  },
  logoText: {
    fontSize: 16,
    fontWeight: "bold",
    margin: 0
  },
  logoSubtitle: {
    fontSize: 10,
    color: "#888"
  },
  navMenu: {
    display: "flex",
    flexDirection: "column",
    gap: 10,
    flex: 1
  },
  navItem: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    padding: "10px 14px",
    background: "none",
    border: "none",
    borderRadius: 8,
    color: "#888",
    fontSize: 14,
    cursor: "pointer",
    textAlign: "left",
    transition: "all 0.2s"
  },
  navItemActive: {
    background: "rgba(255, 149, 0, 0.1)",
    color: "#ff9500",
    fontWeight: "bold"
  },
  networkStatusCard: {
    backgroundColor: "rgba(255, 255, 255, 0.03)",
    border: "1px solid rgba(255, 255, 255, 0.05)",
    borderRadius: 12,
    padding: 16,
    boxSizing: "border-box",
    marginTop: "auto"
  },
  networkTitle: {
    fontSize: 12,
    fontWeight: "bold",
    color: "#aaa"
  },
  networkURL: {
    fontSize: 13,
    color: "#ff9500",
    margin: "8px 0 0 0",
    fontFamily: "monospace"
  },
  statusIndicator: {
    width: 6,
    height: 6,
    borderRadius: "50%",
    backgroundColor: "#34c759",
    display: "inline-block"
  },
  statusText: {
    fontSize: 10,
    color: "#888"
  },
  mainContent: {
    flex: 1,
    display: "flex",
    flexDirection: "column",
    padding: 30,
    boxSizing: "border-box",
    overflowY: "auto"
  },
  header: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 30
  },
  headerTitle: {
    fontSize: 24,
    margin: 0,
    fontWeight: "bold"
  },
  headerSubtitle: {
    fontSize: 13,
    color: "#888",
    margin: "4px 0 0 0"
  },
  statCard: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    backgroundColor: "rgba(255, 255, 255, 0.03)",
    border: "1px solid rgba(255, 255, 255, 0.06)",
    padding: "10px 16px",
    borderRadius: 10
  },
  statValue: {
    fontSize: 14,
    fontWeight: "bold",
    display: "block"
  },
  statLabel: {
    fontSize: 10,
    color: "#888"
  },
  pageLayout: {
    display: "flex",
    gap: 25,
    flex: 1
  },
  pageLayoutSingle: {
    display: "flex",
    flexDirection: "column",
    gap: 25,
    flex: 1
  },
  leftPane: {
    flex: 2,
    backgroundColor: "#13131a",
    borderRadius: 14,
    border: "1px solid rgba(255, 255, 255, 0.06)",
    padding: 20,
    boxSizing: "border-box",
    display: "flex",
    flexDirection: "column"
  },
  rightPane: {
    flex: 1.2,
    backgroundColor: "#13131a",
    borderRadius: 14,
    border: "1px solid rgba(255, 255, 255, 0.06)",
    padding: 20,
    boxSizing: "border-box",
    display: "flex",
    flexDirection: "column"
  },
  panelHeader: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 20
  },
  panelTitle: {
    fontSize: 16,
    fontWeight: "bold",
    margin: 0
  },
  actionButton: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    backgroundColor: "rgba(255, 255, 255, 0.06)",
    color: "#fff",
    border: "none",
    padding: "6px 12px",
    borderRadius: 6,
    fontSize: 12,
    cursor: "pointer",
    fontWeight: "bold"
  },
  bookList: {
    display: "flex",
    flexDirection: "column",
    gap: 12,
    overflowY: "auto"
  },
  bookCard: {
    backgroundColor: "rgba(255, 255, 255, 0.02)",
    border: "1px solid rgba(255, 255, 255, 0.04)",
    borderRadius: 10,
    padding: 14,
    display: "flex",
    alignItems: "center",
    transition: "border-color 0.2s"
  },
  bookFormatBadge: {
    width: 42,
    height: 42,
    borderRadius: 8,
    backgroundColor: "rgba(255, 149, 0, 0.1)",
    border: "1px solid rgba(255, 149, 0, 0.2)",
    color: "#ff9500",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 11,
    fontWeight: "bold"
  },
  bookCardTitle: {
    fontSize: 14,
    margin: 0,
    fontWeight: "semibold"
  },
  bookCardPath: {
    fontSize: 11,
    color: "#666",
    margin: "2px 0",
    wordBreak: "break-all"
  },
  bookCardSize: {
    fontSize: 11,
    color: "#aaa"
  },
  transcodeButton: {
    display: "flex",
    alignItems: "center",
    backgroundColor: "#ff9500",
    color: "#000",
    border: "none",
    padding: "6px 12px",
    borderRadius: 6,
    fontSize: 12,
    cursor: "pointer",
    fontWeight: "bold"
  },
  badgeSynced: {
    fontSize: 11,
    color: "#34c759",
    padding: "4px 8px",
    borderRadius: 4,
    backgroundColor: "rgba(52, 199, 89, 0.1)"
  },
  badgeConverting: {
    display: "flex",
    alignItems: "center",
    fontSize: 11,
    color: "#ff9500",
    padding: "4px 8px",
    borderRadius: 4,
    backgroundColor: "rgba(255, 149, 0, 0.1)"
  },
  logTerminal: {
    flex: 1,
    backgroundColor: "#08080c",
    borderRadius: 8,
    padding: 15,
    fontFamily: "monospace",
    fontSize: 11,
    color: "#00ff66",
    overflowY: "auto",
    border: "1px solid rgba(255,255,255,0.03)"
  },
  logLine: {
    marginBottom: 8,
    lineHeight: 1.4
  },
  logTimestamp: {
    color: "#888",
    marginRight: 6
  },
  highlightsGrid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))",
    gap: 20
  },
  highlightCard: {
    backgroundColor: "#13131a",
    border: "1px solid rgba(255, 255, 255, 0.06)",
    borderRadius: 12,
    padding: 16,
    boxSizing: "border-box"
  },
  highlightHeader: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 10
  },
  highlightBook: {
    fontSize: 11,
    fontWeight: "bold",
    color: "#ff9500",
    backgroundColor: "rgba(255, 149, 0, 0.1)",
    padding: "3px 6px",
    borderRadius: 4
  },
  highlightTime: {
    fontSize: 11,
    color: "#666"
  },
  highlightText: {
    fontSize: 14,
    fontStyle: "italic",
    margin: "0 0 12px 0",
    color: "#ddd",
    lineHeight: 1.4
  },
  highlightNoteCard: {
    backgroundColor: "rgba(255,255,255,0.02)",
    borderLeft: "2px solid #ff9500",
    padding: 8,
    marginBottom: 10,
    borderRadius: 4
  },
  highlightNoteText: {
    fontSize: 12,
    color: "#aaa",
    margin: "4px 0 0 0"
  },
  highlightFooter: {
    fontSize: 11,
    color: "#666",
    display: "flex",
    justifyContent: "flex-end"
  },
  settingsForm: {
    backgroundColor: "#13131a",
    border: "1px solid rgba(255, 255, 255, 0.06)",
    borderRadius: 14,
    padding: 25,
    boxSizing: "border-box",
    display: "flex",
    flexDirection: "column",
    gap: 30
  },
  settingsGroup: {
    display: "flex",
    flexDirection: "column",
    gap: 15
  },
  settingsGroupTitle: {
    fontSize: 15,
    fontWeight: "bold",
    margin: 0,
    color: "#ff9500"
  },
  settingsRow: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 20
  },
  settingsLabel: {
    fontSize: 13,
    color: "#aaa",
    width: 200
  },
  settingsInput: {
    flex: 1,
    backgroundColor: "rgba(255,255,255,0.04)",
    border: "1px solid rgba(255,255,255,0.08)",
    padding: "8px 12px",
    borderRadius: 6,
    color: "#fff",
    fontSize: 13
  }
};
