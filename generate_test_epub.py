import os
import zipfile
import uuid
import shutil

def build_minimal_epub():
    base_dir = "minimal_epub_test"
    if os.path.exists(base_dir):
        shutil.rmtree(base_dir)
        
    os.makedirs(base_dir)
    os.makedirs(os.path.join(base_dir, "META-INF"))
    os.makedirs(os.path.join(base_dir, "OEBPS", "css"))
    os.makedirs(os.path.join(base_dir, "OEBPS", "images"))
    os.makedirs(os.path.join(base_dir, "OEBPS", "text"))
    
    # 1. mimetype (must be uncompressed)
    with open(os.path.join(base_dir, "mimetype"), "w", encoding="utf-8") as f:
        f.write("application/epub+zip")
        
    # 2. container.xml
    container_xml = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""
    with open(os.path.join(base_dir, "META-INF", "container.xml"), "w", encoding="utf-8") as f:
        f.write(container_xml)
        
    # 3. Create a blank test image
    # For now, let's just make a simple 800x1200 image if PIL is available
    width, height = 800, 1200
    try:
        from PIL import Image
        img = Image.new('RGB', (width, height), color = 'red')
        img.save(os.path.join(base_dir, "OEBPS", "images", "page1.jpg"))
    except ImportError:
        # Fallback: create an empty file, but this might fail validation.
        # We assume the environment has PIL or we can copy an existing image.
        print("PIL not found, please provide a valid JPEG at OEBPS/images/page1.jpg")
        pass
        
    # 4. css
    css = """@page { margin: 0; padding: 0; }
body { margin: 0; padding: 0; background-color: #000000; }
svg { display: block; width: 100%; height: 100%; }"""
    with open(os.path.join(base_dir, "OEBPS", "css", "comic.css"), "w", encoding="utf-8") as f:
        f.write(css)
        
    # 5. content.opf
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="pub-id">uuid-{uuid.uuid4()}</dc:identifier>
    <dc:title>Test Comic</dc:title>
    <dc:language>en</dc:language>
    <meta name="fixed-layout" content="true"/>
    <meta name="original-resolution" content="{width}x{height}"/>
    <meta name="orientation-lock" content="none"/>
    <meta name="book-type" content="comic"/>
    <meta name="cdetype" content="pdoc"/>
    <meta name="RegionMagnification" content="true"/>
    <meta name="region-all-mag-adp" content="1"/>
    <meta name="zero-gutter" content="true"/>
    <meta name="zero-margin" content="true"/>
    <meta name="ke-border-color" content="#000000"/>
    <meta name="ke-border-width" content="0"/>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">portrait</meta>
    <meta property="rendition:spread">none</meta>
  </metadata>
  <manifest>
    <item id="css" href="css/comic.css" media-type="text/css"/>
    <item id="img1" href="images/page1.jpg" media-type="image/jpeg"/>
    <item id="page1" href="text/page1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine page-progression-direction="ltr">
    <itemref idref="page1"/>
  </spine>
</package>"""
    with open(os.path.join(base_dir, "OEBPS", "content.opf"), "w", encoding="utf-8") as f:
        f.write(opf)
        
    # 6. xhtml
    xhtml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta name="viewport" content="width={width}, height={height}"/>
    <title>page1.jpg</title>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
</head>
<body>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" 
         width="100%" height="100%" viewBox="0 0 {width} {height}" 
         preserveAspectRatio="xMidYMid meet">
        <image width="{width}" height="{height}" xlink:href="../images/page1.jpg"/>
    </svg>
</body>
</html>"""
    with open(os.path.join(base_dir, "OEBPS", "text", "page1.xhtml"), "w", encoding="utf-8") as f:
        f.write(xhtml)
        
    # 7. Package ZIP
    zip_filename = "test_comic_zero_margin.epub"
    with zipfile.ZipFile(zip_filename, 'w') as epub:
        epub.write(os.path.join(base_dir, "mimetype"), "mimetype", compress_type=zipfile.ZIP_STORED)
        for root, dirs, files in os.walk(base_dir):
            for file in files:
                if file != "mimetype":
                    filepath = os.path.join(root, file)
                    arcname = os.path.relpath(filepath, base_dir)
                    epub.write(filepath, arcname, compress_type=zipfile.ZIP_DEFLATED)
                    
    print(f"Generated {zip_filename}")

if __name__ == "__main__":
    build_minimal_epub()
