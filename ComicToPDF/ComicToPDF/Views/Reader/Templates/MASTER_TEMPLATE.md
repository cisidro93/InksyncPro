# InkSync Pro — Kindle Comic EPUB Master Template
## CBZ to KF8-Compliant EPUB Conversion Blueprint

This document defines the exact file structure, metadata, and markup your converter
must generate to produce a Kindle-compatible fixed-layout EPUB with working Panel View
(Region Magnification). Follow this spec precisely — deviations cause Previewer 3 to
fall back to the 2x2 Virtual Panel default.

---

## 1. EPUB PACKAGE STRUCTURE

Every exported EPUB must match this directory layout exactly:

```
YourComic.epub  (ZIP archive)
├── mimetype                          ← MUST be first file, uncompressed
├── META-INF/
│   └── container.xml
└── OEBPS/
    ├── content.opf                   ← Package document (metadata + spine)
    ├── toc.ncx                       ← NCX navigation (required by KF8)
    ├── nav.xhtml                     ← EPUB3 nav document
    ├── css/
    │   └── comic.css                 ← Fixed layout stylesheet
    ├── images/
    │   ├── cover.jpg                 ← Cover image (required)
    │   ├── page001.jpg               ← Comic pages (JPEG only, no PNG)
    │   ├── page002.jpg
    │   └── ...
    └── pages/
        ├── cover.xhtml               ← Cover page HTML
        ├── page001.xhtml             ← Comic page HTML with panel markup
        ├── page002.xhtml
        └── ...
```

---

## 2. CRITICAL RULES (violations cause Panel View failure)

1. `mimetype` file must be the FIRST file in the ZIP, stored UNCOMPRESSED
2. All images must be JPEG — KF8 does not support PNG transparency
3. `RegionMagnification` meta tag must use EXACT casing shown below
4. `book-type` must be set to `comic`
5. Panel `<a>` anchor and target `<div>` must be SIBLINGS, never nested
6. `targetId` and `sourceId` in JSON must EXACTLY match element `id` attributes
7. Every page that has panels must have ALL panels defined — no partial pages
8. Image resolution: minimum 1200px on shortest side, 300ppi recommended
9. All coordinates must be expressed as PERCENTAGES of page dimensions
10. Ordinal values must start at 1 (not 0) and be sequential per page

---

## 3. FILE TEMPLATES

### 3.1 — mimetype
```
application/epub+zip
```
No newline at end of file. Store uncompressed in ZIP (deflate level 0).

---

### 3.2 — META-INF/container.xml
```xml
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
              media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
```

---

