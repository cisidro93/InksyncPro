import zipfile
import os

source_dir = r"c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\minimal_epub_test"
output_file = r"c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\advanced_4_strict_mimetype_compression.epub"

if os.path.exists(output_file):
    os.remove(output_file)

with zipfile.ZipFile(output_file, 'w') as epub:
    # 1. Add mimetype FIRST with NO COMPRESSION
    mimetype_path = os.path.join(source_dir, "mimetype")
    epub.write(mimetype_path, arcname="mimetype", compress_type=zipfile.ZIP_STORED)
    
    # 2. Add everything else WITH COMPRESSION
    for root, dirs, files in os.walk(source_dir):
        for file in files:
            if file == "mimetype":
                continue
            
            absolute_path = os.path.join(root, file)
            relative_path = os.path.relpath(absolute_path, source_dir)
            # Use forward slashes for EPUB internal paths
            arcname = relative_path.replace("\\", "/")
            
            epub.write(absolute_path, arcname=arcname, compress_type=zipfile.ZIP_DEFLATED)

print(f"Successfully created {output_file} with strict mimetype storage.")
