import os
import shutil
import tempfile
from PySide6.QtWidgets import QApplication
from worker import ConversionThread

# Mock QApplication to avoid issues with QThread
app = QApplication([])

def test_save_location():
    # Create a dummy CBZ file
    with tempfile.NamedTemporaryFile(suffix=".cbz", delete=False) as tmp:
        tmp.write(b"dummy content")
        input_path = tmp.name
    
    try:
        # Test 1: Default behavior (no output_dir)
        thread = ConversionThread(input_path)
        # We can't easily run the thread because it calls cbz_to_pdf which does real work.
        # But we can check the logic in run() by mocking or inspecting.
        # Actually, let's just check if the logic *would* produce the right path.
        # Since I modified run(), I can't easily inspect local variables.
        # Instead, I will rely on the fact that I modified the code correctly and 
        # maybe I can create a small test that mocks cbz_to_pdf.convert_cbz_to_pdf
        
        import cbz_to_pdf
        original_convert = cbz_to_pdf.convert_cbz_to_pdf
        
        captured_output_paths = []
        
        def mock_convert(input_p, output_p, **kwargs):
            captured_output_paths.append(output_p)
            return True
            
        cbz_to_pdf.convert_cbz_to_pdf = mock_convert
        
        # Test 1: Default
        thread1 = ConversionThread(input_path)
        thread1.run()
        expected_default = os.path.splitext(input_path)[0] + ".pdf"
        print(f"Test 1 (Default): Expected {expected_default}, Got {captured_output_paths[0]}")
        assert captured_output_paths[0] == expected_default
        
        # Test 2: Custom output dir
        with tempfile.TemporaryDirectory() as output_dir:
            thread2 = ConversionThread(input_path, output_dir=output_dir)
            thread2.run()
            base_name = os.path.splitext(os.path.basename(input_path))[0]
            expected_custom = os.path.join(output_dir, base_name + ".pdf")
            print(f"Test 2 (Custom): Expected {expected_custom}, Got {captured_output_paths[1]}")
            assert captured_output_paths[1] == expected_custom
            
        print("All tests passed!")
        
        # Restore
        cbz_to_pdf.convert_cbz_to_pdf = original_convert

    finally:
        if os.path.exists(input_path):
            os.remove(input_path)

if __name__ == "__main__":
    test_save_location()
