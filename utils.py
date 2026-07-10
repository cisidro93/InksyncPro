import sys
import os

def resource_path(relative_path):
    """ Get absolute path to resource, works for dev and for PyInstaller """
    try:
        # PyInstaller creates a temp folder and stores path in _MEIPASS
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(".")

    return os.path.join(base_path, relative_path)

import threading

class ActiveUploadRegistry:
    _instance = None
    _lock = threading.Lock()

    def __new__(cls, *args, **kwargs):
        if not cls._instance:
            with cls._lock:
                if not cls._instance:
                    cls._instance = super(ActiveUploadRegistry, cls).__new__(cls)
                    cls._instance.active_paths = set()
                    cls._instance.lock = threading.Lock()
        return cls._instance

    def _normalize(self, file_path):
        """Normalizes file path by standardizing casing and resolving symlinks/realpaths."""
        try:
            return os.path.abspath(os.path.realpath(file_path))
        except Exception:
            return os.path.abspath(file_path)

    def register(self, file_path):
        normalized = self._normalize(file_path)
        with self.lock:
            self.active_paths.add(normalized)

    def unregister(self, file_path):
        normalized = self._normalize(file_path)
        with self.lock:
            self.active_paths.discard(normalized)

    def is_uploading(self, file_path):
        normalized = self._normalize(file_path)
        with self.lock:
            return normalized in self.active_paths

    def clear(self):
        with self.lock:
            self.active_paths.clear()

# Shared singleton instance
active_upload_registry = ActiveUploadRegistry()
