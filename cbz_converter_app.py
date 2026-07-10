import sys
import os
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                             QLabel, QListWidget, QProgressBar, QMessageBox, 
                             QCheckBox, QSpinBox, QHBoxLayout, QPushButton, 
                             QFileDialog, QComboBox, QListWidgetItem, QTabWidget,
                             QLineEdit, QSystemTrayIcon, QMenu)
from PySide6.QtGui import QIcon, QAction
from PySide6.QtCore import QSettings, Qt

from worker import ConversionThread
from ui_components import DropZone, EmailConfigDialog
from styles import COMIC_STYLE
from utils import resource_path

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Inksync Desktop Companion")
        self.setWindowIcon(QIcon(resource_path("app_icon.png")))
        self.resize(550, 750)

        # Central Widget & Main Layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setSpacing(10)
        main_layout.setContentsMargins(15, 15, 15, 15)

        # Tab Widget
        self.tabs = QTabWidget()
        main_layout.addWidget(self.tabs)

        # --- TAB 1: CONVERTER & QUEUE ---
        self.tab_converter = QWidget()
        layout = QVBoxLayout(self.tab_converter)
        layout.setSpacing(12)
        layout.setContentsMargins(10, 10, 10, 10)

        self.drop_zone = DropZone()
        self.drop_zone.file_dropped.connect(self.add_to_queue)
        layout.addWidget(self.drop_zone)

        # Options Group
        options_layout = QVBoxLayout()
        
        # Format Option
        format_layout = QHBoxLayout()
        format_label = QLabel("Output Format:")
        format_label.setStyleSheet("font-weight: bold;")
        self.format_combo = QComboBox()
        self.format_combo.addItems(["EPUB", "PDF"])
        self.format_combo.currentIndexChanged.connect(self.on_format_changed)
        format_layout.addWidget(format_label)
        format_layout.addWidget(self.format_combo)
        options_layout.addLayout(format_layout)

        # Compression Option
        self.compress_checkbox = QCheckBox("Compress Images / Optimize for E-Ink")
        options_layout.addWidget(self.compress_checkbox)

        # Max Size Option
        size_layout = QHBoxLayout()
        self.limit_size_checkbox = QCheckBox("Limit Output Size:")
        self.limit_size_checkbox.setChecked(True)
        
        self.size_preset_combo = QComboBox()
        self.size_preset_combo.addItems(["25 MB (Gmail)", "50 MB", "200 MB", "Custom"])
        self.size_preset_combo.setCurrentIndex(2) # Default to 200 MB
        
        self.size_spinbox = QSpinBox()
        self.size_spinbox.setRange(1, 1000)
        self.size_spinbox.setValue(200)
        self.size_spinbox.setSuffix(" MB")
        self.size_spinbox.setEnabled(False) # Default hidden/disabled
        self.size_spinbox.hide()

        self.limit_size_checkbox.toggled.connect(self.toggle_size_options)
        self.size_preset_combo.currentIndexChanged.connect(self.on_preset_changed)
        
        size_layout.addWidget(self.limit_size_checkbox)
        size_layout.addWidget(self.size_preset_combo)
        size_layout.addWidget(self.size_spinbox)
        options_layout.addLayout(size_layout)

        # Kindle Option
        kindle_layout = QHBoxLayout()
        self.kindle_checkbox = QCheckBox("Send to Kindle (SMTP Email)")
        self.settings_btn = QPushButton("Email Settings")
        self.settings_btn.clicked.connect(self.open_settings)
        
        kindle_layout.addWidget(self.kindle_checkbox)
        kindle_layout.addWidget(self.settings_btn)
        options_layout.addLayout(kindle_layout)

        # Output Folder Option
        folder_layout = QHBoxLayout()
        self.select_folder_btn = QPushButton("Change Holding Folder...")
        self.select_folder_btn.clicked.connect(self.select_output_folder)
        self.folder_label = QLabel("Default Shelf (webapp/downloads)")
        self.folder_label.setStyleSheet("color: #888; font-style: italic;")
        
        folder_layout.addWidget(self.select_folder_btn)
        folder_layout.addWidget(self.folder_label)
        options_layout.addLayout(folder_layout)
        
        layout.addLayout(options_layout)

        # Progress Section
        self.progress_bar = QProgressBar()
        self.progress_bar.setValue(0)
        self.progress_bar.setTextVisible(True)
        layout.addWidget(self.progress_bar)

        self.status_label = QLabel("Ready")
        self.status_label.setStyleSheet("font-weight: bold;")
        layout.addWidget(self.status_label)

        # Queue List
        list_label = QLabel("Conversion Queue:")
        layout.addWidget(list_label)
        
        self.list_widget = QListWidget()
        layout.addWidget(self.list_widget)

        # Action Buttons
        action_layout = QHBoxLayout()
        self.start_btn = QPushButton("Start Conversion")
        self.start_btn.setStyleSheet("background-color: #10B981; color: white;") # Green
        self.start_btn.clicked.connect(self.start_conversion)
        action_layout.addWidget(self.start_btn)

        # Clear Button
        self.clear_btn = QPushButton("Clear Completed")
        self.clear_btn.clicked.connect(self.clear_completed)
        action_layout.addWidget(self.clear_btn)
        
        layout.addLayout(action_layout)
        self.tabs.addTab(self.tab_converter, "Converter Queue")

        # --- TAB 2: HOLDING SHELF LIBRARY ---
        self.tab_library = QWidget()
        lib_layout = QVBoxLayout(self.tab_library)
        lib_layout.setSpacing(10)
        lib_layout.setContentsMargins(10, 10, 10, 10)

        # Search / Filter & Refresh
        lib_top = QHBoxLayout()
        lib_search_label = QLabel("Search:")
        lib_search_label.setStyleSheet("font-weight: bold;")
        self.lib_search = QLineEdit()
        self.lib_search.setPlaceholderText("Search library files...")
        self.lib_search.textChanged.connect(self.filter_library)
        
        self.lib_refresh_btn = QPushButton("Refresh")
        self.lib_refresh_btn.setFixedWidth(80)
        self.lib_refresh_btn.clicked.connect(self.refresh_library)
        
        lib_top.addWidget(lib_search_label)
        lib_top.addWidget(self.lib_search)
        lib_top.addWidget(self.lib_refresh_btn)
        lib_layout.addLayout(lib_top)

        # List of holding files
        self.lib_list = QListWidget()
        self.lib_list.doubleClicked.connect(self.open_library_file)
        lib_layout.addWidget(self.lib_list)

        # Summary label
        self.lib_summary_label = QLabel("Total: 0 files (0.0 MB)")
        self.lib_summary_label.setStyleSheet("color: #FF9900; font-weight: bold;")
        lib_layout.addWidget(self.lib_summary_label)

        # Action Buttons
        lib_actions = QHBoxLayout()
        self.lib_open_btn = QPushButton("Open File")
        self.lib_open_btn.clicked.connect(self.open_library_file)
        
        self.lib_reveal_btn = QPushButton("Show in Folder")
        self.lib_reveal_btn.clicked.connect(self.reveal_library_folder)
        
        self.lib_delete_btn = QPushButton("Delete")
        self.lib_delete_btn.setStyleSheet("background-color: #EF4444; color: white;")
        self.lib_delete_btn.clicked.connect(self.delete_library_file)
        
        lib_actions.addWidget(self.lib_open_btn)
        lib_actions.addWidget(self.lib_reveal_btn)
        lib_actions.addWidget(self.lib_delete_btn)
        lib_layout.addLayout(lib_actions)
        self.tabs.addTab(self.tab_library, "Holding Shelf Library")

        # Global Divider
        divider = QWidget()
        divider.setFixedHeight(2)
        divider.setStyleSheet("background-color: #444444;")
        main_layout.addWidget(divider)

        # --- GLOBAL BOTTOM WEB SERVER CONTROL PANEL ---
        server_group = QVBoxLayout()
        server_label_layout = QHBoxLayout()
        server_label = QLabel("iPadOS / Remote Access:")
        server_label.setStyleSheet("font-weight: bold; color: #60A5FA;")
        server_label_layout.addWidget(server_label)
        
        self.server_status_indicator = QLabel("Stopped")
        self.server_status_indicator.setStyleSheet("color: #F87171;") # Red
        server_label_layout.addWidget(self.server_status_indicator)
        server_label_layout.addStretch()

        self.autostart_server_checkbox = QCheckBox("Auto-Start Server")
        server_label_layout.addWidget(self.autostart_server_checkbox)
        server_group.addLayout(server_label_layout)

        server_btn_layout = QHBoxLayout()
        self.start_server_btn = QPushButton("Start Web Server")
        self.start_server_btn.clicked.connect(self.toggle_server)
        server_btn_layout.addWidget(self.start_server_btn)

        self.open_browser_btn = QPushButton("Open in Browser")
        self.open_browser_btn.setEnabled(False)
        self.open_browser_btn.clicked.connect(self.open_browser)
        server_btn_layout.addWidget(self.open_browser_btn)
        server_group.addLayout(server_btn_layout)

        self.server_url_label = QLabel("")
        self.server_url_label.setStyleSheet("color: #888; font-size: 11px;")
        server_group.addWidget(self.server_url_label)
        main_layout.addLayout(server_group)

        # System Tray Icon Setup
        self.setup_tray_icon()

        # State Variables
        self.is_processing = False
        self.current_thread = None
        self.output_dir = None
        self.server_thread = None
        self.server_url = None
        self.zc = None
        self.zc_info = None

        # Load persisted settings and refresh library
        self.load_settings()
        self.refresh_library()

        # Auto-start server if enabled
        if self.autostart_server_checkbox.isChecked():
            from PySide6.QtCore import QTimer
            QTimer.singleShot(500, self.toggle_server)

    def setup_tray_icon(self):
        self.tray_icon = QSystemTrayIcon(self)
        self.tray_icon.setIcon(QIcon(resource_path("app_icon.png")))
        
        # Tray menu
        tray_menu = QMenu(self)
        restore_action = QAction("Open Companion", self)
        restore_action.triggered.connect(self.showNormal)
        
        toggle_server_action = QAction("Start/Stop Server", self)
        toggle_server_action.triggered.connect(self.toggle_server)
        
        open_folder_action = QAction("Open Library Folder", self)
        open_folder_action.triggered.connect(self.reveal_library_folder)
        
        quit_action = QAction("Exit", self)
        quit_action.triggered.connect(QApplication.instance().quit)
        
        tray_menu.addAction(restore_action)
        tray_menu.addAction(toggle_server_action)
        tray_menu.addAction(open_folder_action)
        tray_menu.addSeparator()
        tray_menu.addAction(quit_action)
        
        self.tray_icon.setContextMenu(tray_menu)
        self.tray_icon.activated.connect(self.on_tray_icon_activated)
        self.tray_icon.show()

    def on_tray_icon_activated(self, reason):
        if reason == QSystemTrayIcon.Trigger:
            if self.isVisible():
                self.hide()
            else:
                self.showNormal()
                self.activateWindow()

    def load_settings(self):
        settings = QSettings("Antigravity", "InksyncDesktop")
        
        # Load Converter Options
        self.format_combo.setCurrentText(settings.value("format", "PDF"))
        self.compress_checkbox.setChecked(settings.value("compress", "false") == "true")
        self.limit_size_checkbox.setChecked(settings.value("limit_size", "true") == "true")
        self.size_preset_combo.setCurrentText(settings.value("size_preset", "200 MB"))
        self.size_spinbox.setValue(int(settings.value("size_custom", 200)))
        self.kindle_checkbox.setChecked(settings.value("send_to_kindle", "false") == "true")
        
        # Load Output Shelf Folder
        saved_dir = settings.value("output_dir", "")
        if saved_dir and os.path.exists(saved_dir):
            self.output_dir = saved_dir
            self.folder_label.setText(f"Output: {saved_dir}")
            self.folder_label.setStyleSheet("") # reset style
            
        # Load Server Settings
        self.autostart_server_checkbox.setChecked(settings.value("autostart_server", "false") == "true")
        self.on_format_changed(self.format_combo.currentIndex())

    def save_settings(self):
        settings = QSettings("Antigravity", "InksyncDesktop")
        
        # Save Converter Options
        settings.setValue("format", self.format_combo.currentText())
        settings.setValue("compress", "true" if self.compress_checkbox.isChecked() else "false")
        settings.setValue("limit_size", "true" if self.limit_size_checkbox.isChecked() else "false")
        settings.setValue("size_preset", self.size_preset_combo.currentText())
        settings.setValue("size_custom", self.size_spinbox.value())
        settings.setValue("send_to_kindle", "true" if self.kindle_checkbox.isChecked() else "false")
        
        # Save Output Shelf Folder
        if self.output_dir:
            settings.setValue("output_dir", self.output_dir)
            
        # Save Server Settings
        settings.setValue("autostart_server", "true" if self.autostart_server_checkbox.isChecked() else "false")

    def register_zeroconf(self):
        try:
            from zeroconf import Zeroconf, ServiceInfo
            import socket
            
            # Get local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.connect(("8.8.8.8", 80))
                local_ip = s.getsockname()[0]
            except Exception:
                local_ip = "127.0.0.1"
            finally:
                s.close()
                
            self.zc = Zeroconf()
            hostname = socket.gethostname() or "DesktopCompanion"
            desc = {'alias': 'Inksync Desktop Companion'}
            self.zc_info = ServiceInfo(
                "_inksync._tcp.local.",
                f"{hostname}._inksync._tcp.local.",
                addresses=[socket.inet_aton(local_ip)],
                port=5000,
                properties=desc,
                server=f"{hostname}.local.",
            )
            self.zc.register_service(self.zc_info)
            print(f"Registered desktop companion as Zeroconf service: {hostname} at {local_ip}")
        except Exception as e:
            print(f"Failed to register Zeroconf service: {e}")
            self.zc = None
            self.zc_info = None

    def unregister_zeroconf(self):
        try:
            if hasattr(self, 'zc') and self.zc:
                if hasattr(self, 'zc_info') and self.zc_info:
                    self.zc.unregister_service(self.zc_info)
                self.zc.close()
                self.zc = None
                self.zc_info = None
                print("Unregistered desktop companion Zeroconf service")
        except Exception as e:
            print(f"Failed to unregister Zeroconf service: {e}")

    def toggle_server(self):
        if self.server_thread and self.server_thread.is_running:
            # Stop Server
            self.server_thread.stop()
            self.start_server_btn.setText("Stopping...")
            self.start_server_btn.setEnabled(False)
            self.unregister_zeroconf()
        else:
            # Start Server
            from web_server_thread import WebServerThread
            self.server_thread = WebServerThread()
            self.server_thread.server_started.connect(self.on_server_started)
            self.server_thread.server_stopped.connect(self.on_server_stopped)
            self.server_thread.error_occurred.connect(self.on_server_error)
            self.server_thread.start()
            self.start_server_btn.setText("Starting...")
            self.start_server_btn.setEnabled(False)

    def on_server_started(self, url):
        self.server_url = url
        self.start_server_btn.setText("Stop Web Server")
        self.start_server_btn.setEnabled(True)
        self.server_status_indicator.setText("Running")
        self.server_status_indicator.setStyleSheet("color: #34D399;") # Green
        self.open_browser_btn.setEnabled(True)
        self.server_url_label.setText(f"Serving at {url}")
        self.register_zeroconf()

    def on_server_stopped(self):
        self.server_url = None
        self.start_server_btn.setText("Start Web Server")
        self.start_server_btn.setEnabled(True)
        self.server_status_indicator.setText("Stopped")
        self.server_status_indicator.setStyleSheet("color: #F87171;")
        self.open_browser_btn.setEnabled(False)
        self.server_url_label.setText("")
        self.unregister_zeroconf()

    def on_server_error(self, error_msg):
        QMessageBox.critical(self, "Server Error", f"Web Server failed: {error_msg}")
        self.on_server_stopped()

    def closeEvent(self, event):
        if self.tray_icon.isVisible() and self.server_thread and self.server_thread.is_running:
            event.ignore()
            self.hide()
            self.tray_icon.showMessage(
                "Inksync Companion Running",
                "The web server is still active in the background. Click the tray icon to restore.",
                QSystemTrayIcon.Information, 3000
            )
        else:
            self.unregister_zeroconf()
            if self.server_thread and self.server_thread.is_running:
                self.server_thread.stop()
            self.save_settings()
            event.accept()

    def open_browser(self):
        if self.server_url:
            import webbrowser
            webbrowser.open(self.server_url)

    def select_output_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "Select Output Folder")
        if folder:
            self.output_dir = folder
            self.folder_label.setText(f"Output: {folder}")
            self.folder_label.setStyleSheet("") # Reset style
            # Refresh library to show files in the new output folder
            self.refresh_library()

    def open_settings(self):
        dialog = EmailConfigDialog(self)
        dialog.exec()

    def add_to_queue(self, file_path):
        file_name = os.path.basename(file_path)
        # Create item
        item = QListWidgetItem(file_name)
        # Store full path in UserRole
        item.setData(Qt.UserRole, file_path)
        # Make editable
        item.setFlags(item.flags() | Qt.ItemIsEditable)
        item.setToolTip("Double-click to rename output file")
        self.list_widget.addItem(item)

    def start_conversion(self):
        self.process_next()

    def clear_completed(self):
        for i in range(self.list_widget.count() - 1, -1, -1):
            item = self.list_widget.item(i)
            if item.text().startswith("Done:") or item.text().startswith("Error:"):
                self.list_widget.takeItem(i)

    def process_next(self):
        if self.is_processing:
            return

        queue_item = None
        queue_index = -1
        
        for i in range(self.list_widget.count()):
            item = self.list_widget.item(i)
            file_path = item.data(Qt.UserRole)
            if file_path:
                queue_item = item
                queue_index = i
                break
        
        if not queue_item:
            return

        self.is_processing = True
        file_path = queue_item.data(Qt.UserRole)
        output_name = queue_item.text()
        output_stem = os.path.splitext(output_name)[0]
        
        # Remove item from queue
        self.list_widget.takeItem(queue_index)
        self.status_label.setText(f"Processing: {output_stem}")
        self.progress_bar.setValue(0)

        compress = self.compress_checkbox.isChecked()
        max_size_mb = self.size_spinbox.value() if self.limit_size_checkbox.isChecked() else None
        send_to_kindle = self.kindle_checkbox.isChecked()
        
        email_config = None
        if send_to_kindle:
            settings = QSettings("Antigravity", "CBZtoPDF")
            email_config = {
                'sender': settings.value("sender_email", ""),
                'password': settings.value("sender_password", ""),
                'kindle_email': settings.value("kindle_email", ""),
                'smtp_server': settings.value("smtp_server", "smtp.gmail.com"),
                'smtp_port': settings.value("smtp_port", "587")
            }
            
            if not email_config['sender'] or not email_config['password'] or not email_config['kindle_email']:
                QMessageBox.warning(self, "Missing Configuration", "Please configure email settings to use Send to Kindle.")
                self.is_processing = False
                return

        self.current_thread = ConversionThread(file_path, compress=compress, max_size_mb=max_size_mb, 
                                             output_dir=self.output_dir, send_to_kindle=send_to_kindle, 
                                             email_config=email_config, output_name=output_stem,
                                             output_format=self.format_combo.currentText())
        self.current_thread.progress_signal.connect(self.update_progress)
        self.current_thread.finished_signal.connect(lambda success, msg: self.conversion_finished(success, msg))
        self.current_thread.start()

    def update_progress(self, percentage, message):
        self.progress_bar.setValue(percentage)
        self.status_label.setText(message)

    def conversion_finished(self, success, message):
        self.is_processing = False
        self.current_thread = None
        
        if success:
            self.list_widget.addItem(f"Done: {message}")
            self.status_label.setText("Ready")
            self.progress_bar.setValue(100)
            self.refresh_library()
        else:
            self.list_widget.addItem(f"Error: {message}")
            self.status_label.setText("Error occurred")
            self.progress_bar.setValue(0)
            QMessageBox.critical(self, "Conversion Error", message)
        
        self.process_next()

    def toggle_size_options(self, checked):
        is_pdf = self.format_combo.currentText() == "PDF"
        self.size_preset_combo.setEnabled(checked and is_pdf)
        if checked and is_pdf and self.size_preset_combo.currentText() == "Custom":
            self.size_spinbox.setVisible(True)
            self.size_spinbox.setEnabled(True)
        else:
            self.size_spinbox.setVisible(False)
            self.size_spinbox.setEnabled(False)

    def on_preset_changed(self, index):
        text = self.size_preset_combo.currentText()
        if text == "Custom":
            self.size_spinbox.setVisible(True)
            self.size_spinbox.setEnabled(True)
        else:
            self.size_spinbox.setVisible(False)
            self.size_spinbox.setEnabled(False)
            if "25 MB" in text:
                self.size_spinbox.setValue(25)
            elif "50 MB" in text:
                self.size_spinbox.setValue(50)
            elif "200 MB" in text:
                self.size_spinbox.setValue(200)

    def on_format_changed(self, index):
        is_pdf = self.format_combo.currentText() == "PDF"
        self.limit_size_checkbox.setEnabled(is_pdf)
        self.size_preset_combo.setEnabled(is_pdf and self.limit_size_checkbox.isChecked())
        if not is_pdf:
            self.size_spinbox.setEnabled(False)
            self.size_spinbox.hide()
            self.limit_size_checkbox.setStyleSheet("color: #888888;")
        else:
            self.limit_size_checkbox.setStyleSheet("")
            self.toggle_size_options(self.limit_size_checkbox.isChecked())

    def get_library_dir(self):
        if self.output_dir and os.path.exists(self.output_dir):
            return self.output_dir
        base_dir = os.path.dirname(os.path.abspath(__file__))
        downloads_dir = os.path.join(base_dir, "webapp", "downloads")
        os.makedirs(downloads_dir, exist_ok=True)
        return downloads_dir

    def refresh_library(self):
        self.lib_list.clear()
        lib_dir = self.get_library_dir()
        total_size_bytes = 0
        total_files = 0
        
        try:
            for file in os.listdir(lib_dir):
                if not file.startswith('.'):
                    file_path = os.path.join(lib_dir, file)
                    if os.path.isfile(file_path):
                        total_files += 1
                        size_bytes = os.path.getsize(file_path)
                        total_size_bytes += size_bytes
                        size_mb = size_bytes / (1024 * 1024)
                        
                        clean_name = file.split('_', 1)[1] if '_' in file else file
                        
                        item = QListWidgetItem(f"{clean_name.upper()} ({size_mb:.1f} MB)")
                        item.setData(Qt.UserRole, file_path)
                        self.lib_list.addItem(item)
        except Exception as e:
            print(f"Failed to scan library directory: {e}")
            
        mb_total = total_size_bytes / (1024 * 1024)
        self.lib_summary_label.setText(f"Total: {total_files} files ({mb_total:.1f} MB)")
        self.filter_library()

    def filter_library(self):
        filter_text = self.lib_search.text().lower().strip()
        for i in range(self.lib_list.count()):
            item = self.lib_list.item(i)
            item.setHidden(filter_text not in item.text().lower())

    def open_library_file(self):
        item = self.lib_list.currentItem()
        if not item:
            QMessageBox.information(self, "No Selection", "Please select a file to open.")
            return
        file_path = item.data(Qt.UserRole)
        if file_path and os.path.exists(file_path):
            import webbrowser
            webbrowser.open(file_path)

    def reveal_library_folder(self):
        item = self.lib_list.currentItem()
        lib_dir = self.get_library_dir()
        file_path = item.data(Qt.UserRole) if item else None
        
        import platform
        import subprocess
        
        target = file_path if (file_path and os.path.exists(file_path)) else lib_dir
        
        try:
            if platform.system() == "Windows":
                if file_path and os.path.exists(file_path):
                    subprocess.run(["explorer", "/select,", os.path.normpath(file_path)])
                else:
                    subprocess.run(["explorer", os.path.normpath(lib_dir)])
            elif platform.system() == "Darwin": # macOS
                subprocess.run(["open", "-R", target] if file_path else ["open", target])
            else: # Linux / generic
                subprocess.run(["xdg-open", os.path.dirname(target) if file_path else target])
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to reveal folder: {e}")

    def delete_library_file(self):
        item = self.lib_list.currentItem()
        if not item:
            QMessageBox.information(self, "No Selection", "Please select a file to delete.")
            return
        file_path = item.data(Qt.UserRole)
        clean_name = item.text().split(' (')[0]
        
        reply = QMessageBox.question(
            self, "Confirm Delete", 
            f"Are you sure you want to delete \"{clean_name}\" from the holding library?",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No
        )
        
        if reply == QMessageBox.Yes:
            try:
                if file_path and os.path.exists(file_path):
                    os.remove(file_path)
                    self.refresh_library()
            except Exception as e:
                QMessageBox.critical(self, "Error", f"Failed to delete file: {e}")

if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setStyleSheet(COMIC_STYLE)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())
