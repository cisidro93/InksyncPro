# InksyncPro Product Bible

**Last Updated:** June 9, 2026

---

## Product Vision

InksyncPro is the premier, state-of-the-art iOS/iPadOS comic and manga reading platform. It is designed to bridge the gap between casual reading and professional, high-performance study and annotation. The application seamlessly integrates local, iCloud, and external storage (Dropbox, Google Drive) without sacrificing performance or aesthetics.

The user experience philosophy: **the app should feel like a beautifully crafted home, not a distracted utilitarian tool.** Every surface, animation, and interaction must feel like it was designed for the modern age.

---

## Core Pillars

1. **Uncompromising Aesthetics:** A modern, premium, frosted-glass UI with rich micro-animations that rivals or exceeds any first-party Apple application or top-tier competitor (e.g., Panels, Comic Zeal).

2. **Robust Data Integrity & Sentinel Security:** Cloud-first, non-destructive architecture with strict lifecycle management. Features an `InstallGuardService` utilizing a non-synced Sentinel file (`.inksync_install_sentinel_v1`) stored in the local `Application Support` directory to accurately detect clean installations versus app updates. Wipes ghost files synced by iCloud in the public `Documents` directory upon fresh installs, avoiding Vault-based copy mechanisms that cause storage bloat and compiler debt.

3. **High-Performance Architecture:** Swift 6 concurrency compliance, background-threaded extraction, and robust memory management preventing OOM crashes. The conversion pipeline utilizes `O(1)` memory disk streaming for massive `.cbz` payloads to bypass `JetsamEvent` kills. The reader uses `CGImageSourceCreateThumbnailAtIndex` for professional image downsampling during the I/O read phase, a custom LRU `NSCache` with `maxCacheSize = 7` to restrict the memory footprint to ~15MB, and asynchronous prefetching tasks (`±2` pages around the active page) to ensure seamless reading performance.

4. **Crash-Free Import & Conversion Pipeline:** Every import operation opens security-scoped resource access explicitly before touching user-selected files. Heavy I/O (ZIP packaging, RAR extraction) is always moved off the Swift cooperative thread pool via `DispatchQueue.global` + `withCheckedThrowingContinuation`. All temporary directories are strictly cleaned up with `defer` regardless of outcome, preventing SSD bloat and subsequent I/O failures.

5. **Diagnostic Telemetry Engine:** `MemoryMonitor` runs a persistent 2-second heartbeat checking `os_proc_available_memory()`. If RAM drops below critical thresholds, it triggers aggressive cache purges. Full crash analytics and memory telemetry are logged locally to `.ips` and `.json` formats for debugging without compromising user privacy.

6. **Future Extensibility:** Architecture designed to support Zettelkasten integrations, advanced markdown exports, and precision page editing tools in future iterations (currently prepared in `V2_Archive`).

---

## Feature Architecture

### 1. Library & Organization

- **Modern Grid & List:** High-performance SwiftData-backed library views featuring dynamic sorting (Date Added, Title, Size, Favorites, Type, Extension Type, Location) and live filtering (Unread, Reading, Completed, On Drive, Cloud).

- **Apple Books-Style Content Shelves:** Persisted shelf selector tab strip (All / Comics / Manga / Books) featuring custom icons, label names, live item count badges, accent colors (Blue, Red-Orange, Teal), and micro-animated scale transitions.

- **Smart Collections Engine:** Dynamic, rule-based filtering accessible via an elegant "overflow strip" in the library header. Predefined collections include:
  - *Recently Added* (Top 50 newest additions)
  - *Reading Now* (In-progress items, sorted by last opened)
  - *All Unread* (Untouched items)
  - *Manga Mode* (Items flagged for right-to-left reading)
  - *Completed* (Finished items)

- **Smart Series Grouping:** Automatic grouping of issues by parsed metadata or folder structure, with support for nested collections, manual sort orders, and automatic cover assignment.

---

### 2. The Guided Reading Experience

- **ReaderProgressTracker:** The single source of truth for reading telemetry, page tracking, reading streaks, and last-opened timestamps. Synced across devices via iCloud.

- **Reading Mode Quick Picker:** A bottom-anchored frosted capsule that pops up on swipe-up gestures when the chrome is hidden, letting users instantly switch and persist per-book layouts:
  - *Normal* (Horizontal LTR page turns)
  - *Manga* (Native RTL reading and tracking)
  - *Webtoon* (Continuous vertical scrolling with page redraw isolation)

