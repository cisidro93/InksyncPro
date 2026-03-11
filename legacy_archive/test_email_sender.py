import unittest
from unittest.mock import patch, MagicMock
import os
import tempfile
import email_sender

class TestEmailSender(unittest.TestCase):
    def setUp(self):
        # Create a dummy file to attach
        self.test_file = tempfile.NamedTemporaryFile(delete=False)
        self.test_file.write(b"dummy content")
        self.test_file.close()

    def tearDown(self):
        os.remove(self.test_file.name)

    @patch('smtplib.SMTP')
    def test_send_email_success(self, mock_smtp):
        # Setup mock
        server_instance = mock_smtp.return_value
        server_instance.sendmail.return_value = {}
        
        # Call function
        success, msg = email_sender.send_email(
            self.test_file.name,
            "sender@example.com",
            "password",
            "kindle@kindle.com",
            "smtp.example.com",
            587
        )
        
        # Assertions
        self.assertTrue(success)
        self.assertEqual(msg, "Email sent successfully")
        
        # Verify SMTP calls
        mock_smtp.assert_called_with("smtp.example.com", 587)
        server_instance.starttls.assert_called_once()
        server_instance.login.assert_called_with("sender@example.com", "password")
        server_instance.sendmail.assert_called_once()
        server_instance.quit.assert_called_once()

    @patch('smtplib.SMTP')
    def test_send_email_failure(self, mock_smtp):
        # Setup mock to raise exception
        mock_smtp.side_effect = Exception("Connection failed")
        
        # Call function
        success, msg = email_sender.send_email(
            self.test_file.name,
            "sender@example.com",
            "password",
            "kindle@kindle.com"
        )
        
        # Assertions
        self.assertFalse(success)
        self.assertEqual(msg, "Connection failed")

if __name__ == '__main__':
    unittest.main()
