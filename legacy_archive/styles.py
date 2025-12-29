
COMIC_STYLE = """
QMainWindow {
    background-color: #202020;
    color: #EEEEEE;
}

QWidget {
    background-color: #202020;
    color: #EEEEEE;
    font-family: 'Segoe UI', sans-serif;
    font-size: 14px;
}

/* Comic Panel Containers */
QFrame, QGroupBox {
    background-color: #2D2D2D;
    border: 2px solid #000000;
    border-radius: 4px;
    margin-top: 20px;
}

QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    padding: 0 5px;
    color: #FF9900;
    font-weight: bold;
    font-size: 16px;
    background-color: #202020; /* Match window bg to overlap border */
}

/* Buttons */
QPushButton {
    background-color: #FF9900;
    color: #000000;
    border: 2px solid #000000;
    border-radius: 4px;
    padding: 8px 16px;
    font-weight: bold;
    text-transform: uppercase;
}

QPushButton:hover {
    background-color: #FFB84D;
    margin-top: -2px; 
    margin-bottom: 2px; /* Lift effect */
    border-bottom: 4px solid #000000; /* Thicker bottom border on hover */
}

QPushButton:pressed {
    background-color: #CC7A00;
    margin-top: 2px;
    margin-bottom: 0px;
    border-bottom: 2px solid #000000;
}

QPushButton:disabled {
    background-color: #555555;
    color: #888888;
    border: 2px solid #333333;
}

/* Detailed Control Styling */
QCheckBox {
    spacing: 8px;
    color: #EEEEEE;
}

QCheckBox::indicator {
    width: 18px;
    height: 18px;
    border: 2px solid #FF9900;
    background: #2D2D2D;
    border-radius: 3px;
}

QCheckBox::indicator:checked {
    background: #FF9900;
    image: url(none); /* Utilize a simple color fill or custom check icon if we had one */
}

/* Drop Zone (handled in component, but defaults here) */
QLabel {
    color: #EEEEEE;
}

/* List Widget (The Queue) */
QListWidget {
    background-color: #252525;
    border: 2px solid #000000;
    border-radius: 4px;
    outline: none;
}

QListWidget::item {
    background-color: #333333;
    color: #FFFFFF;
    border-bottom: 1px solid #000000;
    padding: 10px;
    margin: 2px;
}

QListWidget::item:selected {
    background-color: #444444;
    border: 1px solid #FF9900;
    color: #FF9900;
}

/* Progress Bar */
QProgressBar {
    border: 2px solid #000000;
    border-radius: 4px;
    text-align: center;
    background-color: #2D2D2D;
    height: 25px;
    color: #FFFFFF;
    font-weight: bold;
}

QProgressBar::chunk {
    background-color: #FF9900;
    width: 20px;
}

/* ComboBox & SpinBox */
QComboBox, QSpinBox {
    background-color: #333333;
    border: 2px solid #000000;
    padding: 5px;
    border-radius: 4px;
    selection-background-color: #FF9900;
    selection-color: #000000;
}

/* Scrollbars - Sleek */
QScrollBar:vertical {
    border: none;
    background: #202020;
    width: 10px;
    margin: 0px 0px 0px 0px;
}

QScrollBar::handle:vertical {
    background: #555555;
    min-height: 20px;
    border-radius: 5px;
}

QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
    height: 0px;
}
"""