- **Panel Navigation (Guided View):** Intelligent, Vision-framework-powered panel detection (`EnsemblePanelDetector`). Provides a curated, panel-by-panel guided reading experience with graceful fallbacks and frosted HUD overlays.

- **Manga Native:** Fully supports right-to-left orientation and specifically tracks books requiring this mode.

---

### 3. E-Ink Conversion & Optimization Pipeline

#### 3.1 Resolution-Aware Scaling (`EInkOptimizer`)

Downsamples images using aspect-fit rendering to match target e-reader profiles:

| Device | Resolution | Notes |
| --- | --- | --- |
| Kindle Scribe Colorsoft 11" | 1980 × 2640 px (300 PPI) | Primary target |
| Kindle Scribe Colorsoft 7" | 1264 × 1680 px (300 PPI) | |
| Kindle Paperwhite | 1236 × 1648 px (300 PPI) | |
| Kobo Elipsa | 1404 × 1872 px (227 PPI) | |
| Boox Note Air | 1404 × 1872 px (227 PPI) | |

Features dynamic orientation-aware scaling to rotate spreads for landscape screens.

#### 3.2 EPUB Output — Kindle Compliance Standard

All EPUBs produced by `CBZToEPUBConverter` and `EPUBManifestBuilder` **must** conform to the following rules to pass both sideloading (AZW3) and Send to Kindle cloud conversion (KFX) without E013 / E999 errors:

##### CSS — Approved Subset Only

```css
/* ✅ ALLOWED */
@page { margin: 0; padding: 0; }
html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
.page { width: 100%; height: 100%; }
img { display: block; width: 100%; height: 100%; }

/* ❌ BANNED — causes E013 on Send to Kindle cloud converter */
/* position: fixed          — not in KF8/KFX CSS subset */
/* overflow: hidden          — not in Kindle CSS subset */
/* @media amzn-kf8          — proprietary at-rule, rejected by cloud XML validator */
/* @media amzn-kfx          — proprietary at-rule, rejected by cloud XML validator */
/* @page { size: ... }      — CSS Paged Media L3, rejected by Amazon cloud validator */
/* object-fit: contain      — not in Kindle CSS subset */
/* object-position: center  — not in Kindle CSS subset */
```

**Page sizing** is controlled entirely by `<meta name="viewport" content="width=1980, height=2640"/>` and the `rendition:layout pre-paginated` OPF metadata — never by `@page { size }`. *Critically, viewport tags must NOT include `initial-scale=1.0`, as this triggers E013 rendering kernel panics and screen bricking on older Kindle firmware.*

**Cover page** body element must carry `epub:type="cover"`:

```html
<body epub:type="cover"><img src="../images/cover.jpg" alt="Cover"/></body>
```

**Dual-page (landscape) spreads** are handled by `rendition:spread auto` in the OPF — do not generate custom two-page XHTML. Kindle Scribe Colorsoft renders spreads natively in landscape when the OPF declares `rendition:spread auto`.

**Manga RTL** is declared via `<spine page-progression-direction="rtl">` in the OPF — do not rely on CSS `direction: rtl` as Kindle ignores it for page-turn direction.

#### 3.3 Other Conversion Features

- **Asymmetric Binding Margins:** Generates gutter space padding (Left, Right, or Alternating Odd/Even) at the native device resolution to offset physical bindings.

- **Auto-Cropping:** Scans `CGImage` pixel thresholds to strip blank/white borders before scaling, maximizing the active artwork area.

- **Moiré Reduction:** Pre-scaling Gaussian blur to suppress high-frequency screentone matrices and prevent screen interference patterns, paired with post-conversion re-sharpening.

- **Color Space Safety:** `UIGraphicsImageRenderer` output **must** be forced to `.standard` (sRGB) color space. Exporting badged covers or merged graphics in wide-gamut (P3) color spaces will silently crash E-Ink devices upon loading.

- **Hardware Grayscale & Dithering:** Strips color saturation and applies a 15% contrast boost via `CIColorControls` to enhance text legibility, combined with `CIColorPosterize` 16-level ordered dithering to match Kindle and e-reader panels.

---

### 4. Import & Cloud Infrastructure

