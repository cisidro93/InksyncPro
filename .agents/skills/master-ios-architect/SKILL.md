---
name: master-ios-architect
description: Master iOS & Systems Architecture Protocol for InksyncPro synthesized from industry-leading educators (Point-Free Swift Architecture, Kavsoft ProMotion UI/UX, Paul Hudson Native Frameworks, ThePrimeagen Low-Level Performance, and Visual Kernel Mental Models).
---

# Master iOS & Systems Architecture Protocol for InksyncPro

Synthesized from world-class software engineering educators:

- **Point-Free (Brandon Williams & Stephen Celis):** Swift 6 Concurrency, Single-Source State Machines & Unidirectional Data Flow.
- **Kavsoft (UI/UX Engineering):** Glassmorphism, 120Hz ProMotion Fluid Animations, Custom Gestures & Micro-Interactions.
- **Paul Hudson (Hacking with Swift):** Native Framework Mastery (PDFKit, WebKit, PencilKit, Metal Graphics & SwiftData).
- **ThePrimeagen (Low-Level Systems):** Empirical Crash Diagnostics, Zero-Leak Memory Safety & Performance Profiling.
- **Visual Kernel (Mental Models):** Visual Feedback, Concept Scoping, and Progressive Knowledge Management.

---

## 1. Core Architectural Pillars

### Pillar 1: Point-Free Swift 6 State Architecture

1. **Single Source of Truth:**
   - Never mirror or duplicate state across views. Maintain authoritative state managers (e.g., `ReaderProgressTracker.shared`, `EBookPreferences.shared`).
   - Use `@MainActor` isolation for UI-bound state and `Actor` isolation for asynchronous background tasks.
2. **Value vs. Reference Safety:**
   - Prefer immutable Swift `struct`s for domain models (`ReadingProgress`, `ConvertedPDF`, `Annotation`).
   - Use reference types (`class`, `actor`) strictly for stateful controllers and background services, ensuring all cross-boundary types conform to `Sendable`.
3. **Defensive State Transitions:**
   - Ensure UI state transitions cannot trigger inconsistent intermediate states (e.g., `safeSetViewControllers` in `UIPageViewController` to guarantee array length alignment with `spineLocation`).

### Pillar 2: Kavsoft UI/UX & ProMotion Polish

1. **Aesthetic Excellence:**
   - Use rich, harmonious color palettes (e.g. `Color.inkBackground`, `Color.inkGreen`, `Color.inkOrange`).
   - Implement frosted-glass glassmorphism (`.ultraThinMaterial`, `Capsule()`, `RoundedRectangle(cornerRadius: 16)`).
2. **Fluid Micro-Interactions & ProMotion (120Hz):**
   - Ensure all gesture recognizers, slider scrubbers, and page turn animations respond immediately without UI jank.
   - Use spring physics (`.spring(response: 0.3, dampingFraction: 0.75)`) and HapticEngine feedback (`HapticEngine.light()`, `HapticEngine.medium()`).
3. **Responsive iPadOS Multi-Column Grids:**
   - Adapt UI layouts seamlessly between iPhone portrait/landscape and iPad dual-page / multi-column presentation.

### Pillar 3: Paul Hudson Native Framework Integration

1. **PDFKit Master Architecture & Inking Lifecycle (iOS 16+):**
   - **Early Provider Binding**: Always assign `pdfView.pageOverlayViewProvider = provider` in `makeUIView` *prior* to `pdfView.document = document`. PDFKit instantiates overlays on document load; late binding skips initial pages.
   - **Scroll View Gesture Isolation**: Whenever inking is active, configure `pdfView.scrollView.panGestureRecognizer.minimumNumberOfTouches = 2`. This guarantees 1-finger Apple Pencil and touch drawing strokes are never stolen or cancelled by scroll gestures, while 2-finger pans navigate the canvas.
   - **Markup Mode Suppression**: Set `pdfView.isInMarkupMode = true` during drawing to disable text loupe capture. Suppress page-turn tap recognizers (`tapGesture.isEnabled = !isMarkupActive`) so rapid pen stippling and dotting never flip pages.
   - **Device-Idiom Inking Gating**: Guarantee finger drawing on iPhone (`!isPad`), and allow finger drawing on iPad unless "Apple Pencil Drawing Only" is explicitly enabled in Settings.
   - **Smart Margin Cropping**: Dynamically set `page.setBounds(cropRect, for: .cropBox)` and scale `scaleFactor` to fill 100% of the screen width without thrashing view hierarchies.
