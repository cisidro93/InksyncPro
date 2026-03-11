import sys
from PySide2.QtWidgets import QApplication
from cbz_converter_app import MainWindow

def test_app_init():
    try:
        app = QApplication(sys.argv)
        window = MainWindow()
        print("Successfully initialized MainWindow")
    except Exception as e:
        print(f"Failed to initialize app: {e}")
        sys.exit(1)

if __name__ == "__main__":
    test_app_init()
