const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const archiver = require('archiver'); 

function buildSAOMimicEpub() {
    console.log("Generating SAO Mimic EPUB...");
    const baseDir = path.join(__dirname, 'advanced_13_dir');
    
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
    <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`;
    fs.writeFileSync(path.join(baseDir, 'META-INF', 'container.xml'), containerXML);
    
    const cssContent = `
body
{
line-height: 1.2em;
font-size: 1em;
}
p
{
display: block;
margin-top: 0em;
margin-bottom: 0em;
margin-left: 0em;
margin-right: 0em;
text-indent: 20pt;
}
img
{
display: inline;
}
.image_full, .image_full_caption
{
text-align: center;
page-break-after: always;
page-break-inside: avoid;
clear: both;
padding: 0px;
margin: 0em auto;
height: 95%;
}

.image_full img
{
page-break-inside: avoid;
max-width: 100%;
max-height: 100%;
}
.galley-rw
{
font-family: serif;
font-size: 1em;
font-weight: normal;
letter-spacing: 0em;
line-height: 1.2em;
margin: 0em;
orphans: 1;
padding: 0em;
text-align: justify;
widows: 1;
word-spacing: 0em;
}
`;
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'css', 'stylesheet.css'), cssContent);

    // Copy the same image we used in previous advanced
    const wolvImgPath = path.join(__dirname, 'wolverine_epub_test', 'OEBPS', 'Images', 'kcc-0000-kcc.jpg');
    fs.copyFileSync(wolvImgPath, path.join(baseDir, 'OEBPS', 'images', 'comic_page.jpg'));

    const uuidStr = crypto.randomUUID();

    // 3. package.opf using SAO style
    const opfContent = `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" version="3.0" xml:lang="en">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>SAO Edge Test</dc:title>
<dc:language>en</dc:language>
<dc:identifier id="pub-id">urn:uuid:${uuidStr}</dc:identifier>
</metadata>
<manifest>
<item href="insert001.xhtml" id="insert001" media-type="application/xhtml+xml"/>
<item href="images/comic_page.jpg" id="img1" media-type="image/jpeg"/>
<item href="css/stylesheet.css" id="style" media-type="text/css"/>
<item id="nav" href="toc.xhtml" properties="nav" media-type="application/xhtml+xml"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
</manifest>
<spine toc="ncx">
<itemref idref="insert001" linear="yes"/>
</spine>
</package>`;

    const navContent = `<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
<title>SAO Edge Test</title>
</head>
<body>
<nav epub:type="toc" id="toc">
<ol>
<li><a href="insert001.xhtml">Image</a></li>
</ol>
</nav>
</body>
</html>`;

    const ncxContent = `<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="urn:uuid:${uuidStr}"/>
</head>
<docTitle><text>SAO Edge Test</text></docTitle>
<navMap>
<navPoint id="navPoint-1" playOrder="1">
<navLabel><text>Image</text></navLabel>
<content src="insert001.xhtml"/>
</navPoint>
</navMap>
</ncx>`;

    const xhtmlContent = `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
<head>
<meta content="text/html; charset=UTF-8" http-equiv="default-style"/>
<title>SAO Test</title>
<link href="css/stylesheet.css" rel="stylesheet" type="text/css"/>
</head>
<body>
<div class="galley-rw">
<section class="body-rw Chapter-rw auto-rw page-open-left-rw" epub:type="bodymatter chapter" id="insert001">
<div class="image_full"><img alt="Page" src="images/comic_page.jpg"/></div>
</section>
</div>
</body>
</html>`;

    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'package.opf'), opfContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'toc.xhtml'), navContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'toc.ncx'), ncxContent);
    fs.writeFileSync(path.join(baseDir, 'OEBPS', 'insert001.xhtml'), xhtmlContent);

    const outputPath = path.join(__dirname, 'advanced_13_sao_mimic.epub');
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

buildSAOMimicEpub();
