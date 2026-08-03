# Agent Guidelines & Workflow Rules

## Master iOS & Systems Architecture Protocol (Educator Synthesis)

Whenever conducting code reviews, bug fixes, feature additions, or architectural refactoring across InksyncPro:

### 1. Point-Free Swift 6 State Architecture
- Enforce single source of truth state management (`ReaderProgressTracker.shared`, `EBookPreferences.shared`).
- Maintain strict `@MainActor` and `Actor` isolation with `Sendable` value semantics to eliminate race conditions.
- Prevent invalid intermediate state transitions (e.g. `safeSetViewControllers` in `EBookPageCurlReader`).

### 2. Kavsoft UI/UX & ProMotion 120Hz Excellence
- Deliver spectacular, modern aesthetics using glassmorphic containers (`.ultraThinMaterial`, `Capsule()`, `RoundedRectangle`), curated dark/sepia/light color systems, and Google Fonts typography.
- Guarantee zero UI jank, 120Hz ProMotion touch responsiveness, custom gesture prioritization, and rich tactile `HapticEngine` feedback.

### 3. Paul Hudson Native Framework Mastery
- Deep integration of Apple native APIs: PDFKit (Smart Margin Cropping & Fit-Width expansion), WebKit (Full-bleed dual-page median layout), PencilKit (Non-blocking drawing layers), and Metal graphics.
- Fail-safe state restoration across orientation switches, app backgrounding, and memory pressure.

### 4. ThePrimeagen Low-Level Performance & Zero-Leak Memory Safety
- **Empirical Diagnostics First:** Always read full `.ips` crash logs and stack traces before diagnosing or modifying code.
- **Resource Cleanliness:** Guarantee complete teardown of notification observers (`dismantleUIView`, `deinit`) and background tasks to prevent memory leaks and dangling listeners.
- **Zero Main-Thread Blocking:** Offload document parsing, image extraction, and crop calculations to background `Task.detached` threads.

### 5. Visual Kernel Mental Models & Study Systems
- Provide immediate visual feedback for all reader modes (Smart Crop, Pencil Ink, Dual Page).
- Support deep study workflows: Cornell 3-Zone note paper, Zettelkasten auto-linked nodes (`ZettelkastenAutoLinker`), and Executive Summary HUD layers.

---

## Three-Developer Review & Defense Protocol

Whenever conducting code reviews, bug fixes, or feature additions:

1. **Phase 1: Senior Backend Developer Review**
   - Deep line-by-line audit of data models, serialization schemas, thread concurrency, memory allocation, caching actors, background task safety, and security-scoped file system/sandbox handles.
   - Enforce zero memory leaks, zero race conditions, zero data corruption, and robust error handling.

2. **Phase 2: Senior Frontend / UI / UX Developer Review**
   - Deep audit of SwiftUI/UIKit view hierarchies, ProMotion 120Hz performance, gesture recognizers, visual polish (frosted-glass glassmorphism, light/dark/sepia themes, ProMotion animations), haptic feedback, and user interaction flow.
   - Enforce zero UI jank, zero gesture conflicts, clean responsiveness across iOS/iPadOS screen sizes, and delightful micro-interactions.

3. **Phase 3: Senior Full-Stack Developer Harmonization Review**
   - End-to-end integration audit checking the harmony between backend actors/models and frontend views.
   - Validate state synchronization, progress tracking (`ReaderProgressTracker`), iCloud sync (`NSUbiquitousKeyValueStore`), settings persistence (`EBookPreferences`), and cross-module routing.

---

## Clean Code Handbook Protocol

1. **Single Responsibility Principle (SRP):** Keep components short and focused on a single task.
2. **DRY & Single Source of Truth:** Centralize duplicate logic and state managers.
3. **No Magic Numbers or Cryptic Names:** Store metrics in named enum spaces with intent-revealing names.
4. **Comments Explain "Why":** Reserve comments for non-obvious architecture rationale or OS workarounds.
5. **Resource Cleanliness:** Guarantee teardown of observers and background tasks.
