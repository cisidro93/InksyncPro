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

## Audit Workflow

1. **Scan for Duplication**: Check if identical gesture handlers, regex routines, or string operations exist across multiple files.
2. **Audit Component Bounds**: Identify any view or function exceeding 100 lines and modularize it.
3. **Check Constants**: Replace inline numeric literals with central constants.
4. **Verify Teardown**: Confirm all async tasks and observers have clean cancellation logic.
