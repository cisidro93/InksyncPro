---
name: neoflow-smart-tiers
description: NeoFlow Studio & Smart Tiers Architecture Protocol for InksyncPro. Guides the creation, calculation, editing, and execution of M×N matrix grids, traversal sequences, coordinate transformations, custom per-quadrant resize overrides, and the live Tap-to-Preview reader simulator.
---

# NeoFlow Studio & Smart Tiers Architecture Protocol

A comprehensive systems guide for InksyncPro's proprietary panel reading, multi-column tier navigation, and visual study workspace.

---

## 1. Core Mathematical Model & Presets

NeoFlow Studio partitions document pages into sequential reading blocks (`BooxSectionBlock`) using an $M \times N$ matrix grid:

$$
\text{Columns} = N \in \{1, 2, 3\}, \quad \text{Rows} = M \in \{1, 2, 3\}
$$

### Supported Grid Presets (`BooxGridPreset`)
- **`grid1x1`**: Full single-page view without subdivision.
- **`grid1x2`**: Single column split into Top and Bottom halves (academic double-height slides).
- **`grid1x3`**: Single column split into 3 vertical tiers (standard academic papers / 3-panel strips).
- **`grid2x1`**: 2 columns side-by-side, single row (two-column text reflow).
- **`grid2x2`**: Classic 4-quadrant layout (comic/manga panels, 4-up diagrams).
- **`grid2x3`**: 2 columns × 3 rows (6-panel dense technical layout).
- **`grid3x2`**: 3 columns × 2 rows (wide diagrams, 6-block flow).
- **`grid3x3`**: 3 columns × 3 rows (9-block fine inspection).
- **`half1_2` / `half2_1`**: Dynamic asymmetric two-tier splits.

### Traversal Flow Sequences (`BooxTraversalFlow`)
1. **`zFlow` (Western Left-to-Right)**:
   $$\text{Row } 0: (0,0) \to (0,1) \to \dots \to (0, N-1) \implies \text{Row } 1: (1,0) \to (1,1) \dots$$
2. **`reverseZ` (Manga Right-to-Left)**:
   $$\text{Row } 0: (0, N-1) \to (0, N-2) \to \dots \to (0,0) \implies \text{Row } 1: (1, N-1) \dots$$
3. **`nFlow` (Academic Columnar Top-to-Bottom)**:
   $$\text{Col } 0: (0,0) \to (1,0) \to \dots \to (M-1,0) \implies \text{Col } 1: (0,1) \dots$$
4. **`reverseN` (Japanese Columnar Right-to-Left Top-to-Bottom)**:
   $$\text{Col } N-1: (0, N-1) \to (1, N-1) \dots \implies \text{Col } N-2: (0, N-2) \dots$$

---

## 2. Invariant Coordinate Spaces & Golden Rule

### Coordinate Space Invariants (`BooxCoordinateSpace`)
- **UIKit / Image Space (`space: .image`)**:
  - Origin `(0, 0)` is **Top-Left**.
  - X increases rightward, Y increases **downward**.
  - Used by `ComicReaderEngine`, `UIImageView`, and workspace touch interaction.
- **PDFKit Space (`space: .pdf`)**:
  - Origin `(0, 0)` is **Bottom-Left**.
  - X increases rightward, Y increases **upward**.
  - Used by `ProPDFReaderEngine`, `PDFPage.bounds(for: .cropBox)`.
- **The Golden Coordinate Rule**:
  - Always convert normalized coordinates via `rect.flippedForPDF(space:)` when transferring between UI workspace gestures and PDFKit display rects.
  - Invert row order in PDF coordinates: Row 0 (Top) maps to $Y = 1.0 - \text{height}$, while Row $M-1$ (Bottom) maps to $Y = 0.0$.

### Golden Rule Column Fit Invariant
- **In Portrait**:
  - Scale factor MUST fit the target column or quadrant strictly edge-to-edge across screen width:
    $$\text{scale} = \frac{\text{viewportWidth}}{\text{targetRect.width}}$$
  - **Zero Horizontal Pan**: The viewport must never require horizontal scrolling to read a line of text in portrait mode.
- **In Landscape**:
  - Scale factor is clamped to fit the height comfortably:
    $$\text{scale} = \min\left(\frac{\text{viewportHeight}}{\text{targetRect.height}}, \text{fitScale} \times 3.0\right)$$

---

## 3. Connection Redundancy (Overlap Buffers)

To prevent words, sentences, or speech bubbles from being truncated at block boundaries, `BooxSectionFlowEngine` calculates an expanded `redundantRect`:

$$
\text{redundantRect} = \text{rect.insetBy}(dx: -\Delta_x, dy: -\Delta_y)
$$

- Default overlap ratio: 10% to 15% of block width/height.
- Clamped within the overall cropped page margin boundaries $[0, 1]$.

---

## 4. Interactive Workspace Ergonomics & Touch Guidelines

### Apple HIG Touch Targets ($\ge 44\text{pt}$)
- All interactive margin crop handles, partition divider lines, and corner handles MUST provide an invisible touch target of at least $44\times 44\text{ pt}$:
  ```swift
  Color.clear
      .frame(width: max(44, visibleWidth), height: max(44, visibleHeight))
      .contentShape(Rectangle())
  ```
- Draggable partition lines must loop across all columns and rows (`horizontalSplitRatios` and column splits) for all 2-tier and 3-tier presets.

### Start-Relative Drag Math
- In `DragGesture.onChanged`, capture the initial configuration value on gesture start.
- Compute new values strictly as:
  $$\text{newValue} = \text{clamp}(\text{startValue} + \text{translationDelta}, \text{min}, \text{max})$$
- Never apply incremental translation recursively every frame, which causes jitter and runaway acceleration.

### Gesture Layer Z-Index Hierarchy
- **Layer 1 (Bottom)**: Background page image / rendered PDF page.
- **Layer 2 (Middle)**: Sequence badge overlay & block selection hitboxes.
- **Layer 3 (Top)**: Draggable partition divider lines and margin handles (`.zIndex(100)`).
- **Layer 4 (Overlay)**: 8-Point per-quadrant resize handles for the currently selected block (`.zIndex(200)`).

---

## 5. Per-Quadrant Custom Boundary Overrides (`customBlockOverrides`)

When an individual quadrant requires bespoke framing (e.g. an oversized diagram or irregular comic panel):
1. Tapping a quadrant marks it as active (`selectedBlockIndex == block.stepOrder`).
2. The workspace renders **8 interactive handles**:
   - 4 Corners: Top-Left, Top-Right, Bottom-Left, Bottom-Right.
   - 4 Edges: Top, Bottom, Left, Right.
3. Dragging a handle updates `customBlockOverrides[blockIndex] = updatedNormalizedRect`.
4. `BooxSectionFlowEngine` respects custom overrides during block generation while preserving connection redundancy calculations.

---

## 6. Live Tap-to-Preview Reader Simulation

Before committing changes to the active reader engine, the user can tap **"Preview"** in the navigation bar:
- Launches `BooxReaderPreviewView`, a full-screen interactive reader simulator.
- Displays the actual rendered page cropped and scaled to viewport using the Golden Rule Column Fit.
- Features **Left (Previous)** and **Right (Next)** tap zones to step through Tier $1 \to 2 \to \dots \to K$.
- Displays a floating badge HUD showing the active step (`Tier 2/4 · Col 1 Bottom`) and traversal arrow.
- Tapping **"Exit Preview"** returns to the Studio editor; tapping **"Save & Read"** applies the configuration immediately and launches the reader.
