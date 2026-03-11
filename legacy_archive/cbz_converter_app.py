import sys
import os
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                             QLabel, QListWidget, QProgressBar, QMessageBox, 
                             QCheckBox, QSpinBox, QHBoxLayout, QPushButton, 
                             QFileDialog, QComboBox, QListWidgetItem)
from PySide6.QtGui import QIcon
from PySide6.QtCore import QSettings, Qt

from worker import ConversionThread
from ui_components import DropZone, EmailConfigDialog
from styles import COMIC_STYLE
from utils import resource_path

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("CBZ to PDF Converter")
        self.setWindowIcon(QIcon(resource_path("app_icon.png")))
        self.resize(500, 700)

        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        layout.setSpacing(15)
        layout.setContentsMargins(20, 20, 20, 20)

        self.drop_zone = DropZone()
        self.drop_zone.file_dropped.connect(self.add_to_queue)
        layout.addWidget(self.drop_zone)

        # Options Group
        options_layout = QVBoxLayout()
        
        # Compression Option
        self.compress_checkbox = QCheckBox("Compress Output (Simple)")
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
        self.kindle_checkbox = QCheckBox("Send to Kindle")
        self.settings_btn = QPushButton("Email Settings")
        self.settings_btn.clicked.connect(self.open_settings)
        
        kindle_layout.addWidget(self.kindle_checkbox)
        kindle_layout.addWidget(self.settings_btn)
        options_layout.addLayout(kindle_layout)

        # Output Folder Option
        folder_layout = QHBoxLayout()
        self.select_folder_btn = QPushButton("Save PDF to...")
        self.select_folder_btn.clicked.connect(self.select_output_folder)
        self.folder_label = QLabel("Default (Same as Input)")
        self.folder_label.setStyleSheet("color: #888; font-style: italic;")
        
        folder_layout.addWidget(self.select_folder_btn)
        folder_layout.addWidget(self.folder_label)
        options_layout.addLayout(folder_layout)
        
        layout.addLayout(options_layout)

        # Web Server Section
        server_group = QVBoxLayout()
        server_label_layout = QHBoxLayout()
        server_label = QLabel("iPadOS / Remote Access:")
        server_label.setStyleSheet("font-weight: bold; color: #60A5FA;")
        server_label_layout.addWidget(server_label)
        
        self.server_status_indicator = QLabel("Stopped")
        self.server_status_indicator.setStyleSheet("color: #F87171;") # Red for stopped
        server_label_layout.addWidget(self.server_status_indicator)
        server_label_layout.addStretch()
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
        self.server_url_label.setStyleSheet("color: #888; font-size: 10px;")
        server_group.addWidget(self.server_url_label)

        layout.addLayout(server_group)

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

        self.is_processing = False
        self.current_thread = None
        self.output_dir = None
        
        self.server_thread = None
        self.server_url = None

    def toggle_server(self):
        if self.server_thread and self.server_thread.is_running:
            # Stop Server
            self.server_thread.stop()
            self.start_server_btn.setText("Stopping...")
            self.start_server_btn.setEnabled(False)
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

    def on_server_stopped(self):
        self.server_url = None
        self.start_server_btn.setText("Start Web Server")
        self.start_server_btn.setEnabled(True)
        self.server_status_indicator.setText("Stopped")
        self.server_status_indicator.setStyleSheet("color: #F87171;")
        self.open_browser_btn.setEnabled(False)
        self.server_url_label.setText("")

    def on_server_error(self, error_msg):
        QMessageBox.critical(self, "Server Error", f"Web Server failed: {error_msg}")
        self.on_server_stopped()

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
        else:
            pass

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
        # Remove items that start with "Done:" or "Error:"
        # Iterate backwards to avoid index issues
        for i in range(self.list_widget.count() - 1, -1, -1):
            item = self.list_widget.item(i)
            if item.text().startswith("Done:") or item.text().startswith("Error:"):
                self.list_widget.takeItem(i)

    def process_next(self):
        if self.is_processing:
            return

        # Find next item to process
        # We look for items that have UserRole data (file path) and are not marked done/error
        # We can identify done/error items by their background color or disabled state, 
        # OR we can simply look for items that are valid file paths in UserRole and haven't been modified to say "Done:"?
        # A cleaner way: The "Done:" items are NEW items added by conversion_finished.
        # The original Queue items are still there? NO, previously we didn't remove them.
        # Let's iterate and find the first item that is editable (which means it's a queue item)
        # AND likely needs processing.
        # BETTER: We pop the item from the list? No, user might want to keep history.
        # Let's use a custom role to mark status? Or just remove it from queue and add a log item?
        # Removing from queue and adding log item is closest to previous behavior (queue list + log items).
        
        # Iterate to find first Queue Item
        queue_item = None
        queue_index = -1
        
        for i in range(self.list_widget.count()):
            item = self.list_widget.item(i)
            # Check if it's a queue item (has file path in UserRole)
            file_path = item.data(Qt.UserRole)
            if file_path:
                queue_item = item
                queue_index = i
                break
        
        if not queue_item:
            return

        self.is_processing = True
        
        # Get data
        file_path = queue_item.data(Qt.UserRole)
        # Output Name comes from the ITEM TEXT (which might have been edited)
        output_name = queue_item.text()
        # Remove extension if user typed it, to be safe, or just pass it as stem?
        # Worker expects stem or full name? Worker uses `output_name if ... else input.stem`.
        # So we should pass the name without extension if we want worker to add .pdf, 
        # OR just pass what the user typed?
        # If user typed "MyComic.pdf", stem is "MyComic".
        # Let's strip extension just in case user got confused.
        output_stem = os.path.splitext(output_name)[0]
        
        # Remove item from queue (visual + logical)
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
                                             email_config=email_config, output_name=output_stem)
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
        else:
            self.list_widget.addItem(f"Error: {message}")
            self.status_label.setText("Error occurred")
            self.progress_bar.setValue(0)
            QMessageBox.critical(self, "Conversion Error", message)
        
        self.process_next()

    def toggle_size_options(self, checked):
        self.size_preset_combo.setEnabled(checked)
        if checked and self.size_preset_combo.currentText() == "Custom":
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
            # Update spinbox value to match preset for logic compatibility
            if "25 MB" in text:
                self.size_spinbox.setValue(25)
            elif "50 MB" in text:
                self.size_spinbox.setValue(50)
            elif "200 MB" in text:
                self.size_spinbox.setValue(200)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setStyleSheet(COMIC_STYLE)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())
