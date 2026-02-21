import os
import math
from typing import List, Callable, Optional

def optimize_images(
    image_paths: List[str], 
    max_size_mb: Optional[int] = None, 
    optimize_for_eink: bool = False,
    progress_callback: Optional[Callable[[int, str], None]] = None,
    progress_start: int = 0,
    progress_end: int = 100
) -> None:
    """
    In-place optimization of images.
    - If `optimize_for_eink` is True, aggressively resizes large images to max 1600px height and compresses them to save space, keeping color intact.
    - If `max_size_mb` is provided, ensures the total batch size is under the limit by calculating a scale factor.
    """
    try:
        from PIL import Image
    except ImportError:
        if progress_callback:
            progress_callback(progress_start, "Error: Pillow library not found. Skipping optimization.")
        return

    def report(prog: int, msg: str):
        if progress_callback:
            # Map local [0, 100] progress into the overall [start, end] range provided
            mapped_prog = progress_start + int((prog / 100) * (progress_end - progress_start))
            progress_callback(mapped_prog, msg)
        else:
            print(f"[{prog}%] {msg}")

    total_images = len(image_paths)
    if total_images == 0:
        return

    # Phase 1: E-ink Optimization (Aggressive Resizing & Compression for Color E-ink)
    if optimize_for_eink:
        report(10, f"Running E-ink Color Optimization ({total_images} images)...")
        MAX_HEIGHT = 1600 # Excellent vertical resolution for 10-inch e-ink screens
        
        for i, img_path in enumerate(image_paths):
            try:
                prog = 10 + int((i / total_images) * 40) # Spans 10-50% locally
                if i % 10 == 0:
                    report(prog, f"Optimizing {i+1}/{total_images}...")
                
                with Image.open(img_path) as img:
                    img = img.convert('RGB') # Ensure it's not RGBA or P
                    modified = False
                    
                    # 1. Resize if taller than target
                    if img.height > MAX_HEIGHT:
                        ratio = MAX_HEIGHT / img.height
                        new_width = int(img.width * ratio)
                        img = img.resize((new_width, MAX_HEIGHT), Image.Resampling.LANCZOS)
                        modified = True
                    
                    # 2. Re-save as aggressive JPEG even if wasn't resized, to strip bloat
                    # 65-75% quality is visually indistinguishable on e-ink but saves 80% file size
                    img.save(img_path, "JPEG", quality=75, optimize=True)
                        
            except Exception as e:
                print(f"Warning: Could not optimize {img_path}: {e}")
                
    # Phase 2: Strict Total Size Enforcement
    if max_size_mb:
        report(60, f"Checking size limit ({max_size_mb}MB)...")
        total_size = sum(os.path.getsize(f) for f in image_paths)
        target_size = max_size_mb * 1024 * 1024
        
        if total_size > target_size:
            ratio = target_size / total_size
            scale_factor = math.sqrt(ratio) * 0.95 # Safe margin
            report(70, f"Resizing batch to fit under {max_size_mb}MB...")
            
            for i, img_path in enumerate(image_paths):
                try:
                    prog = 70 + int((i / total_images) * 30) # Spans 70-100% locally
                    if i % 10 == 0:
                        report(prog, f"Fitting size {i+1}/{total_images}...")
                        
                    with Image.open(img_path) as img:
                        img = img.convert('RGB')
                        new_width = int(img.width * scale_factor)
                        new_height = int(img.height * scale_factor)
                        img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                        img.save(img_path, "JPEG", quality=85, optimize=True)
                except Exception as e:
                    print(f"Warning: Could not strictly resize {img_path}: {e}")
        else:
            report(90, f"Total size OK ({(total_size/1024/1024):.1f}MB).")
            
    report(100, "Image processing complete.")
