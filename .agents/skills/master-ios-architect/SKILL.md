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
1. **PDFKit & WebKit Optimization:**
   - Enable Smart Margin Cropping by dynamically setting `page.setBounds(cropRect, for: .cropBox)` and scaling `scaleFactor` to fill 100% of the screen width.
   - Prevent view destruction during crop toggles by keeping `PDFKitRepresentedView` mounted.
2. **PencilKit & Metal Graphics:**
   - Layer PencilKit canvas views (`PKCanvasView`) transparently over active pages without blocking reader tap gestures.
   - Use zero-latency PPL Metal rendering for comic archives and high-resolution document pages.
3. **EPUB WebKit Master Engine:**
   - Symmetrically mount primary `WKWebView` elements to span full screen width across dual-page medians.
   - Pre-render 0ms column snapshots for 3D page curl transitions.

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

---

## 2. Developer Action Checklist

Whenever authoring, refactoring, or reviewing code for InksyncPro:
- [ ] Has the error or bug been justified by empirical log/crash evidence?
- [ ] Is state managed through a single source of truth without duplicated properties?
- [ ] Are view controller array bounds dynamically aligned to prevent UIKit exceptions?
- [ ] Does the UI look spectacular with modern typography, glassmorphic containers, and Haptic feedback?
- [ ] Are all notification observers cleaned up in `dismantleUIView` to prevent memory leaks?
- [ ] Have all background tasks been offloaded from `@MainActor` to avoid frame drops?
