# InksyncPro Product Bible

## Product Vision
InksyncPro is the premier, state-of-the-art iOS/iPadOS comic and manga reading platform. It is designed to bridge the gap between casual reading and professional, high-performance study and annotation. The application seamlessly integrates local, iCloud, and external storage (Dropbox, Google Drive) without sacrificing performance or aesthetics.

## Core Pillars
1. **Uncompromising Aesthetics:** A modern, premium, frosted-glass UI with rich micro-animations that rivals or exceeds any first-party Apple application or top-tier competitor (e.g., Panels, Comic Zeal).
2. **Robust Data Integrity:** Cloud-first, non-destructive architecture. External drives and cloud sources are strictly managed without in-place mutations to guarantee user data safety.
3. **High-Performance Architecture:** Swift 6 concurrency compliance, background threaded extraction, and robust memory management preventing OOM crashes, even on 1000+ page archives.
4. **Professional Workflows:** Deep Zettelkasten integration, annotation markdown export, and precision extraction tools that elevate comic reading to professional study and research.

## Feature Architecture

### 1. Library & Organization
* **Modern Grid & List:** High-performance SwiftData-backed library views featuring dynamic sorting (Date Added, Title, Size) and live filtering (Unread, Reading, Completed).
* **Smart Collections Engine:** Dynamic, rule-based filtering accessible via an elegant "overflow strip" in the library header. Predefined collections include:
  * *Recently Added* (Top 50 newest additions)
  * *Reading Now* (In-progress items, sorted by last opened)
  * *All Unread* (Untouched items)
  * *Manga Mode* (Items flagged for right-to-left reading)
  * *Completed* (Finished items)
* **Smart Series Grouping:** Automatic grouping of issues by parsed metadata or folder structure.
* **Badges & Streaks:** Visual indicators for series completion and consecutive daily reading streaks.

### 2. The Guided Reading Experience
* **ReaderProgressTracker:** The single source of truth for reading telemetry, page tracking, reading streaks, and last-opened timestamps. Synced across devices via iCloud.
* **Panel Navigation (Guided View):** Intelligent, Vision-framework-powered panel detection (`EnsemblePanelDetector`). Provides a curated, panel-by-panel guided reading experience with graceful fallbacks and frosted HUD overlays.
* **Manga Native:** Fully supports right-to-left orientation and specifically tracks books requiring this mode.

### 3. The Work Area & Precision Editor
* **WorkspaceFocusManager:** A curation system that allows users to explicitly "Send to Work Area" only the files they are actively researching or modifying, preventing editor congestion.
* **Multi-Page Preview:** Dynamic previews in the Work Area leveraging `PageModelStore` to simulate the panel flow and visually inspect extractions before committing.
* **Precision Canvas:** Deep crop, split, and annotation tools allowing for exact modifications to comic pages.

### 4. Import & Cloud Infrastructure
* **Universal Conversion Engine:** Supports `cbz`, `cbr`, `rar`, `zip`, and `pdf`. Uses non-blocking background threads to execute heavy extractions.
* **Linked External Drives:** Users can link Dropbox, Google Drive, or physical external SSDs. The `DriveMonitor` constantly syncs file changes.
* **Streaming Architecture:** Remote files require a `resolveLocalURL` gate to safely cache and process without mutating the cloud source.
* **Wi-Fi Server:** A secure, rate-limited local server for wireless, high-speed comic importing via a web browser.

### 5. Research & Zettelkasten
* **Zettelkasten Hub:** A frosted-glass knowledge graph displaying relationships between annotations, characters, and series.
* **Annotation Export:** Seamless export of highlights, notes, and clipped panels to Markdown (optimized for Obsidian integration).

### 6. Apple Ecosystem Integration
* **Spotlight Indexing:** Every comic is deeply indexed by iOS Spotlight. Users can swipe down on their home screen and search for a comic title to jump directly into the book.
* **App Intents (Siri Shortcuts):** Fully parametric iOS Shortcuts.
  * *Resume Reading:* Jump instantly back to the active book.
  * *Open Specific Book:* Ask Siri to open a specific title from the library.
  * *Panel Mode Launch:* Open the most recent comic directly into Guided Panel Mode.
  * *Add Bookmark:* Headless shortcut to bookmark the current active page.

## UI / UX Design Language
* **Theme System:** Adheres to a strict, centralized `Theme` struct utilizing `Theme.bg`, `Theme.surface`, `Theme.text`, and `Theme.orange` for highlights.
* **Materials:** Extensive use of `.ultraThinMaterial` and `.regularMaterial` over gradient backgrounds to create a deep, layered, iOS-native feel.
* **Typography:** `Inter` or `Rounded` system fonts heavily utilized to provide crisp, legible metadata tags.
* **Animations:** Swift spring animations (`.spring(response: 0.3, dampingFraction: 0.75)`) provide tactile feedback on menus, transitions, and layout changes.
