# Agent Guidelines & Workflow Rules

## Three-Developer Review & Defense Protocol
Whenever conducting code reviews, bug fixes, or feature additions (especially across reader engines and core application components):

1. **Phase 1: Senior Backend Developer Review**
   - Deep line-by-line audit of data models, serialization schemas, thread concurrency, memory allocation, caching actors, background task safety, and security-scoped file system/sandbox handles.
   - Enforce zero memory leaks, zero race conditions, zero data corruption, and robust error handling.

2. **Phase 2: Senior Frontend / UI / UX Developer Review**
   - Deep audit of SwiftUI/UIKit view hierarchies, ProMotion 120Hz performance, gesture recognizers, visual polish (frosted-glass glassmorphism, light/dark/sepia themes, ProMotion animations), haptic feedback, and user interaction flow.
   - Enforce zero UI jank, zero gesture conflicts, clean responsiveness across iOS/iPadOS screen sizes, and delightful micro-interactions.

3. **Phase 3: Senior Full-Stack Developer Harmonization Review**
   - End-to-end integration audit checking the harmony between backend actors/models and frontend views.
   - Validate state synchronization, progress tracking (`ReaderProgressTracker`), iCloud sync (`NSUbiquitousKeyValueStore`), settings persistence (`EBookPreferences`), and cross-module routing.

## Clean Code Handbook Protocol
Whenever reviewing, refactoring, or authoring code across reader engines, converters, models, or views:

1. **Single Responsibility Principle (SRP)**
   - Keep functions, structs, actors, and SwiftUI view components short and focused on a single task.
   - Refactor multi-purpose views by extracting focused subviews (e.g., header, gesture zones, overlays).

2. **DRY (Don't Repeat Yourself) & Single Source of Truth**
   - Centralize duplicate logic into shared extensions or reusable components (e.g., `EdgeBrightnessGestureZone`, `baseFilenameWithoutExtensions`).
   - Use single-source managers (e.g., `ReaderProgressTracker.shared`) for app-wide state rather than scattered local properties.

3. **No Magic Numbers or Cryptic Names**
   - Store layout constants, gesture thresholds, and animation metrics in named enum spaces (e.g., `ReaderLayoutConstants`).
   - Use intent-revealing names (`stampCurrentPageLink()`) instead of vague abbreviations (`s()`, `idx`).

4. **Comments Explain "Why", Code Explains "What"**
   - Reserve comments for non-obvious architecture rationale, OS workarounds, or performance decisions. Avoid redundant comments that restate self-explanatory code.

5. **Resource Cleanliness & Memory Safety**
   - Guarantee teardown of notification observers (`dismantleUIView`, `deinit`) and cancel background tasks to prevent memory leaks and dangling listeners.

## Engineering Standards
- Always apply **best-in-class iOS/iPadOS development practices** (Swift 6 concurrency, Actor isolation, SwiftData, Metal/CoreAnimation graphics, ProMotion, PencilKit, WebKit, PDFKit, and HapticEngine).
- Serve as the **last line of defense** to ensure a superior, premium, and flawless product experience for our customers.
