# InksyncPro Product Bible

**Last Updated:** August 17, 2026  
**Architecture Version:** Swift 6.0 Strict Concurrency • iOS 17.0+ • iPadOS 17.0+  
**Target Hardware:** iPhone 15/16 Pro, iPad Mini (8.3"), iPad Air (11"), iPad Pro (11" & 13" M4 120Hz ProMotion)

---

## Product Vision

InksyncPro is the premier, state-of-the-art iOS and iPadOS reading, conversion, and knowledge-synthesis ecosystem for comics, manga, digital EPUBs, and academic PDFs. It bridges the gap between distraction-free casual reading and high-performance, professional study and annotation. The application seamlessly harmonizes local sandboxes, iCloud ubiquity, and external cloud/drive storage without sacrificing 120Hz ProMotion fluidity, visual beauty, or zero-leak memory safety.

The core user experience philosophy: **the app should feel like a beautifully crafted, distraction-free home, not a utilitarian tool.** Every surface, glassmorphic container, typography scale, and gesture interaction is engineered to the highest Apple design standards.

---

## Master Architecture Protocol (Educator Synthesis)

```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           INKSYNC PRO KERNEL ARCHITECTURE                       │
├─────────────────────────┬───────────────────────────┬───────────────────────────┤
│    POINT-FREE SWIFT 6   │    KAVSOFT PROMOTION      │    PAUL HUDSON NATIVE     │
│   Strict Actor State    │   Glassmorphic 120Hz UX   │   PDFKit • WebKit • Pencil│
├─────────────────────────┼───────────────────────────┼───────────────────────────┤
│    THEPRIMEAGEN ZERO    │   VISUAL KERNEL STUDY     │   E-INK CLOUD PIPELINE    │
│  Zero-Leak Memory & JIT │ Zettelkasten • OCR Reflow │  Kindle Scribe • Colorsoft│
└─────────────────────────┴───────────────────────────┴───────────────────────────┘
```

---

## Key Subsystems & Architectural Foundations

### 1. High-Performance Hybrid Reader Engines

- **Pro Vector PDF Reader (`ProPDFReaderEngine`):** Fully integrated with Apple's native `PDFKit`. Features continuous 120Hz ProMotion scaling, custom double-tap column-aware zooming, 3-mode margin cropping (None, Smart Auto, and Precision Custom Insets), dual-page landscape median layout, and Apple PencilKit vector annotation overlay.
- **Smart 3D Curl Manga/Comic Reader (`ComicReaderEngine` & `BookPageTurnEngine`):** Leverages `UIPageViewController` with true 3D page curl physics. Frame-0 image pre-caching eliminates transition flash, and multi-spread geometry offsets split 2-up splash pages for both LTR and RTL reading directions.
- **Reflowable WebKit EPUB Engine (`EBookPageCurlReader`):** Full-bleed reflow engine with dynamic live CSS injection (`EPUBStyleSheetBuilder`), uncompressed snapshot caching for native page curls, and leak-free JavaScript bridge handlers.

---

### 2. Cross-Process Staging & File Ingestion

- **`SharedImportCoordinator` Background Actor:** Manages file imports from Share Extensions, AirDrop, and Files.app "Open In Place" operations.
- **Settle Checks & Retry Loops:** Verifies file size stability over a minimum 150ms delta, ensuring incomplete byte streams are not prematurely ingested.
- **Unified Navigation Bridge:** Automatically selects newly ingested documents and triggers `AppRouter.presentFullScreen(.read(pdf))` for instant reading.

---

### 3. Study, Annotation & Knowledge Graph

- **Cornell 3-Zone Note Layout (`CornellNoteEditorView`):** Structured cue columns, note-taking canvas, and synthesis summary sections with Markdown and Obsidian vault export.
- **Zettelkasten Auto-Linker (`ZettelkastenAutoLinker`):** Analyzes `[[WikiLink]]` tokens and `#tag` clusters to build an in-memory bidirectional graph rendered via `ZettelkastenGraphView`.
- **PencilKit Layer Isolation (`MarginPencilCanvasView`):** Disambiguates drawing touches from navigation gestures, enabling seamless Apple Pencil annotation over pages.

---

### 4. Local Wi-Fi & Device Ecosystem

- **Local Wi-Fi Server (`WiFiServer`):** Embedded HTTP daemon on port 8080 supporting PIN-protected web uploads and downloads.
- **Apple Multipeer Connectivity (`ReadingRoomSession` & `PeerManager`):** Real-time collaborative reading and page synchronization across nearby iPads and iPhones.

---

### 5. E-Ink Conversion & Sideloading Pipeline

#### Resolution-Aware Device Profiles (`EInkOptimizer`)

