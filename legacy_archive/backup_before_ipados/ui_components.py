from PySide6.QtWidgets import (QLabel, QDialog, QFormLayout, QLineEdit, 
                               QDialogButtonBox, QVBoxLayout)
from PySide6.QtCore import Qt, Signal, QSettings
from PySide6.QtGui import QDragEnterEvent, QDropEvent

class DropZone(QLabel):
    file_dropped = Signal(str)

    def __init__(self):
        super().__init__()
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setText("\n\nDrop CBZ or CBR files here\n\n")
        self.setStyleSheet("""
            QLabel {
                border: 2px dashed #666;
                border-radius: 10px;
                font-size: 18px;
                color: #888;
                background-color: #2a2a2a;
                padding: 20px;
            }
            QLabel:hover {
                border-color: #aaa;
                background-color: #333;
                color: #ddd;
            }
        """)
        self.setAcceptDrops(True)

    def dragEnterEvent(self, event: QDragEnterEvent):
        if event.mimeData().hasUrls():
            event.accept()
        else:
            event.ignore()

    def dropEvent(self, event: QDropEvent):
        files = [u.toLocalFile() for u in event.mimeData().urls()]
        for f in files:
            if f.lower().endswith(('.cbz', '.cbr')):
                self.file_dropped.emit(f)

class EmailConfigDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Email Settings")
        self.resize(400, 250)
        
        self.settings = QSettings("Antigravity", "CBZtoPDF")
        
        layout = QFormLayout(self)
        
        self.sender_edit = QLineEdit(self.settings.value("sender_email", ""))
        self.password_edit = QLineEdit(self.settings.value("sender_password", ""))
        self.password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.kindle_edit = QLineEdit(self.settings.value("kindle_email", ""))
        self.smtp_server_edit = QLineEdit(self.settings.value("smtp_server", "smtp.gmail.com"))
        self.smtp_port_edit = QLineEdit(self.settings.value("smtp_port", "587"))
        
        layout.addRow("Sender Email:", self.sender_edit)
        layout.addRow("App Password:", self.password_edit)
        layout.addRow("Kindle Email:", self.kindle_edit)
        layout.addRow("SMTP Server:", self.smtp_server_edit)
        layout.addRow("SMTP Port:", self.smtp_port_edit)
        
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.save_settings)
        buttons.rejected.connect(self.reject)
        layout.addRow(buttons)
        
    def save_settings(self):
        self.settings.setValue("sender_email", self.sender_edit.text())
        self.settings.setValue("sender_password", self.password_edit.text())
        self.settings.setValue("kindle_email", self.kindle_edit.text())
        self.settings.setValue("smtp_server", self.smtp_server_edit.text())
        self.settings.setValue("smtp_port", self.smtp_port_edit.text())
        self.accept()
    
    def get_config(self):
        return {
            'sender': self.sender_edit.text(),
            'password': self.password_edit.text(),
            'kindle_email': self.kindle_edit.text(),
            'smtp_server': self.smtp_server_edit.text(),
            'smtp_port': self.smtp_port_edit.text()
        }
