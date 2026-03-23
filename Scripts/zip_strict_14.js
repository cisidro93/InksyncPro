const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const archiver = require('archiver'); 

function buildReflowableSVGHackedEpub() {
    console.log("Generating reflowable EPUB with SVG Viewport overrides...");
    const baseDir = path.join(__dirname, 'advanced_14_dir');
    
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
    margin: 0;
    padding: 0;
}
html, body {
    margin: 0;
    padding: 0;
    background-color: transparent;
}
svg {
    display: block;
    margin: 0;
    padding: 0;
    width: 100vw;
    height: 100vh;
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
    <dc:title>SVG Reflowable Hack</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-03-13T12:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="css/style.css" media-type="text/css"/>
    <item id="page1" href="page1.xhtml" media-type="application/xhtml+xml" properties="svg"/>
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

    // We use the SVG viewBox stretch hack inside the reflowable container
    const xhtmlContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink">
<head>
    <meta charset="UTF-8"/>
    <title>Chapter 1</title>
    <link rel="stylesheet" type="text/css" href="css/style.css"/>
    <meta name="viewport" content="width=1860, height=2480"/>
</head>
<body>
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100vw" height="100vh" viewBox="0 0 1860 2480" preserveAspectRatio="none">
        <image width="1860" height="2480" xlink:href="images/comic_page.jpg"/>
    </svg>
</body>
</html>`;

    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'content.opf'), opfContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'nav.xhtml'), navContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'toc.ncx'), ncxContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'page1.xhtml'), xhtmlContent);

    const outputPath = path.join(__dirname, 'advanced_14_reflowable_svg.epub');
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

buildReflowableSVGHackedEpub();