#### 4.1 Import Pipeline Architecture

All import operations follow a strict sequence:

1. **Security Scope:** `url.startAccessingSecurityScopedResource()` called *before* any file operation. Scope is held open for the full duration of extraction and released immediately after.
2. **Background Extraction:** All archive extraction (ZIP via ZIPFoundation, RAR via libunrar) runs on `DispatchQueue.global(qos: .userInitiated)` via `withCheckedThrowingContinuation` — never on the Swift cooperative thread pool or the main actor.
3. **Temp Directory Lifecycle:** Every temp directory created during import or conversion is tracked and removed with `defer { try? fileManager.removeItem(at: tempDir) }` regardless of success or failure. Per-entry temp files use UUID names to prevent cross-file data corruption.
4. **Atomic Writes:** Final output files are written atomically. On EPUB rebuild, the new archive is built in a temp path and swapped with `FileManager.moveItem` — never written directly over the live file.
5. **Library Scan:** `scanLibrary()` is called on `@MainActor` after all copy/import tasks complete.

#### 4.2 Supported Formats

| Format | Handler | Notes |
| --- | --- | --- |
| `.cbz` / `.zip` | `ZipUtilities` + ZIPFoundation | Primary format |
| `.cbr` / `.rar` | `CBRExtractor` + libunrar | Requires security scope before `Unrar.Archive(fileURL:)` |
| `.epub` | `EPUBImporter` | Extracted to images, repackaged as CBZ |
| `.pdf` | `ConversionEngine` | Split into pages |

#### 4.3 Other Infrastructure

- **Universal Conversion Engine:** Non-blocking background threads for all heavy extractions. `ConversionOrchestrator` manages job lifecycle.

- **Linked External Drives:** Users can link Dropbox, Google Drive, or physical external SSDs. The `DriveMonitor` constantly syncs file changes.

- **Streaming Architecture:** Remote files require a `resolveLocalURL` gate to safely cache and process without mutating the cloud source.

- **Wi-Fi Server:** A secure, rate-limited local server for wireless, high-speed comic importing via a web browser.

---

### 5. Apple Ecosystem Integration

- **Spotlight Indexing:** Every comic is deeply indexed by iOS Spotlight. Users can swipe down on their home screen and search for a comic title to jump directly into the book.

- **App Intents (Siri Shortcuts):** Fully parametric iOS Shortcuts:
  - *Resume Reading:* Jump instantly back to the active book.
  - *Open Specific Book:* Ask Siri to open a specific title from the library.
  - *Panel Mode Launch:* Open the most recent comic directly into Guided Panel Mode.
  - *Add Bookmark:* Headless shortcut to bookmark the current active page.

- **Keychain API Key Storage:** ComicVine API keys are stored securely in the iOS Keychain, migrating legacy plaintext settings JSON on first launch.

- **100% On-Device AI Processing:** All panel detection is run locally using the CoreML Neural Engine, removing dependencies on external AI vendors to preserve absolute user privacy.

---

## UI / UX Design Language

- **Theme System:** Adheres to a strict, centralized `Theme` struct utilizing `Theme.bg`, `Theme.surface`, `Theme.text`, and `Theme.orange` for highlights.

- **Materials:** Extensive use of `.ultraThinMaterial` and `.regularMaterial` over gradient backgrounds to create a deep, layered, iOS-native feel.

- **Typography:** `Inter` or `Rounded` system fonts heavily utilized to provide crisp, legible metadata tags.

- **Animations:** Swift spring animations (`.spring(response: 0.3, dampingFraction: 0.75)`) provide tactile feedback on menus, transitions, and layout changes.

---

## Engineering Standards

### Concurrency Rules

| Rule | Rationale |
| --- | --- |
| All `FileManager` operations go on `DispatchQueue.global` | Prevents cooperative thread pool starvation |
| `UIImage(contentsOfFile:)` always inside `autoreleasepool` on background thread | Prevents OOM on main stack |
| `@MainActor` properties updated only via `await MainActor.run {}` | Swift 6 strict concurrency compliance |
| Security-scoped URLs: scope opened before, closed after any file access | iOS sandbox enforcement; missing scope = `EACCES` crash |
| Temp dirs always cleaned up with `defer { try? fileManager.removeItem(at:) }` | Prevents storage accumulation leading to OOM kills |
| Per-entry temp files in ZIP migration loops use UUID names | Prevents `transfer.tmp` overwrite race → CRC crash |

