import smtplib
import os
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email.mime.text import MIMEText
from email import encoders

def send_email(file_path, sender_email, sender_password, recipient_email, smtp_server="smtp.gmail.com", smtp_port=587):
    """
    Sends an email with the specified file as an attachment.
    """
    msg = MIMEMultipart()
    msg['From'] = sender_email
    msg['To'] = recipient_email
    msg['Subject'] = f"Convert: {os.path.basename(file_path)}" # "Convert" subject is often required for Kindle
    
    body = "Please find the converted PDF attached."
    msg.attach(MIMEText(body, 'plain'))
    
    filename = os.path.basename(file_path)
    
    try:
        with open(file_path, "rb") as attachment:
            part = MIMEBase('application', 'octet-stream')
            part.set_payload(attachment.read())
            
        encoders.encode_base64(part)
        part.add_header(
            "Content-Disposition",
            f"attachment; filename= {filename}",
        )
        msg.attach(part)
        
        server = smtplib.SMTP(smtp_server, smtp_port)
        server.starttls()
        server.login(sender_email, sender_password)
        text = msg.as_string()
        server.sendmail(sender_email, recipient_email, text)
        server.quit()
        return True, "Email sent successfully"
    except Exception as e:
        return False, str(e)
