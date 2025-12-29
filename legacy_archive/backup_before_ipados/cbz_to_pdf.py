import os
import zipfile
import tempfile
import subprocess
import math
from typing import Optional, Callable, Union
from pathlib import Path
import img2pdf
from PIL import Image

def is_image(filename: str) -> bool:
    """Checks if a file is an image based on extension."""
    valid_extensions = ('.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tiff')
    return filename.lower().endswith(valid_extensions)

def find_winrar() -> Optional[str]:
    """Finds the WinRAR executable."""
    possible_paths = [
        r"C:\Program Files\WinRAR\WinRAR.exe",
        r"C:\Program Files (x86)\WinRAR\WinRAR.exe"
    ]
    
    # Check common paths
    for path in possible_paths:
        if os.path.exists(path):
            return path
            
    # Check PATH
    try:
        result = subprocess.run(["where", "WinRAR"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip().split('\n')[0]
    except Exception:
        pass
        
    return None

def convert_cbz_to_pdf(input_path: Union[str, Path], pdf_path: Union[str, Path], 
                       progress_callback: Optional[Callable[[int, str], None]] = None, 
                       compress: bool = False, quality: int = 75, max_size_mb: Optional[int] = None) -> bool:
    """Converts a CBZ or CBR file to a PDF file."""
    
    input_path = str(input_path)
    pdf_path = str(pdf_path)

    def report_progress(percentage: int, message: str):
        if progress_callback:
            progress_callback(percentage, message)
        print(f"[{percentage}%] {message}")

    if not os.path.exists(input_path):
        report_progress(0, f"Error: File not found: {input_path}")
        return False

    report_progress(5, f"Processing: {os.path.basename(input_path)}")

    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            # Extract contents based on file extension
            report_progress(10, "Extracting archive...")
            if input_path.lower().endswith('.cbz'):
                with zipfile.ZipFile(input_path, 'r') as zip_ref:
                    zip_ref.extractall(temp_dir)
            elif input_path.lower().endswith('.cbr'):
                winrar_exe = find_winrar()
                if not winrar_exe:
                    raise ValueError("WinRAR not found. Please install WinRAR to support CBR files.")
                
                # WinRAR command: x = extract, -ibck = background, -inul = no error msgs, -y = assume yes
                cmd = [winrar_exe, "x", "-ibck", "-inul", "-y", input_path, temp_dir]
                result = subprocess.run(cmd)
                
                if result.returncode != 0:
                     raise ValueError(f"WinRAR failed with exit code {result.returncode}")

            else:
                raise ValueError("Unsupported file format. Please use .cbz or .cbr")
            
            report_progress(30, "Scanning for images...")
            # Find all images
            image_files = []
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    if is_image(file):
                        image_files.append(os.path.join(root, file))
            
            if not image_files:
                raise ValueError("No images found in the archive.")

            # Sort images to ensure correct order (usually alphanumeric)
            image_files.sort()
            
            # Check total size if max_size_mb is set
            if max_size_mb:
                total_size = sum(os.path.getsize(f) for f in image_files)
                target_size = max_size_mb * 1024 * 1024
                
                if total_size > target_size:
                    report_progress(40, f"Total size {total_size/1024/1024:.1f}MB exceeds limit {max_size_mb}MB. Resizing...")
                    
                    ratio = target_size / total_size
                    scale_factor = math.sqrt(ratio) * 0.95
                    
                    for i, img_path in enumerate(image_files):
                        try:
                            prog = 40 + int((i / len(image_files)) * 40)
                            if i % 5 == 0:
                                report_progress(prog, f"Resizing image {i+1}/{len(image_files)}...")
                            
                            with Image.open(img_path) as img:
                                img = img.convert('RGB')
                                new_width = int(img.width * scale_factor)
                                new_height = int(img.height * scale_factor)
                                img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                                img.save(img_path, "JPEG", quality=85, optimize=True)
                        except Exception as e:
                            print(f"Warning: Could not resize {img_path}: {e}")
                else:
                    report_progress(40, "Size within limits. Skipping resize.")

            elif compress:
                report_progress(40, f"Compressing {len(image_files)} images...")
                for i, img_path in enumerate(image_files):
                    try:
                        # Calculate progress for compression phase (40% to 80%)
                        prog = 40 + int((i / len(image_files)) * 40)
                        if i % 5 == 0: # Don't spam callback
                             report_progress(prog, f"Compressing image {i+1}/{len(image_files)}...")
                        
                        with Image.open(img_path) as img:
                            img = img.convert('RGB')
                            img.save(img_path, "JPEG", quality=quality, optimize=True)
                    except Exception as e:
                        print(f"Warning: Could not compress {img_path}: {e}")

            report_progress(80, f"Found {len(image_files)} images. Converting to PDF...")

            # Convert to PDF
            pdf_bytes = img2pdf.convert(image_files)
            
            report_progress(95, "Saving PDF...")
            with open(pdf_path, "wb") as f:
                f.write(pdf_bytes)
            
            report_progress(100, f"Successfully created: {os.path.basename(pdf_path)}")
            return True

    except zipfile.BadZipFile:
        raise ValueError("Invalid CBZ file.")
    except Exception as e:
        raise e
