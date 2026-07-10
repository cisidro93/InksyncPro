import React, { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/tauri";
import { open } from "@tauri-apps/api/dialog";
import { 
  Laptop, 
  Smartphone, 
  Wifi, 
  BookOpen, 
  RefreshCw, 
  Download, 
  Settings, 
  Activity, 
  Send,
  BookMarked,
  Trash2,
  FolderOpen,
  Plus
} from "lucide-react";

interface Book {
  id: string;
  title: string;
  path: string;
  format: string;
  size: string;
  status: "ready" | "converting" | "synced";
}



const CURRENT_VERSION = "0.1.0";

export default function App() {
  const [connectionInfo, setConnectionInfo] = useState<string>("Loading server...");
  const [activeTab, setActiveTab] = useState<"library" | "highlights" | "settings">("library");
  const [logs, setLogs] = useState<string[]>([]);
  const [books, setBooks] = useState<Book[]>([]);
  const [libraryPath, setLibraryPath] = useState<string>("");
  const [isRefreshing, setIsRefreshing] = useState<boolean>(false);
  const [devices, setDevices] = useState<{ip: string, port: number, alias: string}[]>([]);
  const [isScanning, setIsScanning] = useState<boolean>(false);
  const [activeDeviceDropdown, setActiveDeviceDropdown] = useState<string | null>(null);
  const [updateAvailable, setUpdateAvailable] = useState<string | null>(null);

  const [highlights, setHighlights] = useState<any[]>([]);
  const [obsidianVaultPath, setObsidianVaultPath] = useState<string>("");

  const loadHighlights = () => {
    invoke<any[]>("get_annotations")
      .then((data) => setHighlights(data))
      .catch((err) => console.error("Failed to load highlights:", err));
  };

  const fetchObsidianPath = () => {
    invoke<string>("get_obsidian_vault_path")
      .then((path) => setObsidianVaultPath(path))
      .catch((err) => console.error("Failed to load obsidian path:", err));
  };

  const fetchConnection = () => {
    invoke<string>("get_connection_info")
      .then((info) => setConnectionInfo(`http://${info}`))
      .catch(() => setConnectionInfo("http://127.0.0.1:8080"));
  };

  const fetchLibraryPath = () => {
    invoke<string>("get_library_dir")
      .then((path) => setLibraryPath(path))
      .catch((err) => console.error("Failed to load library dir:", err));
  };

  const loadBooks = () => {
    setIsRefreshing(true);
    invoke<Book[]>("get_books")
      .then((data) => {
        // Map backend status or keep default 'ready'
        setBooks(data.map(b => ({ ...b, status: "ready" })));
      })
      .catch((err) => console.error("Failed to load books:", err))
      .finally(() => setIsRefreshing(false));
  };

  const loadLogs = () => {
    invoke<string[]>("get_logs")
      .then((data) => setLogs(data))
      .catch((err) => console.error("Failed to load logs:", err));
  };

  const scanDevices = () => {
    setIsScanning(true);
    invoke<{ip: string, port: number, alias: string}[]>("discover_devices")
      .then((res) => {
        setDevices(res);
      })
      .catch((err) => console.error("Device scan failed:", err))
      .finally(() => setIsScanning(false));
  };

  const handleSendToDevice = (bookId: string, path: string, device: {ip: string, port: number, alias: string}) => {
    setBooks(prev => prev.map(b => b.id === bookId ? { ...b, status: "converting" } : b));
    setActiveDeviceDropdown(null);
    
    invoke("send_book_to_device", { path, deviceIp: device.ip, devicePort: device.port })
      .then(() => {
        setBooks(prev => prev.map(b => b.id === bookId ? { ...b, status: "synced" } : b));
        loadLogs();
      })
      .catch((err) => {
        alert(`Failed to send to ${device.alias}: ${err}`);
        loadBooks();
      });
  };

  const checkUpdates = () => {
    fetch("https://api.github.com/repos/cisidro93/InksyncPro/releases/latest")
      .then(res => res.json())
      .then(data => {
        const payload = data as any;
        if (payload && payload.tag_name) {
          const latest = payload.tag_name.replace("v", "");
          if (latest !== CURRENT_VERSION) {
            setUpdateAvailable(latest);
          }
        }
      })
      .catch(err => console.error("Failed to check for updates:", err));
  };

  useEffect(() => {
    fetchConnection();
    fetchLibraryPath();
    loadBooks();
    loadLogs();
    scanDevices();
    checkUpdates();
    fetchObsidianPath();
    loadHighlights();

    // Poll logs, books, devices, and highlights
    const logInterval = setInterval(loadLogs, 1500);
    const bookInterval = setInterval(loadBooks, 8000);
    const deviceInterval = setInterval(scanDevices, 10000);
    const updateInterval = setInterval(checkUpdates, 60000);
    const highlightInterval = setInterval(loadHighlights, 5000);

    return () => {
      clearInterval(logInterval);
      clearInterval(bookInterval);
      clearInterval(deviceInterval);
      clearInterval(updateInterval);
      clearInterval(highlightInterval);
    };
  }, []);

  const handleTranscode = (id: string, path: string, format: string) => {
    setBooks(prev => prev.map(b => b.id === id ? { ...b, status: "converting" } : b));
    
    // Default format target
    const targetFormat = format === "CBZ" || format === "CBR" ? "PDF" : "EPUB";
    
    invoke("transcode_book", { path, format: targetFormat })
      .then(() => {
        loadBooks();
        loadLogs();
      })
      .catch((err) => {
        alert("Transcoding failed: " + err);
        loadBooks();
      });
  };

  const handleDelete = (path: string) => {
    if (window.confirm("Are you sure you want to delete this file from the holding shelf?")) {
      invoke("delete_book", { path })
        .then(() => {
          loadBooks();
          loadLogs();
        })
        .catch((err) => alert("Failed to delete book: " + err));
    }
  };

  const handleBrowse = async () => {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
        title: "Select Library Holding Directory"
      });
      if (selected && typeof selected === "string") {
        invoke("set_library_dir", { dir: selected })
          .then(() => {
            setLibraryPath(selected);
            loadBooks();
            loadLogs();
          })
          .catch((err) => alert("Failed to set directory: " + err));
      }
    } catch (err) {
      console.error("Browse error:", err);
    }
  };

  const handleBrowseObsidian = async () => {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
        title: "Select Obsidian Vault Directory"
      });
      if (selected && typeof selected === "string") {
        invoke("set_obsidian_vault_path", { path: selected })
          .then(() => {
            setObsidianVaultPath(selected);
            loadLogs();
          })
          .catch((err) => alert("Failed to set Obsidian path: " + err));
      }
    } catch (err) {
      console.error("Obsidian browse error:", err);
    }
  };

  const handleExportToObsidian = () => {
    if (!obsidianVaultPath) {
      alert("Please configure your Obsidian Vault path in the Settings tab first!");
      setActiveTab("settings");
      return;
    }
    invoke<string>("export_to_obsidian", { highlights })
      .then((msg) => {
        alert(msg);
        loadLogs();
      })
      .catch((err) => alert("Export failed: " + err));
  };

  const handleAddBooks = async () => {
    try {
      const selected = await open({
        multiple: true,
        filters: [{
          name: "Books",
          extensions: ["cbz", "cbr", "pdf", "epub"]
        }],
        title: "Select Books to Add"
      });
      if (selected) {
        const paths = Array.isArray(selected) ? selected : [selected];
        invoke("add_books_to_library", { paths })
          .then(() => {
            loadBooks();
            loadLogs();
          })
          .catch((err) => alert("Failed to add books: " + err));
      }
    } catch (err) {
      console.error("Add books error:", err);
    }
  };

  return (
    <div style={{ ...styles.container, flexDirection: "column" }}>
      {updateAvailable && (
        <div style={{
          backgroundColor: "#ff9500",
          color: "#000",
          padding: "10px 20px",
          textAlign: "center",
          fontWeight: "bold",
          fontSize: 13,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 15,
          zIndex: 1000
        }}>
          <span>A new update (v{updateAvailable}) is available for Inksync Companion!</span>
          <button 
            onClick={() => window.open("https://github.com/cisidro93/InksyncPro/releases/latest")}
            style={{
              backgroundColor: "#000",
              color: "#fff",
              border: "none",
              padding: "6px 14px",
              borderRadius: 6,
              cursor: "pointer",
              fontSize: 12,
              fontWeight: "bold",
              transition: "background 0.2s"
            }}
            onMouseEnter={(e) => e.currentTarget.style.backgroundColor = "#222"}
            onMouseLeave={(e) => e.currentTarget.style.backgroundColor = "#000"}
          >
            Download Update
          </button>
        </div>
      )}
      <div style={{ display: "flex", flex: 1, overflow: "hidden", width: "100vw" }}>
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
            <span>Library Shelf</span>
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
          
          {connectionInfo && !connectionInfo.includes("Loading") && (
            <div style={{ display: "flex", justifyContent: "center", marginTop: 12, padding: 8, backgroundColor: "rgba(0,0,0,0.2)", borderRadius: 8 }}>
              <img 
                src={`https://api.qrserver.com/v1/create-qr-code/?size=110x110&color=ff9500&bgcolor=1e1e24&margin=4&data=${encodeURIComponent(connectionInfo)}`} 
                alt="Scan to Connect"
                style={{ width: 110, height: 110 }}
              />
            </div>
          )}

          <div style={{ display: "flex", alignItems: "center", gap: 5, marginTop: 10 }}>
            <span style={styles.statusIndicator}></span>
            <span style={styles.statusText}>Active (_inksync Bonjour)</span>
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
                <span style={styles.statValue}>Connected</span>
                <span style={styles.statLabel}>Local Send API</span>
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
                <h3 style={styles.panelTitle}>Library Files ({books.length})</h3>
                <div style={{ display: "flex", gap: 10 }}>
                  <button onClick={handleAddBooks} style={{ ...styles.actionButton, backgroundColor: "#ff9500", color: "#000" }}>
                    <Plus size={12} style={{ marginRight: 4 }} /> Add Books
                  </button>
                  <button onClick={loadBooks} style={styles.actionButton}>
                    <RefreshCw size={12} className={isRefreshing ? "spin-animation" : ""} /> Refresh
                  </button>
                </div>
              </div>

              <div style={styles.bookList}>
                {books.length === 0 ? (
                  <div style={{ padding: 40, textAlign: "center", color: "#888" }}>
                    No books in the holding library. Drag/drop here or upload from device.
                  </div>
                ) : (
                  books.map(book => (
                    <div key={book.id} style={styles.bookCard}>
                      <div style={styles.bookFormatBadge}>{book.format}</div>
                      <div style={{ flex: 1, marginLeft: 15 }}>
                        <h4 style={styles.bookCardTitle}>{book.title}</h4>
                        <p style={styles.bookCardPath}>{book.path}</p>
                        <span style={styles.bookCardSize}>{book.size}</span>
                      </div>
                      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                        {book.status === "synced" ? (
                          <div style={styles.badgeSynced}>Synced</div>
                        ) : book.status === "converting" ? (
                          <div style={styles.badgeConverting}>
                            <RefreshCw size={12} className="spin-animation" style={{ marginRight: 6 }} />
                            Processing...
                          </div>
                        ) : (
                          <>
                            {(book.format === "CBZ" || book.format === "CBR") && (
                              <button 
                                onClick={() => handleTranscode(book.id, book.path, book.format)} 
                                style={styles.transcodeButton}
                              >
                                <Send size={12} style={{ marginRight: 6 }} /> Transcode
                              </button>
                            )}
                            
                            <div style={{ position: "relative" }}>
                              <button 
                                onClick={() => {
                                  setActiveDeviceDropdown(activeDeviceDropdown === book.id ? null : book.id);
                                  scanDevices();
                                }} 
                                style={{
                                  display: "flex",
                                  alignItems: "center",
                                  backgroundColor: "#34c759",
                                  color: "#000",
                                  border: "none",
                                  padding: "6px 12px",
                                  borderRadius: 6,
                                  fontSize: 12,
                                  cursor: "pointer",
                                  fontWeight: "bold",
                                  transition: "background 0.2s"
                                }}
                              >
                                <Smartphone size={12} style={{ marginRight: 6 }} /> Send to...
                              </button>
                              
                              {activeDeviceDropdown === book.id && (
                                <div style={styles.deviceDropdown}>
                                  <div style={styles.deviceDropdownHeader}>Discovered Devices</div>
                                  {isScanning && devices.length === 0 && (
                                    <div style={styles.deviceDropdownEmpty}>Scanning...</div>
                                  )}
                                  {!isScanning && devices.length === 0 && (
                                    <div style={styles.deviceDropdownEmpty}>No active devices found. Make sure Wi-Fi Transfer is started on iPad/Android.</div>
                                  )}
                                  {devices.map(dev => (
                                    <button
                                      key={dev.ip}
                                      onClick={() => handleSendToDevice(book.id, book.path, dev)}
                                      style={styles.deviceDropdownItem}
                                      onMouseEnter={(e) => e.currentTarget.style.backgroundColor = "rgba(255, 255, 255, 0.05)"}
                                      onMouseLeave={(e) => e.currentTarget.style.backgroundColor = "transparent"}
                                    >
                                      <Smartphone size={12} color="#ff9500" />
                                      <span>{dev.alias.toUpperCase()}</span>
                                    </button>
                                  ))}
                                </div>
                              )}
                            </div>

                            <button 
                              onClick={() => handleDelete(book.path)} 
                              style={styles.deleteButton}
                              title="Delete from Library"
                            >
                              <Trash2 size={14} />
                            </button>
                          </>
                        )}
                      </div>
                    </div>
                  ))
                )}
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
                {logs.length === 0 ? (
                  <div style={{ color: "#555" }}>System active. Waiting for events...</div>
                ) : (
                  logs.map((log, idx) => (
                    <div key={idx} style={styles.logLine}>
                      <span style={styles.logTimestamp}>[SYSTEM]</span> {log}
                    </div>
                  ))
                )}
              </div>
            </div>
          </div>
        )}

        {activeTab === "highlights" && (
          <div style={styles.pageLayoutSingle}>
            <div style={styles.panelHeader}>
              <h3 style={styles.panelTitle}>Aggregated Annotation Log ({highlights.length})</h3>
              <button onClick={handleExportToObsidian} style={{ ...styles.actionButton, backgroundColor: "#ff9500", color: "#000" }}>
                <Download size={14} style={{ marginRight: 6 }} /> Export to Obsidian
              </button>
            </div>

            <div style={styles.highlightsGrid}>
              {highlights.length === 0 ? (
                <div style={{ padding: 40, textAlign: "center", color: "#888", width: "100%" }}>
                  No annotations synced yet. Annotations created on your iOS or Android app will sync here over WiFi.
                </div>
              ) : (
                highlights.map(h => {
                  const bookTitle = h.readwise_book_title || "Unknown Book";
                  const text = h.selected_text || "";
                  const note = h.note_text || "";
                  const page = h.page_index >= 0 ? h.page_index + 1 : 1;
                  const dateStr = h.modified_at ? new Date(h.modified_at).toLocaleDateString() : "Just now";
                  
                  return (
                    <div key={h.id} style={styles.highlightCard}>
                      <div style={styles.highlightHeader}>
                        <span style={styles.highlightBook}>{bookTitle}</span>
                        <span style={styles.highlightTime}>{dateStr}</span>
                      </div>
                      {text && <p style={styles.highlightText}>"{text}"</p>}
                      {note && (
                        <div style={styles.highlightNoteCard}>
                          <span style={{ fontSize: 10, fontWeight: "bold", color: "#ff9500", textTransform: "uppercase" }}>Analysis Notes</span>
                          <p style={styles.highlightNoteText}>{note}</p>
                        </div>
                      )}
                      <div style={styles.highlightFooter}>
                        <span>Page {page}</span>
                        {h.tags && <span style={{ color: "#aaa", fontSize: 11 }}>🏷️ {h.tags}</span>}
                      </div>
                    </div>
                  );
                })
              )}
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
                    <input type="text" value={libraryPath} readOnly style={styles.settingsInput} />
                    <button onClick={handleBrowse} style={{ ...styles.actionButton, backgroundColor: "#ff9500", color: "#000" }}>
                      <FolderOpen size={14} style={{ marginRight: 4 }} /> Browse
                    </button>
                  </div>
                </div>
              </div>

              <div style={styles.settingsGroup}>
                <h4 style={styles.settingsGroupTitle}>Obsidian Zettelkasten Integration</h4>
                <div style={styles.settingsRow}>
                  <label style={styles.settingsLabel}>Obsidian Vault Path</label>
                  <div style={{ display: "flex", gap: 10, flex: 1 }}>
                    <input type="text" value={obsidianVaultPath} readOnly placeholder="Not connected. Select your Obsidian Vault folder..." style={styles.settingsInput} />
                    <button onClick={handleBrowseObsidian} style={{ ...styles.actionButton, backgroundColor: "#ff9500", color: "#000" }}>
                      <FolderOpen size={14} style={{ marginRight: 4 }} /> Link Vault
                    </button>
                  </div>
                </div>
              </div>

              <div style={styles.settingsGroup}>
                <h4 style={styles.settingsGroupTitle}>Bonjour Discovery</h4>
                <div style={styles.settingsRow}>
                  <label style={styles.settingsLabel}>Zeroconf Type</label>
                  <div style={{ flex: 1, fontSize: 13, color: "#888" }}>
                    _inksync._tcp.local. (Active)
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
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
    fontWeight: "bold",
    transition: "background 0.2s"
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
  deleteButton: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "rgba(239, 68, 68, 0.1)",
    color: "#ef4444",
    border: "1px solid rgba(239, 68, 68, 0.2)",
    padding: 6,
    borderRadius: 6,
    cursor: "pointer",
    transition: "background 0.2s"
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
  },
  deviceDropdown: {
    position: "absolute",
    right: 0,
    top: "100%",
    backgroundColor: "#1e1e28",
    border: "1px solid rgba(255, 255, 255, 0.1)",
    borderRadius: 8,
    boxShadow: "0 4px 12px rgba(0,0,0,0.5)",
    zIndex: 100,
    width: 220,
    padding: 6,
    marginTop: 4,
    display: "flex",
    flexDirection: "column",
    gap: 4
  },
  deviceDropdownItem: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    backgroundColor: "transparent",
    color: "#fff",
    border: "none",
    padding: "8px 12px",
    borderRadius: 6,
    fontSize: 12,
    cursor: "pointer",
    textAlign: "left",
    transition: "background 0.2s",
    width: "100%"
  },
  deviceDropdownHeader: {
    fontSize: 10,
    color: "#888",
    padding: "4px 8px",
    fontWeight: "bold",
    textTransform: "uppercase"
  },
  deviceDropdownEmpty: {
    fontSize: 11,
    color: "#aaa",
    padding: "8px",
    textAlign: "center"
  }
};
