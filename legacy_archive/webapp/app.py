import os
import sys
import uuid
import threading
from flask import Flask, render_template, request, jsonify, send_from_directory, current_app
from PySide6.QtCore import QSettings

# Add parent directory to path to import cbz_to_pdf
# Add parent directory to path to import cbz_to_pdf
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cbz_to_pdf
import email_sender
from utils import resource_path

app = Flask(__name__, template_folder=resource_path(os.path.join("webapp", "templates")))
app.config['UPLOAD_FOLDER'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uploads')
app.config['OUTPUT_FOLDER'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'downloads')
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB limit

# Ensure directories exist
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
os.makedirs(app.config['OUTPUT_FOLDER'], exist_ok=True)

# Store task status in memory (for simplicity)
tasks = {}

def conversion_worker(task_id, input_path, output_path, compress, max_size_mb, send_to_kindle):
    """Background worker for conversion."""
    try:
        def progress_callback(percentage, message):
            tasks[task_id]['progress'] = percentage
            tasks[task_id]['message'] = message

        success = cbz_to_pdf.convert_cbz_to_pdf(
            input_path, 
            output_path, 
            progress_callback=progress_callback,
            compress=compress,
            max_size_mb=max_size_mb
        )

        if success:
            if send_to_kindle:
                tasks[task_id]['message'] = 'Sending to Kindle...'
                tasks[task_id]['progress'] = 99
                
                # Read settings
                settings = QSettings("Antigravity", "CBZtoPDF")
                sender = settings.value("sender_email", "")
                password = settings.value("sender_password", "")
                kindle_email = settings.value("kindle_email", "")
                smtp_server = settings.value("smtp_server", "smtp.gmail.com")
                smtp_port = settings.value("smtp_port", "587")

                if not sender or not password or not kindle_email:
                     tasks[task_id]['message'] = 'Conversion done, but Email settings missing.'
                else:
                    file_size = os.path.getsize(output_path)
                    if file_size > 25 * 1024 * 1024 and "gmail" in smtp_server.lower():
                        tasks[task_id]['message'] = 'Error: File > 25MB. Gmail limit is 25MB. Cannot send to Kindle.'
                    else:
                        # Extract original filename (remove UUID prefix)
                        original_filename = os.path.basename(output_path).split('_', 1)[1]
                        
                        email_success, email_msg = email_sender.send_email(
                            output_path, sender, password, kindle_email, smtp_server, int(smtp_port),
                            attachment_name=original_filename
                        )
                        
                        if email_success:
                            tasks[task_id]['message'] = 'Conversion complete & Sent to Kindle!'
                        else:
                            tasks[task_id]['message'] = f'Conversion done, Email failed: {email_msg}'
            else:
                tasks[task_id]['message'] = 'Conversion complete!'
            
            tasks[task_id]['status'] = 'completed'
            tasks[task_id]['progress'] = 100
            tasks[task_id]['download_url'] = f"/download/{os.path.basename(output_path)}"
        else:
            tasks[task_id]['status'] = 'failed'
            tasks[task_id]['message'] = 'Conversion failed.'

    except Exception as e:
        tasks[task_id]['status'] = 'failed'
        tasks[task_id]['message'] = str(e)
    finally:
        # Cleanup input file
        if os.path.exists(input_path):
            try:
                os.remove(input_path)
            except:
                pass

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No selected file'}), 400
    
    if file and (file.filename.lower().endswith('.cbz') or file.filename.lower().endswith('.cbr')):
        task_id = str(uuid.uuid4())
        filename = f"{task_id}_{file.filename}"
        input_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(input_path)
        
        # Options
        compress = request.form.get('compress') == 'true'
        
        kindle_val = request.form.get('kindle')
        send_to_kindle = kindle_val and kindle_val.lower() in ['true', 'on', '1']
        
        max_size_mb = request.form.get('max_size_mb')
        if max_size_mb:
            try:
                max_size_mb = int(max_size_mb)
            except ValueError:
                max_size_mb = None
        else:
            max_size_mb = None

        output_filename = os.path.splitext(file.filename)[0] + ".pdf"
        output_path = os.path.join(app.config['OUTPUT_FOLDER'], f"{task_id}_{output_filename}")

        tasks[task_id] = {
            'status': 'processing',
            'progress': 0,
            'message': 'Starting...',
            'filename': output_filename,
        }
        thread = threading.Thread(target=conversion_worker, args=(task_id, input_path, output_path, compress, max_size_mb, send_to_kindle))
        thread.start()

        return jsonify({'task_id': task_id})
    
    return jsonify({'error': 'Invalid file type'}), 400

@app.route('/status/<task_id>')
def get_status(task_id):
    task = tasks.get(task_id)
    if task:
        return jsonify(task)
    return jsonify({'error': 'Task not found'}), 404

@app.route('/download/<filename>')
def download_file(filename):
    return send_from_directory(app.config['OUTPUT_FOLDER'], filename, as_attachment=True, download_name=filename.split('_', 1)[1])

if __name__ == '__main__':
    # Run on 0.0.0.0 to be accessible from other devices
    app.run(host='0.0.0.0', port=5000, debug=False)