### Memory Management

- `NSCache` with `maxCacheSize = 7` caps the live page buffer to ~15MB.
- `CGImageSourceCreateThumbnailAtIndex` used for cover/thumbnail generation (not `UIImage(contentsOfFile:)`).
- Large bitmap operations wrapped in `autoreleasepool` to release decoded pixel buffers promptly.

### Kindle EPUB Validation Checklist

Before any EPUB output is delivered to the user, it must satisfy:

- [ ] `mimetype` is the **first entry**, stored **uncompressed** (EPUB §3.3)
- [ ] `META-INF/container.xml` is the **second entry**, stored uncompressed
- [ ] `rendition:layout` = `pre-paginated` declared in OPF `<metadata>`
- [ ] `rendition:spread` = `auto` declared in OPF `<metadata>`
- [ ] `<meta name="viewport" content="width=W, height=H"/>` present in every XHTML `<head>`
- [ ] **NO** `initial-scale=1.0` in the viewport meta tag
- [ ] No `position: fixed` in any CSS
- [ ] No `@media amzn-kf8` or `@media amzn-kfx` blocks
- [ ] No `@page { size: ... }` declarations
- [ ] No `object-fit` or `object-position` CSS
- [ ] Cover body element carries `epub:type="cover"`
- [ ] No remote HTTP(S) resources (tracking pixels, fonts, stylesheets) — causes E999
- [ ] OPF `<package>` carries `prefix="rendition: http://www.idpf.org/vocab/rendition/#"`

---

## Inactive / Archived / Planned V2 Features

The following features and their corresponding code/view files are currently moved to the `V2_Archive` directory and are not compiled or active in the current MVP build to maintain a clean footprint and avoid scope creep:

### 1. Library Gamification & Engagement

- **Badges & Streaks:** Visual indicators for series completion and consecutive daily reading streaks. Code files `GamificationManager.swift` and `GamificationDashboardView.swift` are located in `V2_Archive/`.

### 2. Creative Work Area & Precision Editor

- **Workspace Focus List:** A workspace view that displays only explicitly sent files for research/annotation, preventing library-wide editing clutter.
- **Multi-Page Preview:** Dynamic previews in the Work Area leveraging `PageModelStore` to simulate panel flows.
- **Precision Canvas:** High-fidelity cropping, splitting, PencilKit drawing, and page margin trimming tools. Code files `PrecisionCanvasView.swift`, `PencilKitDrawView.swift`, `AdvancedWorkspaceView.swift`, and other editor sheets/views are located in `V2_Archive/Editor/`.

### 3. Study Notes & Zettelkasten Graph

- **Zettelkasten Hub:** A frosted-glass knowledge graph displaying annotation nodes, book sources, and tag groups. Features Multi-Indexed "By Topic" sorting, allowing highlights to appear under multiple themes, with collapsible headers and an alphabetical search index.
- **Zettel Board:** A high-performance column-based Kanban outliner and review board to organize highlights and compile structured manuscript outlines.
- **Annotation Export:** Exporting highlights, notes, and clipped panels to Obsidian-compliant Markdown.
- **Interactive Page-Linking & Previews:** Subsystem using double-bracket links (e.g. `[[Page X]]`) with floating preview popups. Code files `GlobalZettelkastenHubView.swift`, `ZettelkastenGraphView.swift`, `ZettelkastenBoardView.swift`, `StudyNotebookView.swift`, and `ZettelkastenExporter.swift` are located in `V2_Archive/` and `V2_Archive/Editor/`.
- **Intelligent Auto-Tagging:** Background NLP (Natural Language Processing) analyzing untagged highlights and extracting entities/keywords.

---

## Known Limitations & Future Work

- **ThumbnailDaemon cache** should be moved from `Documents/` to `Application Support/` to prevent iCloud sync of cache files.
- **NSCache warm-on-launch**: When a cover image already exists on disk, the `NSCache` should be pre-warmed on app launch rather than waiting for the first library scroll.
- **Dead code audit**: Follow each line of code to identify and remove unreachable paths.
- **Library UX (iPad):** The main library page needs a premium, non-utilitarian redesign for iPadOS that makes full use of the large canvas.
