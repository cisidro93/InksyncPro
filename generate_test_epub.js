const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const crypto = require('crypto');

const redJpegBase64 = 
"/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";

function buildTestEpub(variantName) {
    const baseDir = path.join(__dirname, 'minimal_epub_test');
    
    if (fs.existsSync(baseDir)) {
        fs.rmSync(baseDir, { recursive: true, force: true });
    }
    
    fs.mkdirSync(baseDir);
    fs.mkdirSync(path.join(baseDir, 'META-INF'));
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'css'), { recursive: true });
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'text'), { recursive: true });
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'images'), { recursive: true });
    
    fs.writeFileSync(path.join(baseDir, 'mimetype'), 'application/epub+zip');
    
    const containerXML = `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`;
    fs.writeFileSync(path.join(baseDir, 'META-INF', 'container.xml'), containerXML);
    
    const css = `@page { margin: 0; padding: 0; }
body { margin: 0; padding: 0; background-color: #000000; }
img.page-image { position: absolute; top: 0; left: 0; width: 100vw; height: 100vh; object-fit: contain; }
svg { display: block; width: 100%; height: 100%; }`;
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'css', 'comic.css'), css);
    
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'images', 'page1.jpg'), Buffer.from(redJpegBase64, 'base64'));
    
    const width = 800;
    const height = 1200;
    const uuidStr = crypto.randomUUID();

    const opfContent = `<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="pub-id">urn:uuid:${uuidStr}</dc:identifier>
    <dc:title>Test KF8 Validation</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-03-13T12:00:00Z</meta>
    
    <meta name="fixed-layout" content="true"/>
    <meta name="original-resolution" content="${width}x${height}"/>
    <meta name="orientation-lock" content="none"/>
    <meta name="book-type" content="comic"/>
    <meta name="cdetype" content="pdoc"/>
    <meta name="RegionMagnification" content="true"/>
    <meta name="region-all-mag-adp" content="1"/>
    <meta name="zero-gutter" content="true"/>
    <meta name="zero-margin" content="true"/>
    <meta name="ke-border-color" content="#000000"/>
    <meta name="ke-border-width" content="0"/>
    <meta name="cover" content="img-page1"/>
    
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">auto</meta>
    <meta property="rendition:spread">auto</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="css/comic.css" media-type="text/css"/>
    <item id="img-page1" href="images/page1.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="page1" href="text/page1.xhtml" media-type="application/xhtml+xml"/>
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
    <title>Test Comic</title>
</head>
<body>
    <nav epub:type="toc" id="toc">
        <ol>
            <li><a href="text/page1.xhtml">Start</a></li>
        </ol>
    </nav>
    <nav epub:type="landmarks">
        <ol>
            <li><a epub:type="bodymatter" href="text/page1.xhtml">Start</a></li>
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
    <text>Test Comic</text>
  </docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>Start</text></navLabel>
      <content src="text/page1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>`;

    const xhtmlContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=${width}, height=${height}"/>
    <title>Page 1</title>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
</head>
<body>
    <div class="page">
        <img class="page-image" src="../images/page1.jpg" alt="Page 1"/>
    </div>
</body>
</html>`;

    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'content.opf'), opfContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'nav.xhtml'), navContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'toc.ncx'), ncxContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'text', 'page1.xhtml'), xhtmlContent);
    
    try {
        const outName = `fixed_structure_${variantName}.epub`;
        execSync(`powershell.exe -Command "Compress-Archive -Path minimal_epub_test\\* -DestinationPath ${outName}.zip -Force"`, { cwd: __dirname });
        fs.renameSync(path.join(__dirname, `${outName}.zip`), path.join(__dirname, outName));
        console.log(`Generated ${outName}`);
    } catch (e) {
        console.error("Zipping failed:", e.message);
    }
}

// Fixed structural test 1: All metadata + navigation XML components
buildTestEpub('kcc_exact_imitation');