### 3.3 — OEBPS/content.opf
This is the most critical file. All metadata flags must be present.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0"
         xmlns="http://www.idpf.org/2007/opf"
         unique-identifier="BookID"
         prefix="rendition: http://www.idpf.org/vocab/rendition/#">

  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:opf="http://www.idpf.org/2007/opf">

    <!-- Required Dublin Core -->
    <dc:title>{{COMIC_TITLE}}</dc:title>
    <dc:creator>{{AUTHOR_NAME}}</dc:creator>
    <dc:identifier id="BookID">{{UNIQUE_UUID}}</dc:identifier>
    <dc:language>en</dc:language>
    <dc:date>{{PUBLICATION_DATE}}</dc:date>

    <!-- Fixed Layout — ALL of these are required -->
    <meta name="fixed-layout" content="true"/>
    <meta name="original-resolution" content="{{PAGE_WIDTH}}x{{PAGE_HEIGHT}}"/>
    <meta name="orientation-lock" content="{{ORIENTATION}}"/>
    <meta name="book-type" content="comic"/>
    <meta name="RegionMagnification" content="true"/>
    <meta name="cover" content="cover-image"/>
    <meta name="cdetype" content="pdoc"/>

    <!-- EPUB3 rendition properties -->
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">{{ORIENTATION}}</meta>
    <meta property="rendition:spread">landscape</meta>

    <!-- Primary writing mode: use horizontal-lr for western comics,
         horizontal-rl for manga -->
    <meta name="primary-writing-mode" content="{{WRITING_MODE}}"/>

  </metadata>

  <manifest>
    <!-- Navigation -->
    <item id="nav"
          href="nav.xhtml"
          media-type="application/xhtml+xml"
          properties="nav"/>
    <item id="ncx"
          href="toc.ncx"
          media-type="application/x-dtbncx+xml"/>

    <!-- Stylesheet -->
    <item id="css"
          href="css/comic.css"
          media-type="text/css"/>

    <!-- Cover image -->
    <item id="cover-image"
          href="images/cover.jpg"
          media-type="image/jpeg"
          properties="cover-image"/>

    <!-- Cover page -->
    <item id="cover-page"
          href="pages/cover.xhtml"
          media-type="application/xhtml+xml"/>

    <!-- Comic page images — repeat for each page -->
    <item id="img-page001"
          href="images/page001.jpg"
          media-type="image/jpeg"/>
    <!-- {{REPEAT: img-page items}} -->

    <!-- Comic page HTML — repeat for each page -->
    <item id="page001"
          href="pages/page001.xhtml"
          media-type="application/xhtml+xml"/>
    <!-- {{REPEAT: page items}} -->

  </manifest>

  <spine toc="ncx">
    <!-- Cover: linear="no" prevents double cover display -->
    <itemref idref="cover-page" linear="no"/>

    <!-- Comic pages in reading order -->
    <itemref idref="page001"/>
    <!-- {{REPEAT: itemref entries}} -->
  </spine>

  <guide>
    <reference type="cover" title="Cover" href="pages/cover.xhtml"/>
    <reference type="start" title="Start" href="pages/page001.xhtml"/>
  </guide>

</package>
```

**Variable substitutions:**
- `{{COMIC_TITLE}}` — title string
- `{{AUTHOR_NAME}}` — creator string
- `{{UNIQUE_UUID}}` — generate with UUID v4, format: `urn:uuid:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- `{{PUBLICATION_DATE}}` — ISO 8601 format: `2025-01-01`
- `{{PAGE_WIDTH}}` — pixel width of source images (e.g. 1920)
- `{{PAGE_HEIGHT}}` — pixel height of source images (e.g. 1200)
- `{{ORIENTATION}}` — `landscape` for standard comics, `portrait` for manga
- `{{WRITING_MODE}}` — `horizontal-lr` for western, `horizontal-rl` for manga

---

### 3.4 — OEBPS/toc.ncx

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
  "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"
     version="2005-1">
  <head>
    <meta name="dtb:uid" content="{{UNIQUE_UUID}}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>{{COMIC_TITLE}}</text>
  </docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>Start</text></navLabel>
      <content src="pages/page001.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
```

---

### 3.5 — OEBPS/nav.xhtml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops"
      xml:lang="en">
  <head>
    <meta charset="UTF-8"/>
    <title>{{COMIC_TITLE}}</title>
  </head>
  <body>
    <nav epub:type="toc" id="toc">
      <ol>
        <li><a href="pages/page001.xhtml">Start Reading</a></li>
      </ol>
    </nav>
    <nav epub:type="landmarks">
      <ol>
        <li><a epub:type="bodymatter" href="pages/page001.xhtml">Start</a></li>
      </ol>
    </nav>
  </body>
</html>
```

---

### 3.6 — OEBPS/css/comic.css

```css
/* CSS Reset — required for consistent Kindle rendering */
* {
  margin: 0;
  padding: 0;
  border: 0;
}

/* Fixed layout page body */
html, body {
  width: 100%;
  height: 100%;
  overflow: hidden;
  background-color: #000000;
}

/* Full-bleed page container */
.page {
  position: absolute;
  width: 100%;
  height: 100%;
  margin: 0;
  padding: 0;
}

/* Full page comic image */
.page-image {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
}

/* Panel tap target anchor — invisible overlay */
a.app-amzn-magnify {
  display: block;
  position: absolute;
  text-decoration: none;
  background: transparent;
}

/* Panel source div — defines tap area */
.panel-source {
  position: absolute;
  background: transparent;
}

/* Panel target div — defines zoom view area */
.panel-target {
  position: absolute;
  background: transparent;
}
```

