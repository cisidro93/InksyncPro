import SwiftUI
import PencilKit

// MARK: - Inksync Floating Pen Dock

/// Next-Generation floating glassmorphic pen dock for study-grade PDF and book markup.
/// Synthesizes the tactile ergonomics of reMarkable Paper Pro, the clean non-blocking footprint
/// of Kindle Scribe, and 120Hz ProMotion Apple Pencil Pro tactile micro-interactions.
public struct InksyncPenDockView: View {

    @ObservedObject var inkingState = InksyncInkingState.shared
    @ObservedObject var prefs = EBookPreferences.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone }
    var onUndo: (() -> Void)? = nil
    var onRedo: (() -> Void)? = nil
    var onClearPage: (() -> Void)? = nil
    var onExport: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var showColorPalette: Bool = false
    @State private var showWidthSlider: Bool = false
    @State private var showLayersHUD: Bool = false
    @State private var showClearConfirmation: Bool = false
    @State private var isMinimized: Bool = false
    @GestureState private var dragOffset: CGSize = .zero
    @State private var accumulatedOffset: CGSize = .zero

    public init(
        onUndo: (() -> Void)? = nil,
        onRedo: (() -> Void)? = nil,
        onClearPage: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onClearPage = onClearPage
        self.onExport = onExport
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 8) {
            if !isMinimized {
                if showColorPalette {
                    colorPaletteBar
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .scale(scale: 0.9).combined(with: .opacity)
                        ))
                }

                if showWidthSlider {
                    widthSliderBar
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .scale(scale: 0.9).combined(with: .opacity)
                        ))
                }

                if showLayersHUD {
                    layersHUDCard
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .scale(scale: 0.9).combined(with: .opacity)
                        ))
                }

                mainDockCapsule
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                minimizedPill
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .offset(x: accumulatedOffset.width + dragOffset.width, y: accumulatedOffset.height + dragOffset.height)
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    accumulatedOffset.width += value.translation.width
                    accumulatedOffset.height += value.translation.height
                    HapticEngine.selection()
                }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isMinimized)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showColorPalette)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showWidthSlider)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("InksyncDodgePenDock"))) { _ in
            if !isMinimized {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isMinimized = true
                    inkingState.isDockMinimized = true
                }
                HapticEngine.light()
            }
        }
        .onChange(of: inkingState.isDockMinimized) { _, newVal in
            if isMinimized != newVal {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isMinimized = newVal
                }
            }
        }
        .onAppear {
            isMinimized = inkingState.isDockMinimized
        }
        .alert("Clear Page Markup?", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) {
                onClearPage?()
                HapticEngine.medium()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will erase all ink and highlights on the current page.")
        }
    }

    // MARK: - Main Dock Capsule

    private var mainDockCapsule: some View {
        HStack(spacing: isCompact ? 6 : 10) {
            // Minimize button
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    isMinimized = true
                    inkingState.isDockMinimized = true
                }
                HapticEngine.light()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(isCompact ? 4 : 6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Minimize Toolbar")

            // Kindle-Style Master Tool Mode Switcher
            HStack(spacing: isCompact ? 2 : 4) {
                ForEach(ReaderToolMode.allCases) { mode in
                    let isSelected = inkingState.activeToolMode == mode
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            inkingState.activeToolMode = mode
                        }
                        HapticEngine.selection()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: mode.iconSystemName)
                                .font(.system(size: isCompact ? 12 : 13, weight: isSelected ? .bold : .medium))
                            if isSelected && !isCompact {
                                Text(mode.displayName)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.horizontal, isSelected ? (isCompact ? 8 : 10) : (isCompact ? 5 : 7))
                        .padding(.vertical, isCompact ? 5 : 6)
                        .background(
                            isSelected ? (mode == .textHighlight ? Color.inkOrange : Color.inkGreen) : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.06), in: Capsule())

            // Digital Coloring Studio Toggle Button
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    inkingState.isColoringModeActive.toggle()
                    if inkingState.isColoringModeActive {
                        inkingState.activeToolMode = .write
                        showColorPalette = true
                    }
                }
                HapticEngine.selection()
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 13, weight: inkingState.isColoringModeActive ? .bold : .medium))
                    .foregroundStyle(inkingState.isColoringModeActive ? Color.white : Color.secondary)
                    .padding(isCompact ? 4 : 6)
                    .background(
                        inkingState.isColoringModeActive ? Color.inkOrange : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help("Digital Coloring Studio (Preserve Lineart)")

            // Creative Art & Tracing Lightbox Layers Button
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    showLayersHUD.toggle()
                    if showLayersHUD {
                        showColorPalette = false
                        showWidthSlider = false
                    }
                }
                HapticEngine.selection()
            } label: {
                Image(systemName: "square.3.layers.3d.down.right")
                    .font(.system(size: 13, weight: showLayersHUD ? .bold : .medium))
                    .foregroundStyle(showLayersHUD ? Color.white : Color.secondary)
                    .padding(isCompact ? 4 : 6)
                    .background(
                        showLayersHUD ? Color.inkViolet : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help("Creative Layers & Tracing Lightbox")

            Divider()
                .frame(height: 24)
                .background(Color.secondary.opacity(0.3))

            if inkingState.activeToolMode == .write {
                // Favorite Tool Slots (2 on compact phone, 4 on regular iPad)
                let slotCount = isCompact ? 2 : inkingState.favorites.count
                HStack(spacing: isCompact ? 4 : 6) {
                    ForEach(0..<min(slotCount, inkingState.favorites.count), id: \.self) { index in
                        favoriteSlotButton(at: index)
                    }
                }

                // Tool Type Selector
                Menu {
                    ForEach(InkingToolKind.allCases.filter { $0 != .eraser && $0 != .highlighter }, id: \.self) { kind in
                        Button {
                            inkingState.updateActiveKind(kind)
                            HapticEngine.selection()
                        } label: {
                            Label(kind.displayName, systemImage: kind.iconSystemName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: inkingState.activePreset.kind.iconSystemName)
                            .font(.system(size: 14, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(inkingState.activePreset.color.color)
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, isCompact ? 5 : 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                // Active Color Chip Button
                Button {
                    withAnimation {
                        showColorPalette.toggle()
                        if showColorPalette { showWidthSlider = false }
                    }
                    HapticEngine.selection()
                } label: {
                    Circle()
                        .fill(inkingState.activePreset.color.color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.2), lineWidth: 1.5)
                        )
                        .shadow(color: inkingState.activePreset.color.color.opacity(0.35), radius: 3, y: 1)
                }
                .buttonStyle(.plain)

                // Stroke Width Button
                Button {
                    withAnimation {
                        showWidthSlider.toggle()
                        if showWidthSlider { showColorPalette = false }
                    }
                    HapticEngine.selection()
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.primary)
                            .frame(
                                width: max(3, min(12, inkingState.activePreset.width * 1.5)),
                                height: max(3, min(12, inkingState.activePreset.width * 1.5))
                            )
                        Text(String(format: "%.1f", inkingState.activePreset.width))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if inkingState.activeToolMode == .textHighlight {
                HStack(spacing: 6) {
                    ForEach(PDFHighlightColor.allCases) { hlColor in
                        let isSelected = prefs.defaultHighlightColor == hlColor
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                prefs.defaultHighlightColor = hlColor
                            }
                            HapticEngine.selection()
                        } label: {
                            Circle()
                                .fill(hlColor.color)
                                .frame(width: isSelected ? 20 : 15, height: isSelected ? 20 : 15)
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .shadow(color: hlColor.color.opacity(isSelected ? 0.6 : 0.2), radius: isSelected ? 3 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)

                Text("Glide to highlight")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else if inkingState.activeToolMode == .eraser {
                // Clear Current Page Ink
                Button {
                    showClearConfirmation = true
                    HapticEngine.light()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                        Text("Clear Page")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("Pan, zoom & turn pages freely")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            // Undo & Redo Controls
            HStack(spacing: 3) {
                Button {
                    onUndo?()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Undo (2-Finger Tap)")

                Button {
                    onRedo?()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Redo (3-Finger Tap)")
            }

            // Close / Exit Markup Mode
            if let onClose = onClose {
                Button {
                    onClose()
                    HapticEngine.medium()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close Pen Toolbar")
            }
        }
        .padding(.horizontal, isCompact ? 10 : 14)
        .padding(.vertical, isCompact ? 6 : 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Favorite Slot Button

    @ViewBuilder
    private func favoriteSlotButton(at index: Int) -> some View {
        let preset = inkingState.favorites[index]
        let isSelected = inkingState.activePreset.id == preset.id

        Button {
            inkingState.selectFavorite(at: index)
            HapticEngine.selection()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: preset.kind.iconSystemName)
                    .font(.system(size: 15, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(preset.color == .obsidian ? Color.primary : preset.color.color)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isSelected ? (preset.color == .obsidian ? Color.primary.opacity(0.18) : preset.color.color.opacity(0.18)) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        Circle()
                            .stroke(isSelected ? (preset.color == .obsidian ? Color.primary : preset.color.color) : Color.clear, lineWidth: 2)
                    )

                // Color Pip with contrast border
                Circle()
                    .fill(preset.color.color)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.35), lineWidth: 0.5)
                    )
                    .offset(x: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .accessibilityLabel("\(preset.name) - \(preset.color.displayName)")
        .help("\(preset.name) (\(preset.color.displayName))")
    }

    // MARK: - Calibrated & Vibrant Artist Palette Bar

    private var colorPaletteBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(InksyncInkColor.allCases, id: \.self) { color in
                    let isSelected = inkingState.activePreset.color == color
                    Button {
                        inkingState.updateActiveColor(color)
                        HapticEngine.selection()
                        withAnimation {
                            showColorPalette = false
                        }
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: isSelected ? 28 : 22, height: isSelected ? 28 : 22)
                            .overlay(
                                Circle()
                                    .stroke(
                                        color == .obsidian || color == .pureWhite
                                            ? Color.primary.opacity(isSelected ? 0.9 : 0.4)
                                            : Color.primary.opacity(isSelected ? 0.9 : 0.15),
                                        lineWidth: isSelected ? 2.5 : 1
                                    )
                            )
                            .shadow(color: color.color.opacity(isSelected ? 0.4 : 0.1), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.displayName)
                    .help(color.displayName)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: isCompact ? 340 : 420)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: - Width Slider Bar

    private var widthSliderBar: some View {
        let isWideTool = inkingState.activePreset.kind == .highlighter || inkingState.activePreset.kind == .watercolor || inkingState.activePreset.kind == .crayon
        return HStack(spacing: 14) {
            Text("Fine")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { Double(inkingState.activePreset.width) },
                    set: { inkingState.updateActiveWidth(CGFloat($0)) }
                ),
                in: isWideTool ? 4.0...36.0 : 0.5...16.0,
                step: 0.5
            )
            .frame(width: isCompact ? 120 : 160)
            .tint(inkingState.activePreset.color.color)

            Text("Broad")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            // Live preview dot
            Circle()
                .fill(inkingState.activePreset.color.color)
                .frame(
                    width: max(4, min(24, inkingState.activePreset.width * 1.2)),
                    height: max(4, min(24, inkingState.activePreset.width * 1.2))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: - Creative Art & Layers Management Card

    private var layersHUDCard: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.inkViolet)
                    Text("Document Layers")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        showLayersHUD = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .background(Color.primary.opacity(0.08))

            // Layer 1: Document Base & Tracing Lightbox
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Tracing Lightbox")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(Int(inkingState.documentBackgroundOpacity * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.inkBlue)
                }

                HStack(spacing: 8) {
                    Text("Faint")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { inkingState.documentBackgroundOpacity },
                            set: { inkingState.documentBackgroundOpacity = $0 }
                        ),
                        in: 0.15...1.0,
                        step: 0.05
                    )
                    .tint(Color.inkBlue)
                    Text("Solid")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // Layer 2: Handwritten Ink Layer
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(inkingState.activePreset.color.color)
                        .frame(width: 9, height: 9)
                    Text("Handwritten Ink")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }

                Spacer()

                // Visibility Toggle
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        inkingState.isInkLayerVisible.toggle()
                    }
                    HapticEngine.selection()
                } label: {
                    Image(systemName: inkingState.isInkLayerVisible ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(inkingState.isInkLayerVisible ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Toggle Ink Visibility")

                // Clear Page Ink Button
                Button {
                    showClearConfirmation = true
                    HapticEngine.light()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkRed)
                        .frame(width: 28, height: 28)
                        .background(Color.inkRed.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear Page Ink")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // Layer 3: Lineart Overlay (if Coloring Studio is active)
            if inkingState.isColoringModeActive {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.inkOrange)
                        Text("Contour Lineart")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            inkingState.isLineartLayerVisible.toggle()
                        }
                        HapticEngine.selection()
                    } label: {
                        Image(systemName: inkingState.isLineartLayerVisible ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(inkingState.isLineartLayerVisible ? Color.primary : Color.secondary.opacity(0.6))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Lineart Overlay")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            // Layer 4: Text Highlights Layer
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkAmber)
                    Text("Text Highlights")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        inkingState.isTextHighlightLayerVisible.toggle()
                    }
                    HapticEngine.selection()
                } label: {
                    Image(systemName: inkingState.isTextHighlightLayerVisible ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(inkingState.isTextHighlightLayerVisible ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Toggle Text Highlights")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // Apple Pencil Only Mode (Palm & Finger Navigation Protection)
            if !isCompact {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "applepencil.and.scribble")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.inkBlue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Apple Pencil Only")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text("Fingers navigate & turn; Pencil inks")
                                .font(.system(size: 9, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { AppSettingsManager.shared.conversionSettings.pencilOnlyDrawing },
                        set: { newValue in
                            AppSettingsManager.shared.conversionSettings.pencilOnlyDrawing = newValue
                            AppSettingsManager.shared.save()
                            NotificationCenter.default.post(name: NSNotification.Name("InksyncUpdateCanvasPolicy"), object: nil)
                            HapticEngine.selection()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Color.inkGreen))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            if let onExport = onExport {
                Divider()
                    .background(Color.primary.opacity(0.08))

                // Export & Secure Share Action
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        showLayersHUD = false
                    }
                    onExport()
                    HapticEngine.medium()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up.shield")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.inkGreen)
                        Text("Export & Secure Share\u{2026}")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.inkGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.inkGreen.opacity(0.25), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("Export marked-up PDF with tamper-proof flattening or editable annotations")
            }
        }
        .padding(12)
        .frame(maxWidth: isCompact ? 300 : 340)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: - Minimized Pill

    private var minimizedPill: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isMinimized = false
                inkingState.isDockMinimized = false
            }
            HapticEngine.medium()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: inkingState.activeToolMode.iconSystemName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(inkingState.activeToolMode == .textHighlight ? Color.inkOrange : inkingState.activePreset.color.color)
                Text(inkingState.activeToolMode.displayName)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Circle()
                    .fill(inkingState.activePreset.color.color)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.25), radius: 8, y: 3)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("Expand Pen Toolbar")
    }
}
