import Foundation

/// Provides static access to the raw shell, batch, and python scripts
/// required to build `.inksync` KFX export packages for desktop conversion.
/// Extracted from CBZToEPUBConverter to reduce compilation bloat and adhere to Single Responsibility.
public struct KFXScriptProvider {
    
    public static let convertShContent = #"""
    #!/bin/bash
    # InkSync Pro — KFX Conversion Script (Mac/Linux)
    # Requirements: Kindle Previewer 3, Calibre with KFX Output plugin
    # Usage: bash convert.sh

    set -e

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IMAGES_DIR="$SCRIPT_DIR/images"
    METADATA="$SCRIPT_DIR/metadata.json"

    # Parse metadata
    TITLE=$(python3 -c "import json,sys; d=json.load(open('$METADATA')); print(d['title'])")
    DIRECTION=$(python3 -c "import json,sys; d=json.load(open('$METADATA')); print(d['reading_direction'])")

    SAFE_TITLE=$(echo "$TITLE" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    OUTPUT_DIR="$SCRIPT_DIR/output"
    EPUB_PATH="$OUTPUT_DIR/${SAFE_TITLE}.epub"
    KPF_PATH="$OUTPUT_DIR/${SAFE_TITLE}.kpf"
    KFX_PATH="$OUTPUT_DIR/${SAFE_TITLE}.kfx"

    mkdir -p "$OUTPUT_DIR"

    echo "=== InkSync Pro KFX Converter ==="
    echo "Title: $TITLE"
    echo "Reading direction: $DIRECTION"
    echo ""

    # Step 1: Build EPUB from images
    echo "[1/3] Building EPUB from images..."
    python3 "$SCRIPT_DIR/build_epub.py" \
      --images "$IMAGES_DIR" \
      --output "$EPUB_PATH" \
      --title "$TITLE" \
      --direction "$DIRECTION"
    echo "      EPUB created: $EPUB_PATH"

    # Step 2: Convert EPUB to KPF via Kindle Previewer CLI
    echo "[2/3] Converting EPUB to KPF via Kindle Previewer..."
    KP_CLI="/Applications/Kindle Previewer 3.app/Contents/MacOS/kindlepreviewer"
    if [ ! -f "$KP_CLI" ]; then
      echo "ERROR: Kindle Previewer 3 not found at default path."
      echo "       Download from: https://www.amazon.com/Kindle-Previewer/b?node=21381691011"
      exit 1
    fi
    "$KP_CLI" "$EPUB_PATH" -convert -output "$OUTPUT_DIR"
    # Kindle Previewer names the output after the EPUB filename
    KPF_ACTUAL="$OUTPUT_DIR/${SAFE_TITLE}.kpf"
    if [ ! -f "$KPF_ACTUAL" ]; then
      # Some versions output to a subfolder
      KPF_ACTUAL=$(find "$OUTPUT_DIR" -name "*.kpf" | head -1)
    fi
    echo "      KPF created: $KPF_ACTUAL"

    # Step 3: Convert KPF to KFX via Calibre KFX Output plugin
    echo "[3/3] Converting KPF to KFX via Calibre..."
    CALIBRE_DEBUG="/Applications/calibre.app/Contents/MacOS/calibre-debug"
    if [ ! -f "$CALIBRE_DEBUG" ]; then
      echo "ERROR: Calibre not found at default path."
      echo "       Download from: https://calibre-ebook.com/download"
      exit 1
    fi
    "$CALIBRE_DEBUG" -r "KFX Output" -- "$KPF_ACTUAL" "$KFX_PATH"
    echo "      KFX created: $KFX_PATH"

    echo ""
    echo "=== Done! ==="
    echo "Transfer this file to your Kindle:"
    echo "  $KFX_PATH"
    echo ""
    echo "Connect Kindle via USB and copy to the 'documents' folder."
    """#
    
    public static let convertBatContent = #"""
    @echo off
    REM InkSync Pro — KFX Conversion Script (Windows)
    REM Requirements: Kindle Previewer 3, Calibre with KFX Output plugin
    REM Usage: Double-click convert.bat

    setlocal enabledelayedexpansion

    set SCRIPT_DIR=%~dp0
    set IMAGES_DIR=%SCRIPT_DIR%images
    set METADATA=%SCRIPT_DIR%metadata.json
    set OUTPUT_DIR=%SCRIPT_DIR%output

    for /f "delims=" %%i in ('python -c "import json; d=json.load(open(r'%METADATA%')); print(d['title'])"') do set TITLE=%%i
    for /f "delims=" %%i in ('python -c "import json; d=json.load(open(r'%METADATA%')); print(d['reading_direction'])"') do set DIRECTION=%%i

    REM Sanitize title for filename
    set SAFE_TITLE=%TITLE: =_%

    set EPUB_PATH=%OUTPUT_DIR%\%SAFE_TITLE%.epub
    set KFX_PATH=%OUTPUT_DIR%\%SAFE_TITLE%.kfx

    if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

    echo === InkSync Pro KFX Converter ===
    echo Title: %TITLE%
    echo Reading direction: %DIRECTION%
    echo.

    echo [1/3] Building EPUB from images...
    python "%SCRIPT_DIR%build_epub.py" --images "%IMAGES_DIR%" --output "%EPUB_PATH%" --title "%TITLE%" --direction "%DIRECTION%"
    echo       EPUB created: %EPUB_PATH%

    echo [2/3] Converting EPUB to KPF via Kindle Previewer...
    set KP_CLI=%LOCALAPPDATA%\Amazon\Kindle Previewer 3\app\KindlePreviewer.exe
    if not exist "%KP_CLI%" (
      echo ERROR: Kindle Previewer 3 not found.
      echo        Download from: https://www.amazon.com/Kindle-Previewer/b?node=21381691011
      pause
      exit /b 1
    )
    "%KP_CLI%" "%EPUB_PATH%" -convert -output "%OUTPUT_DIR%"

    echo [3/3] Converting KPF to KFX via Calibre...
    set CALIBRE_DEBUG=%PROGRAMFILES%\Calibre2\calibre-debug.exe
    if not exist "%CALIBRE_DEBUG%" (
      echo ERROR: Calibre not found at default path.
      echo        Download from: https://calibre-ebook.com/download
      pause
      exit /b 1
    )
    "%CALIBRE_DEBUG%" -r "KFX Output" -- "%OUTPUT_DIR%\%SAFE_TITLE%.kpf" "%KFX_PATH%"

    echo.
    echo === Done! ===
    echo Transfer this file to your Kindle:
    echo   %KFX_PATH%
    echo.
    echo Connect Kindle via USB and copy to the 'documents' folder.
    pause
    """#
    
    public static let buildEpubPyContent = #"""
    #!/usr/bin/env python3
    """
    InkSync Pro — EPUB builder for KFX pipeline
    Builds a fixed-layout EPUB3 from a folder of sequentially named images.
    Called by convert.sh and convert.bat.
    """
    import argparse, os, shutil, uuid, zipfile
    from datetime import datetime, timezone

    def build_epub(images_dir, output_path, title, direction):
        images = sorted([
            f for f in os.listdir(images_dir)
            if f.lower().endswith(('.jpg', '.jpeg', '.png'))
        ])
        if not images:
            raise SystemExit("ERROR: No images found in images/")

        book_id = str(uuid.uuid4())
        prog_dir = "rtl" if direction == "rtl" else "ltr"
        spread = "landscape" if direction == "rtl" else "landscape"

        work_dir = output_path + "_build"
        os.makedirs(os.path.join(work_dir, "OEBPS", "images"), exist_ok=True)
        os.makedirs(os.path.join(work_dir, "OEBPS", "text"), exist_ok=True)
        os.makedirs(os.path.join(work_dir, "OEBPS", "css"), exist_ok=True)
        os.makedirs(os.path.join(work_dir, "META-INF"), exist_ok=True)

        # mimetype
        with open(os.path.join(work_dir, "mimetype"), "w") as f:
            f.write("application/epub+zip")

        # container.xml
        with open(os.path.join(work_dir, "META-INF", "container.xml"), "w") as f:
            f.write("""<?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>""")

        # CSS
        css = """@page { margin: 0; padding: 0; }
    body { margin: 0; padding: 0; background: #000; }
    .page-container { position: relative; width: 100%; height: 100%; }
    .comic-page { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }"""
        with open(os.path.join(work_dir, "OEBPS", "css", "comic.css"), "w") as f:
            f.write(css)

        manifest_items = []
        spine_items = []
        manifest_items.append('<item id="css" href="css/comic.css" media-type="text/css"/>')
        manifest_items.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        manifest_items.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')

        for i, img_file in enumerate(images):
            ext = os.path.splitext(img_file)[1].lower()
            mime = "image/png" if ext == ".png" else "image/jpeg"
            safe_ext = "png" if ext == ".png" else "jpg"
            new_name = f"image_{i+1:04d}.{safe_ext}"

            shutil.copy(
                os.path.join(images_dir, img_file),
                os.path.join(work_dir, "OEBPS", "images", new_name)
            )

            cover_prop = ' properties="cover-image"' if i == 0 else ""
            manifest_items.append(
                f'<item id="img_{i+1}" href="images/{new_name}" media-type="{mime}"{cover_prop}/>'
            )

            page_xhtml = f"""<?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head>
      <meta charset="UTF-8"/>
      <meta name="viewport" content="width=device-width, height=device-height"/>
      <title>Page {i+1}</title>
      <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
    </head>
    <body>
      <div class="page-container">
        <img src="../images/{new_name}" class="comic-page" alt="Page {i+1}"/>
      </div>
    </body>
    </html>"""
            page_name = f"page_{i+1:04d}.xhtml"
            with open(os.path.join(work_dir, "OEBPS", "text", page_name), "w") as f:
                f.write(page_xhtml)
            manifest_items.append(
                f'<item id="page_{i+1}" href="text/{page_name}" media-type="application/xhtml+xml"/>'
            )
            spine_items.append(f'<itemref idref="page_{i+1}"/>')

        # nav.xhtml
        nav = f"""<?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>Navigation</title><meta charset="utf-8"/></head>
    <body>
      <nav epub:type="toc" id="toc">
        <ol><li><a href="text/page_0001.xhtml">Start Reading</a></li></ol>
      </nav>
    </body>
    </html>"""
        with open(os.path.join(work_dir, "OEBPS", "nav.xhtml"), "w") as f:
            f.write(nav)

        # toc.ncx
        ncx = f"""<?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="urn:uuid:{book_id}"/></head>
      <docTitle><text>{title}</text></docTitle>
      <navMap>
        <navPoint id="navPoint-1" playOrder="1">
          <navLabel><text>Start</text></navLabel>
          <content src="text/page_0001.xhtml"/>
        </navPoint>
      </navMap>
    </ncx>"""
        with open(os.path.join(work_dir, "OEBPS", "toc.ncx"), "w") as f:
            f.write(ncx)

        # content.opf
        modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        opf = f"""<?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf"
             xmlns:epub="http://www.idpf.org/2007/ops"
             unique-identifier="BookID" version="3.0"
             prefix="rendition: http://www.idpf.org/vocab/rendition/#">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="BookID">urn:uuid:{book_id}</dc:identifier>
        <dc:title>{title}</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">{modified}</meta>
        <meta property="rendition:layout">pre-paginated</meta>
        <meta property="rendition:spread">{spread}</meta>
        <meta property="rendition:orientation">portrait</meta>
        <meta name="cover" content="img_1"/>
      </metadata>
      <manifest>
        {"    ".join(manifest_items)}
      </manifest>
      <spine toc="ncx" page-progression-direction="{prog_dir}">
        {"    ".join(spine_items)}
      </spine>
    </package>"""
        with open(os.path.join(work_dir, "OEBPS", "content.opf"), "w") as f:
            f.write(opf)

        # Package as EPUB (mimetype first, uncompressed)
        if os.path.exists(output_path):
            os.remove(output_path)
        with zipfile.ZipFile(output_path, "w") as zf:
            zf.write(
                os.path.join(work_dir, "mimetype"), "mimetype",
                compress_type=zipfile.ZIP_STORED
            )
            for root, dirs, files in os.walk(work_dir):
                for file in files:
                    if file == "mimetype":
                        continue
                    abs_path = os.path.join(root, file)
                    rel_path = os.path.relpath(abs_path, work_dir)
                    zf.write(abs_path, rel_path, compress_type=zipfile.ZIP_DEFLATED)

        shutil.rmtree(work_dir)
        print(f"EPUB built: {output_path} ({len(images)} pages)")

    if __name__ == "__main__":
        parser = argparse.ArgumentParser()
        parser.add_argument("--images", required=True)
        parser.add_argument("--output", required=True)
        parser.add_argument("--title", required=True)
        parser.add_argument("--direction", required=True)
        args = parser.parse_args()
        build_epub(args.images, args.output, args.title, args.direction)
    """#
    
    public static let readmeTxtContent = #"""
    InkSync Pro — KFX Export Package
    =================================

    This package contains your comic ready for final KFX conversion.
    KFX is required for correct display on Kindle firmware 5.19.2+.

    WHAT YOU NEED ON YOUR COMPUTER
    -------------------------------
    1. Kindle Previewer 3
       Download: https://www.amazon.com/Kindle-Previewer/b?node=21381691011

    2. Calibre (free)
       Download: https://calibre-ebook.com/download

    3. Calibre KFX Output Plugin
       In Calibre: Preferences > Plugins > Get new plugins > search "KFX Output"

    HOW TO CONVERT
    --------------
    Mac/Linux:  Open Terminal, drag convert.sh into it, press Enter
    Windows:    Double-click convert.bat

    The final .kfx file will appear in the output/ folder.

    HOW TO TRANSFER TO KINDLE
    --------------------------
    1. Connect your Kindle via USB
    2. Open the Kindle drive on your computer
    3. Copy the .kfx file into the 'documents' folder
    4. Eject Kindle safely

    The book will appear in your Kindle library.

    WHY IS THIS NEEDED?
    -------------------
    Kindle firmware 5.19.2 introduced a regression affecting all sideloaded
    comic/manga files. KFX format is unaffected and provides the same full-quality
    panel navigation as purchased Amazon comics.
    """#
}
