import sys
import os
from PySide6.QtCore import QThread, Signal
from werkzeug.serving import make_server
import threading

# Add the webapp directory to python path if needed, 
# though running from root usually suffices for imports if webapp is a package.
# But since webapp might not be a package, we might need to handle imports carefully.
# Assuming we are running from root.

# We need to import the flask app instance.
# Since app.py is in webapp/, and it imports cbz_to_pdf from root (..),
# we need to ensure sys.path is set up correctly for it to find modules.

try:
    from webapp.app import app
except ImportError:
    # Fallback/Safety: try adding webapp to path or importing differently
    sys.path.append(os.path.abspath("webapp"))
    from app import app

class WebServerThread(QThread):
    server_started = Signal(str)  # Emits URL when started
    server_stopped = Signal()
    error_occurred = Signal(str)

    def __init__(self, host='0.0.0.0', port=5000):
        super().__init__()
        self.host = host
        self.port = port
        self.server = None
        self.ctx = None
        self.is_running = False

    def run(self):
        try:
            # Use werkzeug's make_server to have control over the server loop
            # This allows us to shutdown the server cleanly
            self.server = make_server(self.host, self.port, app)
            self.ctx = app.app_context()
            self.ctx.push()
            
            self.is_running = True
            # For local open, localhost is better than 0.0.0.0
            display_url = f"http://localhost:{self.port}"
            self.server_started.emit(display_url)
            
            # This blocks until shutdown is called
            self.server.serve_forever()
            
        except Exception as e:
            self.error_occurred.emit(str(e))
        finally:
            self.is_running = False
            self.server_stopped.emit()

    def stop(self):
        if self.server:
            self.server.shutdown()