---

### 3.7 — OEBPS/pages/cover.xhtml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width={{PAGE_WIDTH}}, height={{PAGE_HEIGHT}}"/>
    <title>{{COMIC_TITLE}}</title>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
  </head>
  <body>
    <div class="page">
      <img class="page-image"
           src="../images/cover.jpg"
           alt="Cover"/>
    </div>
  </body>
</html>
```

---

### 3.8 — OEBPS/pages/page001.xhtml
**This is the most important template — the panel markup structure.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width={{PAGE_WIDTH}}, height={{PAGE_HEIGHT}}"/>
    <title>Page 1</title>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
  </head>
  <body>
    <div class="page">

      <!-- Full page image — always first -->
      <img class="page-image"
           src="../images/page001.jpg"
           alt="Page 1"/>

      <!-- ============================================
           PANEL MARKUP — repeat block for each panel
           CRITICAL RULES:
           - <a> and target <div> must be SIBLINGS
           - targetId must exactly match target div id
           - sourceId must exactly match source div id
           - ordinal starts at 1, increments per panel
           - All coordinates are % of page dimensions
           - Target view should be ~150% of source area
           ============================================ -->

      <!-- Panel 1 -->
      <a class="app-amzn-magnify"
         data-app-amzn-magnify='{"targetId":"p1-panel1-t","sourceId":"p1-panel1-s","ordinal":1}'>
        <div id="p1-panel1-s"
             class="panel-source"
             style="top:{{P1_TOP}}%; left:{{P1_LEFT}}%; width:{{P1_WIDTH}}%; height:{{P1_HEIGHT}}%;">
        </div>
      </a>
      <div id="p1-panel1-t"
           class="panel-target"
           style="top:{{P1_TOP}}%; left:{{P1_LEFT}}%; width:{{P1_WIDTH}}%; height:{{P1_HEIGHT}}%;">
      </div>

      <!-- Panel 2 -->
      <a class="app-amzn-magnify"
         data-app-amzn-magnify='{"targetId":"p1-panel2-t","sourceId":"p1-panel2-s","ordinal":2}'>
        <div id="p1-panel2-s"
             class="panel-source"
             style="top:{{P2_TOP}}%; left:{{P2_LEFT}}%; width:{{P2_WIDTH}}%; height:{{P2_HEIGHT}}%;">
        </div>
      </a>
      <div id="p1-panel2-t"
           class="panel-target"
           style="top:{{P2_TOP}}%; left:{{P2_LEFT}}%; width:{{P2_WIDTH}}%; height:{{P2_HEIGHT}}%;">
      </div>

      <!-- {{REPEAT panel blocks — increment ordinal and IDs for each panel}} -->

    </div>
  </body>
</html>
```

**Panel coordinate variables (per detected panel):**
- `{{P#_TOP}}` — top edge as % of page height (e.g. `0.00` to `100.00`)
- `{{P#_LEFT}}` — left edge as % of page width
- `{{P#_WIDTH}}` — panel width as % of page width
- `{{P#_HEIGHT}}` — panel height as % of page height

**Coordinate conversion formula (pixels to percent):**
```
top%    = (pixel_y / image_height) * 100
left%   = (pixel_x / image_width)  * 100
width%  = (pixel_w / image_width)  * 100
height% = (pixel_h / image_height) * 100
```

**ID naming convention (must be unique across entire book):**
```
p{PAGE_NUMBER}-panel{PANEL_NUMBER}-s   ← source div
p{PAGE_NUMBER}-panel{PANEL_NUMBER}-t   ← target div
```
Example: page 3, panel 2 → `p3-panel2-s` and `p3-panel2-t`

