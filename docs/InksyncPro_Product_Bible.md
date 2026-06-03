# InksyncPro Product Bible

## Product Vision

InksyncPro is the premier, state-of-the-art iOS/iPadOS comic and manga reading platform. It is designed to bridge the gap between casual reading and professional, high-performance study and annotation. The application seamlessly integrates local, iCloud, and external storage (Dropbox, Google Drive) without sacrificing performance or aesthetics.

## Core Pillars

1. **Uncompromising Aesthetics:** A modern, premium, frosted-glass UI with rich micro-animations that rivals or exceeds any first-party Apple application or top-tier competitor (e.g., Panels, Comic Zeal).
2. **Robust Data Integrity & Sentinel Security:** Cloud-first, non-destructive architecture with strict lifecycle management. Features an `InstallGuardService` utilizing a non-synced Sentinel file (`.inksync_install_sentinel_v1`) stored in the local `Application Support` directory to accurately detect clean installations versus app updates. Wipes ghost files synced by iCloud in the public `Documents` directory upon fresh installs, avoiding Vault-based copy mechanisms that cause storage bloat and compiler debt.
3. **High-Performance Architecture:** Swift 6 concurrency compliance, background threaded extraction, and robust memory management preventing OOM crashes. Uses `CGImageSourceCreateThumbnailAtIndex` for professional image downsampling during the I/O read phase, a custom LRU `NSCache` with `maxCacheSize = 7` to restrict the memory footprint to ~15MB, and asynchronous prefetching tasks (`±2` pages around the active page) to ensure seamless reading performance.
4. **Professional Workflows:** Deep Zettelkasten integration, annotation markdown export, and precision extraction tools that elevate comic reading to professional study and research.

## Feature Architecture

### 1. Library & Organization

* **Modern Grid & List:** High-performance SwiftData-backed library views featuring dynamic sorting (Date Added, Title, Size, Favorites, Type, Extension Type, Location) and live filtering (Unread, Reading, Completed, On Drive, Cloud).
* **Apple Books-Style Content Shelves:** Persisted shelf selector tab strip (All / Comics / Manga / Books) featuring custom icons, label names, live item count badges, accent colors (Blue, Red-Orange, Teal), and micro-animated scale transitions.
* **Smart Collections Engine:** Dynamic, rule-based filtering accessible via an elegant "overflow strip" in the library header. Predefined collections include:
  * *Recently Added* (Top 50 newest additions)
  * *Reading Now* (In-progress items, sorted by last opened)
  * *All Unread* (Untouched items)
  * *Manga Mode* (Items flagged for right-to-left reading)
  * *Completed* (Finished items)
* **Smart Series Grouping:** Automatic grouping of issues by parsed metadata or folder structure, with support for nested collections, manual sort orders, and automatic cover assignment.
* **Badges & Streaks:** Visual indicators for series completion and consecutive daily reading streaks.

### 2. The Guided Reading Experience

* **ReaderProgressTracker:** The single source of truth for reading telemetry, page tracking, reading streaks, and last-opened timestamps. Synced across devices via iCloud.
* **Reading Mode Quick Picker:** A bottom-anchored frosted capsule that pops up on swipe-up gestures when the chrome is hidden, letting users instantly switch and persist per-book layouts:
  * *Normal* (Horizontal LTR page turns)
  * *Manga* (Native RTL reading and tracking)
  * *Webtoon* (Continuous vertical scrolling with page redraw isolation)
* **Panel Navigation (Guided View):** Intelligent, Vision-framework-powered panel detection (`EnsemblePanelDetector`). Provides a curated, panel-by-panel guided reading experience with graceful fallbacks and frosted HUD overlays.
* **Manga Native:** Fully supports right-to-left orientation and specifically tracks books requiring this mode.

### 3. The Work Area & Precision Editor

* **WorkspaceFocusManager:** A curation system that allows users to explicitly "Send to Work Area" only the files they are actively researching or modifying, preventing editor congestion.
* **Multi-Page Preview:** Dynamic previews in the Work Area leveraging `PageModelStore` to simulate the panel flow and visually inspect extractions before committing.
* **Precision Canvas:** Deep crop, split, and annotation tools allowing for exact modifications to comic pages.

### 4. E-Ink Conversion & Optimization Pipeline

