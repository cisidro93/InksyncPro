import os
import zipfile
import tempfile
import uuid
import shutil
from typing import Optional, Callable, Union
from pathlib import Path

def is_image(filename: str) -> bool:
    """Checks if a file represents an image based on extension."""
    return filename.lower().endswith(('.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'))

def convert_cbz_to_epub(
    input_path: Union[str, Path], 
    epub_path: Union[str, Path], 
    manga_mode: bool = False,
    progress_callback: Optional[Callable[[int, str], None]] = None
) -> bool:
    """
    Converts a CBZ file to a Fixed-Layout EPUB3 file optimized for Kindle.
    """
    try:
        from PIL import Image
    except ImportError:
        if progress_callback:
            progress_callback(0, "Error: Pillow library not found.")
        return False
        
    input_path = str(input_path)
    epub_path = str(epub_path)
    
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
            # 1. Extract inputs
            report_progress(10, "Extracting archive...")
            if input_path.lower().endswith('.cbz'):
                try:
                    with zipfile.ZipFile(input_path, 'r') as zip_ref:
                        zip_ref.extractall(temp_dir)
                except zipfile.BadZipFile:
                    raise ValueError("Invalid CBZ file.")
            else:
                 raise ValueError("Unsupported format. Use .cbz")
                 
            # 2. Find and sort images
            report_progress(30, "Scanning for images...")
            image_files = []
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    if is_image(file):
                        image_files.append(os.path.join(root, file))
                        
            if not image_files:
                raise ValueError("No images found in the archive.")
                
            image_files.sort()
            
            # 3. Create EPUB Build Directory
            report_progress(40, "Building EPUB structure...")
            epub_build = os.path.join(temp_dir, "epub_build")
            meta_inf = os.path.join(epub_build, "META-INF")
            oebps = os.path.join(epub_build, "OEBPS")
            images_dir = os.path.join(oebps, "images")
            
            os.makedirs(meta_inf, exist_ok=True)
            os.makedirs(images_dir, exist_ok=True)
            
            # 3a. META-INF/container.xml
            with open(os.path.join(meta_inf, "container.xml"), "w", encoding="utf-8") as f:
                f.write('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
</container>''')

            # 3b. Read first image for base dimensions
            base_width, base_height = 800, 1280
            if image_files:
                try:
                    with Image.open(image_files[0]) as first_img:
                        base_width = first_img.width
                        base_height = first_img.height
                except Exception:
                    pass
            
            # 4. Copy Images and generate XHTML pages
            pages_data = [] # List of dicts {id, image_name, xhtml_name}
            
            for index, img_path in enumerate(image_files):
                prog = 40 + int((index / len(image_files)) * 30)
                if index % 20 == 0:
                     report_progress(prog, f"Processing page {index+1}/{len(image_files)}")
                
                # Normalize extension & copy
                ext = Path(img_path).suffix.lower()
                clean_ext = ".jpg" if ext == ".jpeg" else ext
                new_image_name = f"page_{index:04d}{clean_ext}"
                dest_image_path = os.path.join(images_dir, new_image_name)
                
                shutil.copy2(img_path, dest_image_path)
                
                xhtml_name = f"page_{index:04d}.xhtml"
                page_id = f"page_{index:04d}"
                
                pages_data.append({
                    "id": page_id,
                    "image_name": new_image_name,
                    "xhtml_name": xhtml_name
                })
                
                # Write XHTML for this page
                xhtml_path = os.path.join(oebps, xhtml_name)
                with open(xhtml_path, "w", encoding="utf-8") as f:
                    f.write(f'''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <title>Page {index+1}</title>
    <meta name="viewport" content="width={base_width}, height={base_height}"/>
    <style>
        @page {{ margin: 0; padding: 0; }}
        body {{ margin: 0; padding: 0; text-align: center; background-color: #000000; }}
        img {{
            width: 100%;
            height: 100%;
            object-fit: contain;
            display: block;
        }}
    </style>
</head>
<body>
    <img src="images/{new_image_name}" alt="Comic Page"/>
</body>
</html>''')

            # 5. Generate content.opf
            report_progress(80, "Generating Metadata...")
            book_id = str(uuid.uuid4())
            title = os.path.splitext(os.path.basename(input_path))[0]
            direction = "rtl" if manga_mode else "ltr"
            
            opf_content = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>{title}</dc:title>
        <dc:language>en</dc:language>
        <dc:identifier id="pub-id">urn:uuid:{book_id}</dc:identifier>
        <meta property="rendition:layout">pre-paginated</meta>
        <meta property="rendition:orientation">auto</meta>
        <meta property="rendition:spread">auto</meta>
        <meta name="book-type" content="comic"/>
        <meta name="primary-writing-mode" content="{direction}"/>
        <meta name="original-resolution" content="{base_width}x{base_height}"/>
        <meta name="fixed-layout" content="true"/>
    </metadata>
    <manifest>
'''
            # Add manifest items
            for p in pages_data:
                opf_content += f'        <item id="img_{p["id"]}" href="images/{p["image_name"]}" media-type="image/jpeg"/>\n'
                opf_content += f'        <item id="{p["id"]}" href="{p["xhtml_name"]}" media-type="application/xhtml+xml"/>\n'
                
            opf_content += '''    </manifest>
    <spine page-progression-direction="''' + direction + '''">\n'''
    
            # Add spine items
            for p in pages_data:
                opf_content += f'        <itemref idref="{p["id"]}"/>\n'
                
            opf_content += '''    </spine>
</package>'''

            with open(os.path.join(oebps, "content.opf"), "w", encoding="utf-8") as f:
                f.write(opf_content)
                
            # 6. Zip the EPUB
            report_progress(90, "Packaging EPUB...")
            with zipfile.ZipFile(epub_path, 'w', zipfile.ZIP_STORED) as epub_zip:
                # mimetype must be first, uncompressed
                epub_zip.writestr("mimetype", "application/epub+zip")
                
            with zipfile.ZipFile(epub_path, 'a', zipfile.ZIP_DEFLATED) as epub_zip:
                for root, _, files in os.walk(epub_build):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.relpath(file_path, epub_build)
                        if arcname != "mimetype":
                            epub_zip.write(file_path, arcname)
                            
            report_progress(100, f"Created: {os.path.basename(epub_path)}")
            return True
            
    except Exception as e:
        if progress_callback:
            progress_callback(0, f"Conversion Failed: {str(e)}")
        raise e