---

## 4. PAGE WITH NO PANELS (full splash page)

For pages where no panels were detected — splash pages, chapter breaks, covers —
use this simplified template with NO panel markup at all:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width={{PAGE_WIDTH}}, height={{PAGE_HEIGHT}}"/>
    <title>Page {{PAGE_NUM}}</title>
    <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
  </head>
  <body>
    <div class="page">
      <img class="page-image"
           src="../images/page{{PAGE_NUM_PADDED}}.jpg"
           alt="Page {{PAGE_NUM}}"/>
    </div>
  </body>
</html>
```

Kindle will apply Virtual Panel 2x2 to these pages automatically, which is
acceptable behavior for splash pages.

---

## 5. MANGA MODE DIFFERENCES

For right-to-left manga, change these values:

**OPF metadata:**
```xml
<meta name="orientation-lock" content="portrait"/>
<meta name="primary-writing-mode" content="horizontal-rl"/>
<meta property="rendition:orientation">portrait</meta>
```

**Panel reading order:** ordinal values go right-to-left, top-to-bottom.
Panel 1 = top-right, Panel 2 = top-left, Panel 3 = mid-right, etc.

---

## 6. ZIP ASSEMBLY ORDER

The EPUB ZIP must be assembled in this exact order:

1. `mimetype` — UNCOMPRESSED (store only, deflate=0)
2. `META-INF/container.xml` — normal compression
3. `OEBPS/content.opf` — normal compression
4. `OEBPS/toc.ncx` — normal compression
5. `OEBPS/nav.xhtml` — normal compression
6. `OEBPS/css/comic.css` — normal compression
7. `OEBPS/images/*` — normal compression
8. `OEBPS/pages/*` — normal compression

**Swift ZIP note:** Use `ZipArchive` or `Zip` package. Set compression method to
`.store` (level 0) for the mimetype entry only. All other files use `.deflate`.

---

## 7. VALIDATION CHECKLIST

Before sending to Kindle Previewer 3, verify:

- [ ] `mimetype` is uncompressed and first in ZIP
- [ ] `content.opf` has `RegionMagnification` with exact casing
- [ ] `content.opf` has `book-type` set to `comic`
- [ ] `content.opf` has `fixed-layout` set to `true`
- [ ] `content.opf` has `rendition:layout` set to `pre-paginated`
- [ ] Every page HTML has correct `viewport` meta tag with actual pixel dimensions
- [ ] All `targetId` values match their target `<div>` `id` attributes exactly
- [ ] All `sourceId` values match their source `<div>` `id` attributes exactly
- [ ] All IDs are unique across the entire book (not just per page)
- [ ] Ordinal values start at 1 on each page
- [ ] `<a>` anchors and target `<div>` elements are siblings, not nested
- [ ] All images are JPEG (not PNG)
- [ ] Cover image is referenced in manifest with `properties="cover-image"`
- [ ] Spine includes all pages

---

## 8. COMMON FAILURE MODES AND FIXES

| Symptom | Cause | Fix |
|---|---|---|
| 2x2 virtual panel fallback on all pages | Missing `RegionMagnification` or `book-type` in OPF | Add both meta tags with exact casing |
| 2x2 fallback on specific pages only | Malformed panel markup on those pages | Check sibling structure and ID matching |
| Panels fire but in wrong order | Ordinal values incorrect or non-sequential | Ensure ordinals are 1,2,3... per page |
| Panels fire but zoom wrong area | Source and target div coordinates don't match intent | Verify coordinate math: pixels→percent |
| Book opens but no panel navigation | `rendition:layout` not set to `pre-paginated` | Add EPUB3 rendition meta tags |
| Previewer shows blank pages | Viewport dimensions don't match actual image size | Set viewport width/height to actual pixel dimensions |
| Double cover displayed | Cover page in spine without `linear="no"` | Add `linear="no"` to cover spine itemref |
