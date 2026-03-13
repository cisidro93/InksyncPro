const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const archiver = require('archiver'); 

function buildTextInjectedEpub() {
    console.log("Generating with Archiver testing TEXT INJECTION...");
    const baseDir = path.join(__dirname, 'advanced_10_dir');
    
    if (fs.existsSync(baseDir)) fs.rmSync(baseDir, { recursive: true, force: true });
    
    fs.mkdirSync(baseDir);
    fs.mkdirSync(path.join(baseDir, 'META-INF'));
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'Text'), { recursive: true });
    fs.mkdirSync(path.join(baseDir, 'OEBPS', 'Images'), { recursive: true });
    
    fs.writeFileSync(path.join(baseDir, 'mimetype'), 'application/epub+zip');
    
    const containerXML = `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles>
<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
</rootfiles>
</container>`;
    fs.writeFileSync(path.join(baseDir, 'META-INF', 'container.xml'), containerXML);
    
    const css = `@page { margin: 0; }
body { display: block; margin: 0; padding: 0; }
.PV-text { position: absolute; bottom: 5px; right: 5px; font-size: 8px; color: black; z-index: 100; }`;
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'Text', 'style.css'), css);

    const wolvImgPath = path.join(__dirname, 'wolverine_epub_test', 'OEBPS', 'Images', 'kcc-0000-kcc.jpg');
    fs.copyFileSync(wolvImgPath, path.join(baseDir, 'OEBPS', 'Images', 'kcc-0000-kcc.jpg'));
    
    const wolvCoverPath = path.join(__dirname, 'wolverine_epub_test', 'OEBPS', 'Images', 'cover.jpg');
    fs.copyFileSync(wolvCoverPath, path.join(baseDir, 'OEBPS', 'Images', 'cover.jpg'));

    const width = 1860;
    const height = 2480;

    const opfContent = `<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" unique-identifier="BookID" xmlns="http://www.idpf.org/2007/opf">
<metadata xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>Text Injection Test</dc:title>
<dc:language>en-US</dc:language>
<dc:identifier id="BookID">urn:uuid:2b243d83-b01c-45cc-92d4-7e486634d065</dc:identifier>
<meta name="cover" content="cover"/>
<meta name="fixed-layout" content="true"/>
<meta name="original-resolution" content="${width}x${height}"/>
<meta name="book-type" content="comic"/>
<meta name="primary-writing-mode" content="horizontal-lr"/>
<meta name="zero-gutter" content="true"/>
<meta name="zero-margin" content="true"/>
<meta name="ke-border-color" content="#FFFFFF"/>
<meta name="ke-border-width" content="0"/>
<meta property="rendition:spread">landscape</meta>
<meta property="rendition:layout">pre-paginated</meta>
<meta name="orientation-lock" content="none"/>
<meta name="region-mag" content="true"/>
</metadata>
<manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
<item id="cover" href="Images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
<item id="page_Images_kcc-0000-kcc" href="Text/kcc-0000-kcc.xhtml" media-type="application/xhtml+xml"/>
<item id="img_Images_kcc-0000-kcc" href="Images/kcc-0000-kcc.jpg" media-type="image/jpeg"/>
<item id="css" href="Text/style.css" media-type="text/css"/>
</manifest>
<spine page-progression-direction="ltr" toc="ncx">
<itemref idref="page_Images_kcc-0000-kcc" linear="yes" properties="page-spread-left"/>
</spine>
</package>`;

    const navContent = `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Test</title><meta charset="utf-8"/></head>
<body><nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc" id="toc"><ol><li><a href="Text/kcc-0000-kcc.xhtml">Start</a></li></ol></nav></body></html>`;

    const ncxContent = `<?xml version="1.0" encoding="UTF-8"?>
<ncx version="2005-1" xml:lang="en-US" xmlns="http://www.daisy.org/z3986/2005/ncx/">
<head><meta name="dtb:uid" content="urn:uuid:2b243d83-b01c-45cc-92d4-7e486634d065"/></head>
<docTitle><text>Test</text></docTitle>
<navMap><navPoint id="Text"><navLabel><text>Start</text></navLabel><content src="Text/kcc-0000-kcc.xhtml"/></navPoint></navMap>
</ncx>`;

    // WE INJECT 'inkSyncPro' AS TEXT INTO THE PAGE TO TEST USER HYPOTHESIS
    const xhtmlContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
<title>kcc-0000-kcc</title>
<link href="style.css" type="text/css" rel="stylesheet"/>
<meta name="viewport" content="width=${width}, height=${height}"/>
</head>
<body style="">
<div style="text-align:center;top:0;">
<img width="${width}" height="${height}" src="../Images/kcc-0000-kcc.jpg"/>
</div>
<div class="PV-text">InksyncPro</div>
</body>
</html>`;

    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'content.opf'), opfContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'nav.xhtml'), navContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'toc.ncx'), ncxContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'Text', 'kcc-0000-kcc.xhtml'), xhtmlContent);

    const outputPath = path.join(__dirname, 'advanced_10_text_injection.epub');
    const output = fs.createWriteStream(outputPath);
    const archive = archiver('zip', { zlib: { level: 9 } });

    output.on('close', function() {
        console.log(`Archiver wrote ${archive.pointer()} total bytes to ${outputPath}`);
    });

    archive.pipe(output);
    archive.append(fs.createReadStream(path.join(baseDir, 'mimetype')), { name: 'mimetype', store: true });
    archive.directory(path.join(baseDir, 'META-INF'), 'META-INF');
    archive.directory(path.join(baseDir, 'OEBPS'), 'OEBPS');
    archive.finalize();
}

buildTextInjectedEpub();
