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

- **PDFKit Inking & Page Overlay Lifecycle (iOS 16+)**:
  - Assign `pdfView.pageOverlayViewProvider` in `makeUIView` **before** assigning `pdfView.document = document` so PDFKit queries overlays on initial layout for page 0.
  - Enable `pdfView.isInMarkupMode = true` whenever inking is active to suppress internal text selection loupes.
  - **Scroll View Gesture Isolation**: Configure `pdfView.scrollView.panGestureRecognizer.minimumNumberOfTouches = isCanvasMarkupActive ? 2 : 1` so 1-finger pencil and touch strokes draw with 100% fidelity without being cancelled by scroll gestures, while 2-finger gestures smoothly pan/zoom.
  - Disable reader tap gesture recognizers (`tapGesture.isEnabled = !isCanvasMarkupActive`) during markup so stippling or dotting `i` never turns pages.
  - Idiom-safe drawing policy: `allowFinger = !isPad || !pencilOnlyDrawingSetting || isEraser` so iPhones always permit finger inking.
- **Text Highlighting & Selection Standard (Kindle / Apple Books Parity)**:
  - Never auto-commit highlights inside `selectionChanged`. Selection must purely update state to present the floating HUD (Color palette, Copy, Note, Speak).
  - Dedicated stylus highlighter mode (`isHighlighterMode`) commits instantly on gesture `.ended` with zero UI latency and clears selection.
  - Tapping existing highlights must hit-test the annotation, present the HUD with active color, and allow color changes or deletion with zero duplicate highlight stamps.
  - Multi-line highlights must resolve `selectionsByLine()` for stored text and compute line-by-line quad points relative to the union box (`PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)`), preventing solid block degeneration on reload.
- **WebKit Multi-Column EPUB Reflow Standard**:
  - Enforce invariant full-bleed viewport: `position: relative !important; width: 100vw !important; height: 100vh !important; box-sizing: border-box !important;`.
  - Maintain the mathematical zero-drift column stride: $\text{colWidth} = (\text{renderWidth} / \text{cols}) - 2m$, $\text{gap} = 2m$, ensuring $\text{colWidth} + \text{gap} = \text{pageWidth}$ so every page turn lands with pixel-perfect margin alignment.
  - Avoid destructive global CSS overrides (`display: block !important; position: static !important; float: none !important;` on divs/sections).
  - Protect page breaks with `break-inside: avoid !important` on images, figures, tables, and code blocks, and `break-after: avoid !important` on headings.
  - Retain the primary webview during `willTransitionTo` in `UIPageViewController` to prevent blank page flashes during page curls.
  - Guard `wrapHTMLBodyWithViewport` against duplicate nested `#inksync-viewport` wrapping.
- **PencilKit & Metal Graphics**: Non-blocking drawing layers, 120Hz touch responsiveness, and Metal GPU shaders.
- **Fail-Safe State Restoration**: Invariant state restoration across orientation switches, app backgrounding, and memory pressure. Synchronously seed initial cache arrays in singleton initializers (`rebuildVisiblePDFs()`) to eliminate cold-launch empty states.

### 4. ThePrimeagen Low-Level Performance & Zero-Leak Memory Safety

- **Empirical Diagnostics First:** Always read full `.ips` crash logs and stack traces before diagnosing or modifying code.
- **Resource Cleanliness:** Guarantee complete teardown of notification observers (`dismantleUIView`, `deinit`) and background tasks to prevent memory leaks and dangling listeners.
- **Zero Main-Thread Blocking:** Offload document parsing, image extraction, and crop calculations to background `Task.detached` threads.

### 5. Visual Kernel Mental Models & Study Systems

- Provide immediate visual feedback for all reader modes (Smart Crop, Pencil Ink, Dual Page).
- Support deep study workflows: Cornell 3-Zone note paper, Zettelkasten auto-linked nodes (`ZettelkastenAutoLinker`), and Executive Summary HUD layers.