* **Resolution-Aware Scaling (`EInkOptimizer`):** Downsamples images using aspect-fit rendering to match target e-reader profiles (e.g., Kindle Scribe Colorsoft, Colorsoft 7", Paperwhite, Kobo, Boox) to prevent rendering lag. Features dynamic orientation-aware scaling to rotate spreads for landscape screens.
* **Asymmetric Binding Margins:** Generates gutter space padding (Left, Right, or Alternating Odd/Even) at the native device resolution to offset physical bindings.
* **Auto-Cropping:** Scans CGImage pixel thresholds to strip blank/white borders before scaling, maximizing the active artwork area.
* **Moiré Reduction:** Pre-scaling Gaussian blur to suppress high-frequency screentone matrices and prevent screen interference patterns, paired with post-conversion re-sharpening.
* **Hardware Grayscale & Dithering:** Strips color saturation and applies a 15% contrast boost via `CIColorControls` to enhance text legibility, combined with `CIColorPosterize` 16-level ordered dithering to match Kindle and e-reader panels.

### 5. Import & Cloud Infrastructure

* **Universal Conversion Engine:** Supports `cbz`, `cbr`, `rar`, `zip`, and `pdf`. Uses non-blocking background threads to execute heavy extractions.
* **Linked External Drives:** Users can link Dropbox, Google Drive, or physical external SSDs. The `DriveMonitor` constantly syncs file changes.
* **Streaming Architecture:** Remote files require a `resolveLocalURL` gate to safely cache and process without mutating the cloud source.
* **Wi-Fi Server:** A secure, rate-limited local server for wireless, high-speed comic importing via a web browser.

### 6. Research & Zettelkasten

* **Zettelkasten Hub:** A frosted-glass knowledge graph displaying relationships between annotations, characters, and series. Features Multi-Indexed "By Topic" sorting, allowing cross-referenced highlights to appear under multiple themes, with collapsible headers and an alphabetical index bar for rapid navigation.
* **Intelligent Auto-Tagging:** Background NLP (Natural Language Processing) automatically analyzes untagged highlights and extracts lexical entities and contextual keywords to organize user research.
* **Zettel Board:** A high-performance Kanban-style outliner and review board. It enables column-based outlining, lazy-loaded lists (120 FPS performance), an inbox drawer for unassigned highlights, bidirectional note-to-note linking, and compiling structured highlight outlines directly into Manuscript documents.
* **Annotation Export:** Seamless export of highlights, notes, and clipped panels to Markdown (optimized for Obsidian integration).
* **Interactive Page-Linking & Previews:** An integrated cross-referencing subsystem using double-bracket page links (e.g., `[[Page X]]`). Tapping a page reference in the study notes summons a floating glassmorphic page preview modal displaying a high-fidelity thumbnail of the page. Features a single-tap "Jump to Page" controller to immediately scroll the textbook reader view. Leverages a specialized gesture interception delegate on the text editor's underlying text view to capture link-taps selectively without disrupting cursor placement, selections, or keyboard focus during normal text editing.

### 7. Apple Ecosystem Integration

* **Spotlight Indexing:** Every comic is deeply indexed by iOS Spotlight. Users can swipe down on their home screen and search for a comic title to jump directly into the book.
* **App Intents (Siri Shortcuts):** Fully parametric iOS Shortcuts:
  * *Resume Reading:* Jump instantly back to the active book.
  * *Open Specific Book:* Ask Siri to open a specific title from the library.
  * *Panel Mode Launch:* Open the most recent comic directly into Guided Panel Mode.
  * *Add Bookmark:* Headless shortcut to bookmark the current active page.
* **Keychain API Key Storage:** ComicVine API keys are stored securely in the iOS Keychain, migrating legacy plaintext settings JSON on first launch.
* **100% On-Device AI Processing:** All panel detection is run locally using the CoreML Neural Engine, removing dependencies on external AI vendors (OpenRouter, OpenAI, Anthropic, Gemini) to preserve absolute user privacy.

## UI / UX Design Language

* **Theme System:** Adheres to a strict, centralized `Theme` struct utilizing `Theme.bg`, `Theme.surface`, `Theme.text`, and `Theme.orange` for highlights.
* **Materials:** Extensive use of `.ultraThinMaterial` and `.regularMaterial` over gradient backgrounds to create a deep, layered, iOS-native feel.
* **Typography:** `Inter` or `Rounded` system fonts heavily utilized to provide crisp, legible metadata tags.
* **Animations:** Swift spring animations (`.spring(response: 0.3, dampingFraction: 0.75)`) provide tactile feedback on menus, transitions, and layout changes.
