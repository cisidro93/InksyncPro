import sys
import os
from pathlib import Path
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                             QLabel, QListWidget, QProgressBar, QMessageBox, 
                             QCheckBox, QSpinBox, QHBoxLayout, QPushButton, 
                             QFileDialog)
from PySide6.QtCore import QSettings
from qt_material import apply_stylesheet

from worker import ConversionThread
from ui_components import DropZone, EmailConfigDialog

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("CBZ to PDF Converter")
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
        self.limit_size_checkbox = QCheckBox("Limit Output Size (MB):")
        self.limit_size_checkbox.setChecked(True)
        self.size_spinbox = QSpinBox()
        self.size_spinbox.setRange(1, 1000)
        self.size_spinbox.setValue(200)
        self.size_spinbox.setEnabled(True)
        
        self.limit_size_checkbox.toggled.connect(self.size_spinbox.setEnabled)
        
        size_layout.addWidget(self.limit_size_checkbox)
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

        # Clear Button
        self.clear_btn = QPushButton("Clear Completed")
        self.clear_btn.clicked.connect(self.clear_completed)
        layout.addWidget(self.clear_btn)

        self.queue = []
        self.is_processing = False
        self.current_thread = None
        self.output_dir = None

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
        self.queue.append(file_path)
        self.list_widget.addItem(f"Queued: {file_name}")
        self.process_next()

    def clear_completed(self):
        # Remove items that start with "Done:" or "Error:"
        # Iterate backwards to avoid index issues
        for i in range(self.list_widget.count() - 1, -1, -1):
            item = self.list_widget.item(i)
            if item.text().startswith("Done:") or item.text().startswith("Error:"):
                self.list_widget.takeItem(i)

    def process_next(self):
        if self.is_processing or not self.queue:
            return

        self.is_processing = True
        file_path = self.queue.pop(0)
        file_name = os.path.basename(file_path)
        
        self.status_label.setText(f"Processing: {file_name}")
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
                                             output_dir=self.output_dir, send_to_kindle=send_to_kindle, email_config=email_config)
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

if __name__ == "__main__":
    app = QApplication(sys.argv)
    apply_stylesheet(app, theme='dark_teal.xml')
    window = MainWindow()
    window.show()
    sys.exit(app.exec())