### 6. Software Design Lifecycle & Observability (Banerjee Protocol)

- **5-Phase Pre-Implementation Discipline**: Before coding, systematically define:
  1. *Problem Statement & Scope Boundaries* (in-scope, out-of-scope, core assumptions).
  2. *Use-Case & Permutation Matrix* (valid, invalid/malformed, missing inputs).
  3. *Behavioral Requirements Contract* (explicit system behaviors & invariants).
  4. *Modular Architecture & Telemetry* (loose coupling, deep modules, `os.Logger` subsystems).
  5. *Detailed Specs & Component Tests* (immutable `Sendable` value types, test-driven validation).
- **Hot-Path vs. Cold-Path Separation (Muratori vs. Dijkstra/Ousterhout)**:
  - Keep 120Hz hot rendering paths (Metal shaders, byte-level bitmap manipulation) direct and non-dispatching.
  - Keep service, state, and business boundaries cleanly protocol-abstracted to maximize cognitive compression.

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

4. **Phase 4: Skeptical Verification Protocol (Zero-Assumption Audit)**
   - **Never Assume Integration**: Never claim a feature, tool, or UI control is fully functional just because a component file, state property, or action closure exists.
   - **Line-by-Line Callback Verification**: For every toolbar button, menu option, or gesture handler, explicitly trace the call chain: UI Button → Action Callback → `@State` Boolean Toggle → Modal Sheet / Feature Engine.
   - **Sheet & Action Binding Audit**: Verify that every modal sheet (`.sheet`, `.popover`, `.alert`) has a working presenter boolean and non-nil content view before declaring completion.

---

## Clean Code Handbook Protocol

1. **Single Responsibility Principle (SRP):** Keep components short and focused on a single task.
2. **DRY & Single Source of Truth:** Centralize duplicate logic and state managers.
3. **No Magic Numbers or Cryptic Names:** Store metrics in named enum spaces with intent-revealing names.
4. **Comments Explain "Why":** Reserve comments for non-obvious architecture rationale or OS workarounds.
5. **Resource Cleanliness:** Guarantee teardown of observers and background tasks.
6. **Zero Comprehension Debt & Cognitive Compression (AI Economics):** Lines of code are cheap to generate with AI, but human and agent comprehension is the bottleneck. Use clean protocols and deep modules (Ousterhout) as cognitive compression algorithms. Reject blind copy-pasting and AI-induced code churn.
7. **Fault Isolation & Typed Error Hierarchies:** Isolate engine errors so secondary failures never crash the active reader session. Define typed domain errors conforming to `LocalizedError` and `Sendable`.

---

## Integration & Feature Defense Matrix Protocol

To prevent key functions or safeguards from being overlooked or improperly integrated:

1. **Instantiation & Routing Audit**:
   - Trace the complete invocation chain from view entry (`UnifiedReaderView`, `ReaderView`) down to child engine components (`DocumentReaderEngine`, `EBookPageCurlReader`) before editing code.
   - Verify that conditional branches (e.g. `.pdf` vs `.epub` vs `.cbz`) explicitly route to the intended vector or paged engines.

2. **Viewport & Zoom Safeguard Checklist**:
   - **Scale Clamping**: `minScaleFactor` MUST equal `fitScale` (never < 0.5) and `maxScaleFactor` MUST be capped at `fitScale * 3.5`.
   - **Gesture Isolation**: Disambiguate single-tap, double-tap, and pan gestures using `.require(toFail:)` and `.cancelsTouchesInView = false`.
   - **In-Memory Loading**: Never write and immediately delete temporary disk files during asynchronous WKWebView or PDFKit loading. Always use in-memory buffers or persistent directory handles.

3. **Multi-State Edge-Case Verification**:
   - Verify feature behavior across 4 primary runtime states: (1) Initial Load, (2) Zoomed State (1.0x - 3.5x), (3) Orientation Rotation (Portrait ↔ Landscape), and (4) Low Memory Purge.