2. **Text Highlighting & Selection Standard (Kindle / Apple Books Parity):**
   - **Zero Auto-Commit Highlights in `selectionChanged`**: Selection notifications must purely update the selection snapshot to drive HUD presentation. Never place asynchronous debounce tasks in `selectionChanged` that unilaterally stamp highlights.
   - **Dual Selection Pathways**: Fast-path dedicated stylus highlighter commits on `.ended` with `defaultHighlightColor`; standard reader selection displays the floating HUD (Color palette, Copy, Note, Translate, Speak).
   - **Annotation Hit-Testing & Mutation**: Tapping existing highlights must hit-test the annotation, display the HUD with its active color, and allow color changes or deletion with zero duplicate highlight stamps.
   - **Per-Line Quad Polygons**: Reconstruct stored highlights using `selectionsByLine()` for saved text, generating tight per-line quads via `PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)` so multi-line text never degenerates into a solid block.
3. **EPUB WebKit Master Engine & Zero-Drift Reflow:**
   - **Invariant Viewport Model**: Enforce `position: relative !important; width: 100vw !important; height: 100vh !important; box-sizing: border-box !important;`.
   - **Mathematical Zero-Drift Column Stride**: Calculate $\text{colWidth} = (\text{renderWidth} / \text{cols}) - 2m$ and $\text{gap} = 2m$, guaranteeing $\text{colWidth} + \text{gap} = \text{pageWidth}$ so every page turn lands with pixel-perfect margin alignment.
   - **Structural Layout Preservation**: Avoid destructive global CSS resets (`display: block !important; position: static !important;`). Protect page breaks with `break-inside: avoid !important` on images, figures, tables, and code blocks, and `break-after: avoid !important` on headings.
   - **Failsafe Snapshot Lifecycle**: Retain the primary webview during `willTransitionTo` in `UIPageViewController` to eliminate blank page flashes during page curls.
   - **Wrapper Idempotency**: Guard `wrapHTMLBodyWithViewport` with `if html.contains("id=\"inksync-viewport\"") { return html }`.
4. **PencilKit & Metal Graphics:**
   - Layer transparent `PKCanvasView` overlays with dynamic `contentScaleFactor` matching zoom level for crisp 120Hz ProMotion vector lines.
   - Use zero-latency PPL Metal rendering for comic archives and high-resolution document pages.

### Pillar 4: ThePrimeagen Low-Level Performance & Zero-Leak Memory Safety

1. **Empirical Log & Traceback First:**
   - Always read full, un-truncated `.ips` crash logs and stack traces before forming a diagnostic hypothesis.
   - Trace exact faulting frames (`_validatedViewControllersForTransitionWithViewControllers:animated:`, `loadChapterAndPresent`) back to root causes.
2. **Zero Memory Leaks & Resource Safety:**
   - Explicitly dismantle notification observers (`NotificationCenter.default.removeObserver`) in `dismantleUIView`.
   - Cancel dangling background tasks upon view disappearance (`.onDisappear`).
3. **Zero Main-Thread Blocking:**
   - Offload heavy tasks (PDF rendering, image sampling, archive extraction, smart crop calculation) to background tasks (`Task.detached(priority: .userInitiated)`).

### Pillar 5: Visual Kernel Knowledge Management

1. **Visual State Clarity:**
   - Provide clear, immediate visual indicators for active states (Smart Crop active, Pencil Ink mode enabled, Dual Page active).
2. **Zettelkasten & Study Notebook:**
   - Maintain auto-linked knowledge nodes (`ZettelkastenAutoLinker`), Progressive Summarization HUDs, and Cornell 3-Zone study notes for deep reading comprehension.

### Pillar 6: Software Design Lifecycle & Observability (Banerjee Protocol)

1. **Structured 5-Phase Design Protocol Before Implementation:**
   - **Phase 1: Problem Definition & Scope Boundaries**: Explicitly define what problem is being solved, what is strictly *in scope*, what is *out of scope*, and list core assumptions before writing code.
   - **Phase 2: Use-Case & Permutation Mapping**: Enumerate interactions across valid, invalid, missing, and boundary states (e.g. empty files, corrupted archives, network drops, orientation shifts).
   - **Phase 3: Behavioral Requirements Contract**: Define exact behavioral expectations, error handling policies, and API capabilities.
   - **Phase 4: Modular Architecture & Telemetry**: Design loosely coupled components with deep interfaces (Ousterhout). Integrate telemetry (`os.Logger` subsystems) early as an architectural feedback loop.
   - **Phase 5: Detailed Data Structures & Component Tests**: Model domain data using immutable value types (`Sendable` structs) and verify components with focused tests.
2. **Hot-Path vs. Cold-Path Architecture (Muratori vs. Dijkstra/Ousterhout):**
   - **Hot Rendering Paths (Muratori Caution)**: Avoid virtual dispatch, dynamic protocol casting, or heap thrashing inside 120Hz rendering loops, Metal shaders, or byte-level image processing. Keep hot loops direct and cache-friendly.
   - **System & Service Boundaries (Dijkstra/Ousterhout Depth)**: Use expressive protocols and deep modules at architecture, state, and service boundaries to keep cognitive load minimal and eliminate comprehension debt.
