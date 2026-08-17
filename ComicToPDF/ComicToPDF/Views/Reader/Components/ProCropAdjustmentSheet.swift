import SwiftUI
import PDFKit

/// Pro Crop Adjustment Sheet — Interactive visual crop adjustment modal for PDFs and comics.
/// Provides live Top/Bottom/Left/Right trim sliders, 1-tap presets, and per-book persistence.
struct ProCropAdjustmentSheet: View {
    let pdfID: UUID
    let pdfDocument: PDFDocument?
    let currentPageIndex: Int
    var onApplyCrop: (CodableCropInsets) -> Void
    var onDismiss: () -> Void

    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var topTrim: Double = 0.0
    @State private var bottomTrim: Double = 0.0
    @State private var leftTrim: Double = 0.0
    @State private var rightTrim: Double = 0.0
    @State private var selectedMode: String = "custom" // "smartAuto", "custom", "none"
    @State private var previewImage: UIImage? = nil
    @State private var showSavedToast: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Mode Selector Segmented Control
                HStack(spacing: 8) {
                    modeButton(title: "Smart Auto", icon: "sparkles", mode: "smartAuto")
                    modeButton(title: "Custom Pro", icon: "crop", mode: "custom")
                    modeButton(title: "Full Page", icon: "arrow.up.left.and.down.right", mode: "none")
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // Interactive Visual Page Preview with Live Crop Guides
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                    if let img = previewImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                            .padding(12)
                            .overlay(
                                GeometryReader { geo in
                                    let w = geo.size.width - 24
                                    let h = geo.size.height - 24
                                    let x = 12 + (w * leftTrim)
                                    let y = 12 + (h * topTrim)
                                    let cropW = max(10, w * (1.0 - leftTrim - rightTrim))
                                    let cropH = max(10, h * (1.0 - topTrim - bottomTrim))

                                    ZStack {
                                        // Dimmed outer region
                                        Rectangle()
                                            .fill(Color.black.opacity(0.4))
                                            .mask(
                                                Rectangle()
                                                    .fill(Color.black)
                                                    .overlay(
                                                        Rectangle()
                                                            .frame(width: cropW, height: cropH)
                                                            .position(x: x + cropW / 2, y: y + cropH / 2)
                                                            .blendMode(.destinationOut)
                                                    )
                                            )

                                        // Orange crop boundary box
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.orange, lineWidth: 2)
                                            .frame(width: cropW, height: cropH)
                                            .position(x: x + cropW / 2, y: y + cropH / 2)
                                    }
                                }
                            )
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading Page Preview…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .padding(.horizontal)

                if selectedMode == "custom" {
                    // Precision Trim Sliders
                    ScrollView {
                        VStack(spacing: 12) {
                            trimSlider(label: "Top Trim", value: $topTrim, icon: "arrow.up")
                            trimSlider(label: "Bottom Trim", value: $bottomTrim, icon: "arrow.down")
                            trimSlider(label: "Left Trim", value: $leftTrim, icon: "arrow.left")
                            trimSlider(label: "Right Trim", value: $rightTrim, icon: "arrow.right")

                            // Quick Presets
                            HStack(spacing: 12) {
                                presetButton(title: "10% Uniform", action: {
                                    topTrim = 0.10; bottomTrim = 0.10; leftTrim = 0.10; rightTrim = 0.10
                                })
                                presetButton(title: "15% Top/Bottom", action: {
                                    topTrim = 0.15; bottomTrim = 0.15; leftTrim = 0.05; rightTrim = 0.05
                                })
                                presetButton(title: "Reset Margins", action: {
                                    topTrim = 0; bottomTrim = 0; leftTrim = 0; rightTrim = 0
                                })
                            }
                            .padding(.top, 4)
                        }
                        .padding(.horizontal)
                    }
                } else if selectedMode == "smartAuto" {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Smart Auto-Crop Active")
                            .font(.headline)
                        Text("Automatically detects text bounding boxes & trims margins on the fly for every page.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.plaintext")
                            .font(.largeTitle)
                            .foregroundColor(.blue)
                        Text("Full Uncropped Page (MediaBox)")
                            .font(.headline)
                        Text("Displays full standard page boundaries without margin trimming.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxHeight: .infinity)
                }

                Spacer()

                // Action Footer
                VStack(spacing: 8) {
                    Button(action: saveAndApplyCrop) {
                        HStack {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("Save Crop for This Document")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .orange.opacity(0.3), radius: 6, y: 3)
                    }

                    Button(action: setAsAppDefault) {
                        Text("Set Mode as App Default")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .navigationTitle("Document Crop Engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
            .onAppear(perform: loadCurrentCropSettings)
        }
        .overlay(alignment: .top) {
            if showSavedToast {
                Text("Saved to Document Preferences ✓")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Helpers

    private func modeButton(title: String, icon: String, mode: String) -> some View {
        Button(action: {
            HapticEngine.selection()
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedMode = mode
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selectedMode == mode ? Color.orange : Color(UIColor.tertiarySystemBackground))
            .foregroundColor(selectedMode == mode ? .white : .primary)
            .cornerRadius(10)
        }
    }

    private func trimSlider(label: String, value: Binding<Double>, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: 0.0...0.35, step: 0.01) { _ in
                HapticEngine.light()
            }
            .tint(.orange)
        }
    }

    private func presetButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            HapticEngine.medium()
            withAnimation { action() }
        }) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .cornerRadius(8)
        }
    }

    private func loadCurrentCropSettings() {
        if let saved = ReaderProgressTracker.shared.cropInsets(for: pdfID) {
            selectedMode = saved.modeRaw
            topTrim = saved.top
            bottomTrim = saved.bottom
            leftTrim = saved.left
            rightTrim = saved.right
        } else {
            selectedMode = prefs.defaultCropModeRaw
            topTrim = prefs.defaultCropTop
            bottomTrim = prefs.defaultCropBottom
            leftTrim = prefs.defaultCropLeft
            rightTrim = prefs.defaultCropRight
        }

        // Render low-res preview of current page
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        Task.detached(priority: .userInitiated) {
            let rect = page.bounds(for: .mediaBox)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            let targetSize = CGSize(width: 300, height: 300 * (rect.height / max(1, rect.width)))
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let img = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: targetSize))
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: 0, y: targetSize.height)
                ctx.cgContext.scaleBy(x: targetSize.width / rect.width, y: -targetSize.height / rect.height)
                page.draw(with: .mediaBox, to: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.previewImage = img
                }
            }
        }
    }

    private func saveAndApplyCrop() {
        HapticEngine.success()
        let insets = CodableCropInsets(
            top: topTrim,
            bottom: bottomTrim,
            left: leftTrim,
            right: rightTrim,
            modeRaw: selectedMode
        )
        ReaderProgressTracker.shared.saveCropInsets(insets, for: pdfID)
        onApplyCrop(insets)

        withAnimation { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showSavedToast = false
            onDismiss()
        }
    }

    private func setAsAppDefault() {
        HapticEngine.medium()
        prefs.defaultCropModeRaw = selectedMode
        prefs.defaultCropTop = topTrim
        prefs.defaultCropBottom = bottomTrim
        prefs.defaultCropLeft = leftTrim
        prefs.defaultCropRight = rightTrim
        withAnimation { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showSavedToast = false
        }
    }
}
