import os
import zipfile
import tempfile
import math
from typing import Optional, Callable, Union
from pathlib import Path

# Safe imports for Android (Lazy loaded)
# try:
#     import img2pdf
#     HAS_IMG2PDF = True
# except ImportError:
#     HAS_IMG2PDF = False
# from PIL import Image

def is_image(filename: str) -> bool:
    """Checks if a file represents an image based on extension."""
    return filename.lower().endswith(('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'))

def convert_cbz_to_pdf(input_path: Union[str, Path], pdf_path: Union[str, Path], 
                       progress_callback: Optional[Callable[[int, str], None]] = None, 
                       compress: bool = False, quality: int = 75, max_size_mb: Optional[int] = None) -> bool:
    """Converts a CBZ file to a PDF file."""
    
    # Lazy Imports to prevent startup freeze
    try:
        import img2pdf
        HAS_IMG2PDF = True
    except ImportError:
        HAS_IMG2PDF = False
        
    try:
        from PIL import Image
    except ImportError:
        if progress_callback:
            progress_callback(0, "Error: Pillow library not found.")
        return False
    
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
                try:
                    with zipfile.ZipFile(input_path, 'r') as zip_ref:
                        zip_ref.extractall(temp_dir)
                except zipfile.BadZipFile:
                    raise ValueError("Invalid CBZ file.")
            elif input_path.lower().endswith('.cbr'):
                raise ValueError("CBR format is not supported on Android version.")
            else:
                raise ValueError("Unsupported file format. Please use .cbz")
            
            report_progress(30, "Scanning for images...")
            # Find all images
            image_files = []
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    if is_image(file):
                        image_files.append(os.path.join(root, file))
            
            if not image_files:
                raise ValueError("No images found in the archive.")

            # Sort images
            image_files.sort()
            
            # Check total size if max_size_mb is set
            if max_size_mb:
                total_size = sum(os.path.getsize(f) for f in image_files)
                target_size = max_size_mb * 1024 * 1024
                
                if total_size > target_size:
                    report_progress(40, f"Resizing (Limit: {max_size_mb}MB)...")
                    ratio = target_size / total_size
                    scale_factor = math.sqrt(ratio) * 0.95
                    
                    for i, img_path in enumerate(image_files):
                        try:
                            prog = 40 + int((i / len(image_files)) * 40)
                            if i % 10 == 0:
                                report_progress(prog, f"Resizing {i+1}/{len(image_files)}...")
                            
                            with Image.open(img_path) as img:
                                img = img.convert('RGB')
                                new_width = int(img.width * scale_factor)
                                new_height = int(img.height * scale_factor)
                                img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                                img.save(img_path, "JPEG", quality=85, optimize=True)
                        except Exception as e:
                            print(f"Warning: Could not resize {img_path}: {e}")
                else:
                    report_progress(40, "Size OK. Skipping resize.")

            elif compress:
                report_progress(40, f"Compressing {len(image_files)} images...")
                for i, img_path in enumerate(image_files):
                    try:
                        prog = 40 + int((i / len(image_files)) * 40)
                        if i % 10 == 0:
                             report_progress(prog, f"Compressing {i+1}/{len(image_files)}...")
                        
                        with Image.open(img_path) as img:
                            img = img.convert('RGB')
                            img.save(img_path, "JPEG", quality=quality, optimize=True)
                    except Exception as e:
                        print(f"Warning: Could not compress {img_path}: {e}")

            report_progress(80, f"Found {len(image_files)} images. Generating PDF...")

            # Convert to PDF
            if HAS_IMG2PDF:
                try:
                    pdf_bytes = img2pdf.convert(image_files)
                    report_progress(95, "Saving PDF...")
                    with open(pdf_path, "wb") as f:
                        f.write(pdf_bytes)
                except Exception as e:
                    # Fallback if img2pdf fails runtime
                     print(f"img2pdf failed: {e}. Trying Pillow...")
                     HAS_IMG2PDF = False # Force fallback logic
            
            if not HAS_IMG2PDF:
                # Fallback to Pillow
                report_progress(95, "Saving PDF (Internal Engine)...")
                images = []
                first_image = None
                for img_path in image_files:
                    try:
                        img = Image.open(img_path).convert("RGB")
                        if first_image is None:
                            first_image = img
                        else:
                            images.append(img)
                    except Exception as e:
                         print(f"Warning: Could not open {img_path}: {e}")
                
                if first_image:
                    first_image.save(pdf_path, "PDF", resolution=100.0, save_all=True, append_images=images)
                else:
                    raise ValueError("No valid images processing for PDF.")
            
            report_progress(100, f"Created: {os.path.basename(pdf_path)}")
            return True

    except Exception as e:
        # Re-raise nicely
        raise e
