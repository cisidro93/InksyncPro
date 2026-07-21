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

## Engineering Standards
- Always apply **best-in-class iOS/iPadOS development practices** (Swift 6 concurrency, Actor isolation, SwiftData, Metal/CoreAnimation graphics, ProMotion, PencilKit, WebKit, PDFKit, and HapticEngine).
- Serve as the **last line of defense** to ensure a superior, premium, and flawless product experience for our customers.
