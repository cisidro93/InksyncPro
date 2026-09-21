---
name: clean-code-handbook
description: Enforces Clean Code Handbook standards (Single Responsibility, DRY, Single Source of Truth, Magic Number Elimination, Self-Documenting Naming, and Resource Safety) across Swift, SwiftUI, and iOS architecture. Use when reviewing code quality, refactoring complex components, or establishing architectural standards.
---

# Clean Code Handbook Skill

This skill provides step-by-step instructions for conducting **Clean Code Audits**, **DRY Refactoring**, and **Architectural Quality Enforcement** based on the Clean Code Handbook principles.

## Core Rules & Principles

### 1. Single Responsibility Principle (SRP)

- **Rule**: Every class, struct, actor, function, and SwiftUI view component MUST have a single, well-defined responsibility.
- **Action**:
  - Keep functions under 30-40 lines wherever possible.
  - Break bloated SwiftUI views (`body` > 100 lines) into focused subviews or private view builders.
  - Separate UI layout logic from data parsing and persistence.

### 2. Don't Repeat Yourself (DRY) & Single Source of Truth

- **Rule**: Never duplicate business logic, layout metrics, string manipulation loops, or state structures across multiple files.
- **Action**:
  - Extract repeated inline code (e.g., drag gestures, image extension checks, string filename trimming) into shared extensions or reusable components.
  - Maintain a single authoritative manager (e.g., `ReaderProgressTracker.shared`, `AppSettingsManager.shared`) for global state.

### 3. Eliminate Magic Numbers & Cryptic Abbreviations

- **Rule**: No unexplained hardcoded numbers or abbreviated variable names.
- **Action**:
  - Store layout bounds, animation spring values, and debounce thresholds in named constant enums (e.g., `ReaderLayoutConstants`).
  - Use intent-revealing parameter names (`activeReaderPageIndex`) instead of vague placeholders (`idx`, `p`, `val`).

### 4. Self-Documenting Code & Intent-Focused Comments

- **Rule**: Code must be expressive enough to explain *what* it does through naming and clean structure.
- **Action**:
  - Only write comments to explain *why* a complex algorithm, workaround, or low-level optimization was implemented.
  - Remove redundant syntax comments (e.g., `// loop over array`).

### 5. Resource Cleanliness & Memory Safety

- **Rule**: Zero dangling listeners, zero uncancelled background tasks, and zero memory leaks.
- **Action**:
  - Always implement observer teardown (`dismantleUIView`, `deinit`) when adding NotificationCenter listeners.
  - Explicitly cancel `Task` instances in `.onDisappear` or before reassigning debounced operations.

### 6. Prevent Comprehension Debt & Eliminate AI-Induced Churn (AI Economics)

- **Rule**: Code is written once but read dozens of times. AI makes lines of code free to produce, but human and agent comprehension remains the hard bottleneck.
- **Action**:
  - **Protocols as Cognitive Compression**: Use protocols (`DocumentReaderEngine`, `ZettelkastenLinkEngine`, `CacheRegistryProtocol`) to create semantic boundaries. A clean interface allows developers to reason about *what* code does in 1 cognitive chunk instead of 6 syntax-heavy implementation chunks.
  - **Deep Modules (Ousterhout)**: Strive for simple public interfaces hiding rich internal implementation. Avoid shallow modules where the interface is as complex as the implementation.
  - **Zero Comprehension Debt**: Reject blind copy-pasting of AI-generated snippets. If code passes tests but is unreadable or introduces silent complexity, it must be refactored before merging.
  - **Two-Phase Abstraction ("Stabilize then Extract")**: Avoid premature abstractions (Metz/Abramov). Build the concrete flow first, let it stabilize, then use AI to mechanically extract clean, uncomplected abstractions.

### 7. Explicit Fault Isolation & Structured Error Hierarchies

- **Rule**: Never swallow errors silently or pass untyped strings as error models.
- **Action**:
  - Define domain-specific error enums conforming to `LocalizedError` and `Sendable`.
  - Isolate component failures so an engine error (e.g., failed thumbnail render or corrupt PDF page) degrades gracefully without tearing down the entire reader session.

### 8. Touch Ergonomics & Apple HIG Compliance (≥ 44pt Hit Corridors)

- **Rule**: Every interactive control, drag handle, divider line, or close button MUST have a touch target of at least 44×44 pt.
- **Action**:
  - Never style a draggable handle with only a 5pt or 7pt physical frame without an invisible touch hit corridor.
  - Wrap slim tactile indicators inside a `ZStack` containing `Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())`.
  - Ensure gesture layers follow strict Z-index ordering so tap containers (e.g. badge selection boxes) never sit on top of and steal drag touches from partition handles.

### 9. Gesture Translation Math & Presentation Idempotency

- **Rule**: Drag gestures must never accumulate cumulative translation runaway; full-screen navigation transitions must be idempotent.
- **Action**:
  - In `DragGesture.onChanged`, capture the initial trim/split/rect on drag start, and calculate offsets strictly as `dragStartValue + translation`. Never apply incremental translation deltas recursively.
  - In `AppRouter.presentFullScreen`, guard against re-presenting an already active document to eliminate unnecessary dismissal cycles and screen flashes.

## Audit Workflow

1. **Scan for Duplication & Code Churn**: Check if identical gesture handlers, regex routines, or string operations exist across multiple files.
2. **Audit Cognitive Load & Component Bounds**: Identify any view or function exceeding reasonable bounds (functions > 40 lines, view bodies > 80 lines) and modularize into deep components.
3. **Verify Semantic Interfaces**: Confirm that complex subsystem interactions are decoupled through clear protocols rather than tightly coupled concrete classes.
4. **Check Constants & Naming**: Replace inline numeric literals with central constants and cryptic names with intent-revealing identifiers.
5. **Verify Touch Ergonomics (≥ 44pt)**: Ensure all handles and interactive partition lines provide a minimum 44pt invisible touch corridor and correct Z-index layering.
6. **Verify Teardown & Fault Safety**: Confirm all async tasks and observers have clean cancellation logic and explicit error handling.