| Device | Resolution | PPI | Target Profile |
| :--- | :--- | :--- | :--- |
| **Kindle Scribe Colorsoft 11"** | 1980 × 2640 px | 300 PPI | Primary E-Ink Target |
| **Kindle Scribe Colorsoft 7"** | 1264 × 1680 px | 300 PPI | Portable Scribe |
| **Kindle Paperwhite** | 1236 × 1648 px | 300 PPI | Standard E-Reader |
| **Kobo Elipsa / Boox Note Air** | 1404 × 1872 px | 227 PPI | Open Android / Kobo |

#### Kindle EPUB Compliance Standard

All generated EPUBs conform strictly to Amazon's Send to Kindle (KFX) and sideloading (AZW3) validator rules:

- Viewport declared via `<meta name="viewport" content="width=1980, height=2640"/>` (**NO `initial-scale=1.0`**).
- No forbidden CSS (`position: fixed`, `overflow: hidden`, `@page { size }`, `@media amzn-*`).
- Sequential Floyd-Steinberg 16-level error diffusion dithering for smooth grayscale transitions without banding.
- Srgb standard color space enforcement preventing wide-gamut (P3) rendering panics.

---

### 6. Study Notebook & Relational Zettelkasten Suite

- **Cornell 3-Zone Paper Templates:** Digital paper styles supporting Ruled (`24pt`), College Ruled (`21pt`), and Legal (`28pt`) rule baselines in ivory yellow (`#FFFDF0`) and charcoal themes.
- **Relational Obsidian Vault Exporter:** Packages notes, quotes, and metadata into a nested Obsidian vault structure, pre-rendering PencilKit drawings into transparent PNGs with wiki-links.
- **PARA Method (Tiago Forte):** First-class classification into Projects (🚀), Areas (🏡), Resources (📚), and Archives (📦).
- **Adler Semantic Marginalia:** Instant shorthand tagging (`? Question`, `! Insight`, `★ Core Thesis`, `≠ Counter-Argument`, `Δ Logic Shift`).

---

## Technical Specifications & Concurrency Rules

```swift
// Swift 6 Strict Concurrency Architecture Pattern
@MainActor
final class UnifiedReaderState: ObservableObject {
    @Published var activePage: Int = 0
    @Published var isChromeVisible: Bool = false
    
    // Background heavy lifting offloaded to actors
    func performBackgroundAnalysis(for documentID: UUID) {
        Task.detached(priority: .userInitiated) {
            let result = await DocumentAnalysisActor.shared.analyze(documentID)
            await MainActor.run {
                self.applyResult(result)
            }
        }
    }
}
```

| Invariant | Standard | Enforcement |
| :--- | :--- | :--- |
| **State Mutation** | Single Source of Truth | `ReaderProgressTracker.shared`, `AnnotationStore.shared` |
| **Main Thread Safety** | `@MainActor` UI Isolation | All SwiftUI views and UIKit representables run on `@MainActor` |
| **Heavy I/O & Parsing** | Background Actor Isolation | Archive decompression and OCR parsing run on `Task.detached` |
| **Memory Buffer Cap** | LRU `NSCache` $\le$ 20 Pages | Prevents Jetsam memory kills on high-DPI spreads |
| **File Sandbox Scope** | Security-Scoped Bookmarks | Explicit `startAccessingSecurityScopedResource()` lifecycle |
| **Observer Teardown** | Clean `dismantleUIView` | Unregister all notification observers on view deinit |

---

## File Structure & Module Map

```text
InksyncPro/
├── Services/
│   ├── Core/           # InstallGuard, ZipUtilities, EBookParser, NarrationEngine
│   ├── Reader/         # JITComicCacheEngine, PageOCRService, ReaderUtilities
│   ├── Reflow/         # PDFSpatialParser, ReflowDOMSynthesizer
│   ├── State/          # ReaderProgressTracker, EBookPreferences, ReadingJumpTracker
│   └── Network/        # CloudDownloadManager, ActiveUploadRegistry
├── Views/
│   ├── Library/        # LibraryGridView, ReadNowTabView, DualExportView
│   ├── Reader/         # ProPDFReaderEngine, EBookPageCurlReader, ComicReaderEngine
│   │   └── Components/ # ProCropAdjustmentSheet, HyperlinkPreviewHUD, FloatingReaderClockOverlay
│   ├── Conversion/     # ConvertView, EInkOptimizer, ArchiveMutatorService
│   └── Study/          # StudyNotebookView, GlobalZettelkastenHubView, CorkboardView
└── Models/             # LibraryItem, Annotation, CodableCropInsets, ReadingStreak
```

---

## Deployment & Verification Baseline

- **Point of Truth Commit**: `078235e` (Permanent Baseline Tag)
- **Active Release Branch**: `ios-port`
- **Compiler Status**: 0 Errors, 0 Concurrency Warnings (Swift 6 Strict Mode)
