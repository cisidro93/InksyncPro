import Foundation

let baseDirURL = URL(fileURLWithPath: "minimal_epub_test")
let oebpsDir = baseDirURL.appendingPathComponent("OEBPS")
let metaDir = baseDirURL.appendingPathComponent("META-INF")
let imagesDir = oebpsDir.appendingPathComponent("images")
let textDir = oebpsDir.appendingPathComponent("text")
let cssDir = oebpsDir.appendingPathComponent("css")

let fileManager = FileManager.default

try? fileManager.removeItem(at: baseDirURL)
try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)

let mimetypePath = baseDirURL.appendingPathComponent("mimetype")
try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)

let containerXML = """
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""
try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

let cssContent = """
@page { margin: 0; padding: 0; }
body { margin: 0; padding: 0; background-color: #000000; }
svg { display: block; width: 100%; height: 100%; }
"""
try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)

// Create a blank JPG (red pixel block instead of actual image for proof of concept)
let width = 800
let height = 1200
let blankJPGData = Data(count: 100) // Dummy data, invalid JPG but Kindle might still complain about it. Better to use NO image if possible, or a real one.
// Instead of a dummy JPG, let's just make a blank XHTML page that sets a background color via SVG
try blankJPGData.write(to: imagesDir.appendingPathComponent("page1.jpg"))

let uuid = UUID().uuidString
let opfContent = """
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="pub-id">uuid-\(uuid)</dc:identifier>
    <dc:title>Test Margin Eradication</dc:title>
    <dc:language>en</dc:language>
    <meta name="fixed-layout" content="true"/>
    <meta name="original-resolution" content="\(width)x\(height)"/>
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
    <item id="page1" href="text/page1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine page-progression-direction="ltr">
    <itemref idref="page1"/>
  </spine>
</package>
"""
try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

// We use an empty SVG rect instead of an <image> tag because we don't have a valid JPG generator in raw Swift without UIKit/CoreGraphics
let xhtmlContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <meta name="viewport" content="width=\(width), height=\(height)"/>
    <title>Page 1</title>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
</head>
<body>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" 
         width="100%" height="100%" viewBox="0 0 \(width) \(height)" 
         preserveAspectRatio="xMidYMid meet">
        <rect width="100%" height="100%" fill="red"/>
    </svg>
</body>
</html>
"""
try xhtmlContent.write(to: textDir.appendingPathComponent("page1.xhtml"), atomically: true, encoding: .utf8)

print("Generated directories. Please run: cd minimal_epub_test && zip -X0 test.epub mimetype && zip -X9urD test.epub *")
