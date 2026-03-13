const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const archiver = require('archiver'); 

function buildReflowableHackedEpub() {
    console.log("Generating reflowable EPUB with Edge-To-Edge CSS overrides...");
    const baseDir = path.join(__dirname, 'advanced_12_dir');
    
    if (fs.existsSync(baseDir)) fs.rmSync(baseDir, { recursive: true, force: true });
    
    fs.mkdirSync(baseDir);
    fs.mkdirSync(path.join(baseDir, 'META-INF'));
    fs.mkdirSync(path.join(baseDir, 'OEBPS'));
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'css'));
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'images'));
    
    fs.writeFileSync(path.join(baseDir, 'mimetype'), 'application/epub+zip');
    
    const containerXML = `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`;
    fs.writeFileSync(path.join(baseDir, 'META-INF', 'container.xml'), containerXML);
    
    const cssContent = `@page {
    margin: 0 !important;
    padding: 0 !important;
}
html, body {
    margin: 0 !important;
    padding: 0 !important;
    width: 100vw !important;
    height: 100vh !important;
    max-width: 100% !important;
    max-height: 100% !important;
    overflow: hidden !important;
    background-color: black;
}
div.fullscreen-wrapper {
    position: absolute;
    top: 0;
    left: 0;
    width: 100vw;
    height: 100vh;
    margin: 0;
    padding: 0;
}
img.fullscreen-image {
    display: block;
    margin: 0;
    padding: 0;
    width: 100vw;
    height: 100vh;
    object-fit: cover;
}`;
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'css', 'style.css'), cssContent);

    // Copy the same image we used in Advanced 8/9/10/11
    const wolvImgPath = path.join(__dirname, 'wolverine_epub_test', 'OEBPS', 'Images', 'kcc-0000-kcc.jpg');
    fs.copyFileSync(wolvImgPath, path.join(baseDir, 'OEBPS', 'images', 'comic_page.jpg'));

    const uuidStr = crypto.randomUUID();

    // 3. content.opf (REFLOWABLE - ABSOLUTELY NO FIXED LAYOUT TAGS)
    const opfContent = `<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="pub-id">urn:uuid:${uuidStr}</dc:identifier>
    <dc:title>CSS Reflowable Edge to Edge Hack</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-03-13T12:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="css/style.css" media-type="text/css"/>
    <item id="page1" href="page1.xhtml" media-type="application/xhtml+xml"/>
    <item id="img1" href="images/comic_page.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="page1"/>
  </spine>
</package>`;

    const navContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head>
    <meta charset="UTF-8"/>
    <title>Basic Navigation</title>
</head>
<body>
    <nav epub:type="toc" id="toc">
        <ol>
            <li><a href="page1.xhtml">Chapter 1</a></li>
        </ol>
    </nav>
</body>
</html>`;

    const ncxContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:${uuidStr}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>Image Book</text>
  </docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>Chapter 1</text></navLabel>
      <content src="page1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>`;

    const xhtmlContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, height=device-height, initial-scale=1.0"/>
    <title>Chapter 1</title>
    <link rel="stylesheet" type="text/css" href="css/style.css"/>
</head>
<body>
    <div class="fullscreen-wrapper">
        <img class="fullscreen-image" src="images/comic_page.jpg" alt="Comic Page" />
    </div>
</body>
</html>`;

    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'content.opf'), opfContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'nav.xhtml'), navContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'toc.ncx'), ncxContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'page1.xhtml'), xhtmlContent);

    const outputPath = path.join(__dirname, 'advanced_12_reflowable_css_hack.epub');
    const output = fs.createWriteStream(outputPath);
    const archive = archiver('zip', {
        zlib: { level: 9 }
    });

    output.on('close', function() {
        console.log(`Archiver wrote ${archive.pointer()} total bytes to ${outputPath}`);
    });

    archive.pipe(output);
    archive.append(fs.createReadStream(path.join(baseDir, 'mimetype')), { name: 'mimetype', store: true });
    archive.directory(path.join(baseDir, 'META-INF'), 'META-INF');
    archive.directory(path.join(baseDir, 'OEBPS'), 'OEBPS');
    archive.finalize();
}

buildReflowableHackedEpub();