3. **Telemetry & Unified Logging First:**
   - Instrument critical engines (e.g. `ComicParser`, `PDFCacheManager`, `ReaderProgressTracker`) with structured `os.Logger(subsystem:category:)`.
   - Never use blind `print()` statements for diagnostic tracking in production services.

### Pillar 7: NeoFlow Studio & Smart Tiers Architecture

1. **Coordinate Space Invariants (`BooxCoordinateSpace`):**
   - PDFKit space: `(0,0)` is bottom-left, Y increases upward.
   - UIKit / Image space: `(0,0)` is top-left, Y increases downward.
   - All reader navigation (`PDFTierQuadrant`, `BooxSectionBlock`) MUST normalize to `space: .pdf` before programmatic alignment in `ProPDFReaderEngine`.
2. **Golden Rule Column Fit Invariant:**
   - **In Portrait**: Strict column-fit ensures every line of text spans edge-to-edge with zero horizontal pan. Width must NEVER exceed safe screen width.
   - **In Landscape**: Clamp scale factor comfortably to fit without excessive vertical truncation.
3. **Connection Redundancy Overlap Buffers:**
   - Add a 10%–15% horizontal and vertical buffer between adjacent blocks (`redundantRect`) to eliminate cutting text or speech bubbles in half across page strides.
4. **Draggable Partition Lines & 8-Point Quadrant Resize:**
   - All partition lines and margin handles MUST provide $\ge 44\text{pt}$ touch corridors.
   - Selected quadrants support 8-point interactive resize handles (4 corners, 4 edges) saved via `customBlockOverrides: [Int: CGRect]`.
5. **Full-Screen Tap-to-Preview Reader Simulation:**
   - Provide an interactive, full-screen reader preview with Left/Right step-through tap zones, allowing the user to verify tier framing before saving changes.

### Pillar 8: Unified File Sharing & Ingestion Pipeline

1. **Queue-Based Concurrency Staging (`SharedImportCoordinator`):**
   - When `coordinateImport` is invoked while an ingestion is already active (`isIngesting == true`), incoming target filenames MUST be appended to `pendingTargetFilenames` rather than dropped.
   - Drain pending queues in an automatic follow-up pass upon ingestion completion.
2. **Resilient File Settlement Loop:**
   - Always verify that incoming files from AirDrop or external app handoffs have stabilized non-zero file sizes using an asynchronous retry loop (up to 10 attempts, 200ms apart).
3. **AppRouter Presentation Idempotency:**
   - In `AppRouter.presentFullScreen(_:)`, verify if `activeFullScreen` is already presenting `.read` for the same document ID or path; if so, return immediately to eliminate presentation dismissal flashes.
   - Use a `0.35s` delay when transitioning between different screens to match UIKit full-screen modal cover dismissal animation.
4. **Sandbox Hygiene (`Documents/Inbox`):**
   - Clean up temporary copies in `Documents/Inbox/` after copying to `InksyncVault/Inbox` to prevent container bloat.

---

## 2. Developer Action Checklist

Whenever authoring, refactoring, or reviewing code for InksyncPro:

- [ ] **Design Lifecycle**: Has the problem, scope, use-case matrix, and failure modes been defined before coding?
- [ ] **Empirical Diagnostics**: Has any bug or crash been verified against real logs, traces, or diagnostic telemetry?
- [ ] **State Single Source of Truth**: Is state managed through an authoritative actor/manager without duplicated mirrors?
- [ ] **Cognitive Load & Deep Modules**: Are complex systems behind simple semantic protocols to prevent comprehension debt?
- [ ] **Hot vs Cold Separation**: Are high-frequency rendering/byte paths kept direct and performance-critical while services are modular?
- [ ] **Touch Ergonomics & Apple HIG**: Do all interactive handles, partition lines, and buttons provide $\ge 44\text{pt}$ invisible touch hit areas?
- [ ] **NeoFlow & Smart Tiers**: Does column fitting follow the Golden Rule, and do custom overrides preserve PDFKit coordinate invariants?
- [ ] **File Sharing & Ingestion**: Are concurrent imports queued without dropping, files verified settled, and temporary sandbox copies cleaned up?
- [ ] **Presentation Idempotency**: Does `AppRouter` guard against duplicate presentation cycles and match UIKit dismissal animation timings?
- [ ] **Resource Safety**: Are notification observers dismantled and async tasks explicitly cancelled on view teardown?
- [ ] **Telemetry**: Are key lifecycle and error events logged with structured `os.Logger`?

