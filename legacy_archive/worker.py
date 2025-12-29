import os
from pathlib import Path
from typing import Optional, Dict
from PySide6.QtCore import QThread, Signal
import cbz_to_pdf
import email_sender

class ConversionThread(QThread):
    progress_signal = Signal(int, str)
    finished_signal = Signal(bool, str)

    def __init__(self, input_path: str, compress: bool = False, max_size_mb: Optional[int] = None, 
                 output_dir: Optional[str] = None, send_to_kindle: bool = False, email_config: Optional[Dict] = None,
                 output_name: Optional[str] = None):
        super().__init__()
        self.input_path = Path(input_path)
        self.compress = compress
        self.max_size_mb = max_size_mb
        self.output_dir = Path(output_dir) if output_dir else None
        self.send_to_kindle = send_to_kindle
        self.email_config = email_config
        self.output_name = output_name

    def run(self):
        try:
            base_name = self.output_name if self.output_name else self.input_path.stem
            if self.output_dir:
                output_path = self.output_dir / (base_name + ".pdf")
            else:
                # Default to same directory as input
                output_path = self.input_path.with_suffix(".pdf")
            
            def callback(percentage, message):
                self.progress_signal.emit(percentage, message)

            # Convert Path objects to strings for the underlying library if needed, 
            # but let's try to pass strings to ensure compatibility with existing cbz_to_pdf
            cbz_to_pdf.convert_cbz_to_pdf(str(self.input_path), str(output_path), progress_callback=callback, 
                                        compress=self.compress, max_size_mb=self.max_size_mb)
            
            if self.send_to_kindle and self.email_config:
                self.progress_signal.emit(99, "Sending to Kindle...")
                success, msg = email_sender.send_email(
                    str(output_path),
                    self.email_config['sender'],
                    self.email_config['password'],
                    self.email_config['kindle_email'],
                    self.email_config['smtp_server'],
                    int(self.email_config['smtp_port'])
                )
                if not success:
                    raise Exception(f"Conversion successful, but email failed: {msg}")
                self.progress_signal.emit(100, "Sent to Kindle")

            self.finished_signal.emit(True, f"Successfully created {output_path.name}")
        except Exception as e:
            self.finished_signal.emit(False, str(e))
