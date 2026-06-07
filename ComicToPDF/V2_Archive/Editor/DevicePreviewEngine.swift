import SwiftUI
import CoreImage
import Accelerate
import UIKit
import ZIPFoundation

// MARK: - DevicePreviewEngine
//
// Live e-ink rendering simulation for InksyncPro.
// Applies the same CIFilter/vImage pipeline used in the real conversion pipeline
// to a representative source image and renders the result inside a device bezel.
//
// Design:
//  • Runs transform async on Task.detached (background thread, no MainActor contention)
//  • Throttled via a debounce timer so live slider drags don't stall
//  • The heavy CIContext is shared with ImageProcessor to avoid GPU context thrashing
//  • Phone/iPad adaptive: on iPhone = bottom sheet panel, on iPad = inline side-by-side

// MARK: - Preview Result

struct DevicePreviewResult {
    let original: UIImage
    let processed: UIImage
    let deviceProfile: TargetDeviceProfile
    let settings: ConversionSettings
    let renderTimeMs: Double
}

// MARK: - Preview ViewModel

@MainActor
final class DevicePreviewViewModel: ObservableObject {
    @Published private(set) var original: UIImage? = nil
    @Published private(set) var processed: UIImage? = nil
    @Published private(set) var isRendering: Bool = false
    @Published private(set) var renderTimeMs: Double = 0
    @Published var showSplitView: Bool = true     // false = show processed only
    @Published var isExpanded: Bool = false        // iPad: expand to full-width

    private var renderTask: Task<Void, Never>? = nil
    private var debounceTask: Task<Void, Never>? = nil

    private static let shared = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Load the first page of a comic URL as the preview source.
    func loadSourceImage(from url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = Self.extractFirstPage(url: url)
            await MainActor.run { [weak self] in
                self?.original = image
            }
        }
    }

    /// Re-render the processed preview with the current settings.
    /// Debounced — safe to call from every slider onChange.
    func requestRender(settings: ConversionSettings) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // 120ms debounce — snappy enough for sliders, slow enough to avoid stutter
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderNow(settings: settings)
        }
    }

    /// Immediate render — call when device profile changes (major setting change).
    func renderNow(settings: ConversionSettings) async {
        guard let source = original else { return }
        renderTask?.cancel()
        isRendering = true
        let start = Date()

        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            // Downsample source to preview resolution (device profile resolution, max 1200px long edge)
            let previewSize = Self.previewResolution(for: settings.targetDeviceProfile)
            let downsampled = Self.downsample(image: source, to: previewSize) ?? source

            guard !Task.isCancelled else { return }

            // Apply the full ImageProcessor pipeline (same as real conversion)
            let result = ImageProcessor.process(image: downsampled, settings: settings) ?? downsampled

            guard !Task.isCancelled else { return }

            let ms = Date().timeIntervalSince(start) * 1000
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.processed = result
                self.renderTimeMs = ms
                self.isRendering = false
            }
        }
        await renderTask?.value
    }

    // MARK: - Private Helpers

    // `nonisolated` is required so Task.detached (which runs off the MainActor) can call
    // these static methods synchronously. Without it, Swift 6 treats all statics on a
    // @MainActor class as actor-isolated and forces an `await` at every call site.

    nonisolated private static func previewResolution(for profile: TargetDeviceProfile) -> CGSize {
        // Scale device resolution to 50% for preview (fast, still representative)
        if let res = profile.resolution {
            return CGSize(width: min(res.width * 0.5, 800), height: min(res.height * 0.5, 1000))
        }
        return CGSize(width: 600, height: 800)  // fallback for .original
    }

    nonisolated private static func downsample(image: UIImage, to size: CGSize) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        let widthRatio = size.width / CGFloat(cgImage.width)
        let heightRatio = size.height / CGFloat(cgImage.height)
        let scale = min(widthRatio, heightRatio, 1.0)   // never upscale
        guard scale < 1.0 else { return image }
        let newW = Int(CGFloat(cgImage.width) * scale)
        let newH = Int(CGFloat(cgImage.height) * scale)

        var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent
        )
        var src = vImage_Buffer()
        var dst = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&src, &format, nil, cgImage, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return image }
        defer { free(src.data) }
        guard vImageBuffer_Init(&dst, vImagePixelCount(newH), vImagePixelCount(newW), 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return image }
        defer { free(dst.data) }
        guard vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return image }
        var err: vImage_Error = kvImageNoError
        guard let cg = vImageCreateCGImageFromBuffer(&dst, &format, nil, nil, vImage_Flags(kvImageNoFlags), &err),
              err == kvImageNoError else { return image }
        return UIImage(cgImage: cg.takeRetainedValue())
    }

    nonisolated private static func extractFirstPage(url: URL) -> UIImage? {
        let ext = url.pathExtension.lowercased()

        // PDF: render page 0 to CGImage
        if ext == "pdf" {
            guard let doc = CGPDFDocument(url as CFURL),
                  let page = doc.page(at: 1) else { return nil }
            var mediaBox = page.getBoxRect(.mediaBox)
            if mediaBox.width <= 0 || mediaBox.height <= 0 || mediaBox.width.isNaN || mediaBox.height.isNaN {
                mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            }
            var scale: CGFloat = min(800 / mediaBox.width, 1200 / mediaBox.height, 2.0)
            if scale <= 0 || scale.isNaN {
                scale = 1.0
            }
            let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
            guard size.width > 0 && size.height > 0 && !size.width.isNaN && !size.height.isNaN else {
                return nil
            }
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.scaleBy(x: scale, y: scale)
                ctx.cgContext.drawPDFPage(page)
            }
        }

        // CBZ/ZIP: extract first image entry
        if ext == "cbz" || ext == "zip" {
            guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else { return nil }
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
            let sorted = archive.filter {
                let name = ($0.path as NSString).lastPathComponent
                let pathExt = (name as NSString).pathExtension.lowercased()
                return imageExts.contains(pathExt) && !$0.path.contains("__MACOSX") && !name.hasPrefix("._")
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

            guard let first = sorted.first else { return nil }
            var data = Data()
            _ = try? archive.extract(first) { chunk in data.append(chunk) }
            return UIImage(data: data)
        }

        // EPUB: attempt to grab cover from zip structure
        if ext == "epub" {
            guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else { return nil }
            let imageExts: Set<String> = ["jpg", "jpeg", "png"]
            let candidates = archive.filter {
                let name = ($0.path as NSString).lastPathComponent.lowercased()
                let ext = (name as NSString).pathExtension
                return imageExts.contains(ext) && (name.contains("cover") || name.contains("page") || name.contains("001"))
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            if let first = candidates.first {
                var data = Data()
                _ = try? archive.extract(first) { chunk in data.append(chunk) }
                return UIImage(data: data)
            }
        }

        return nil
    }
}

// MARK: - Main Preview View

/// Full device preview panel — used as a bottom sheet on iPhone and an inline column on iPad.
struct DevicePreviewPanel: View {
    @ObservedObject var viewModel: DevicePreviewViewModel
    let profile: TargetDeviceProfile
    let settings: ConversionSettings

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if isIPad {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
    }

    // MARK: - iPad: side-by-side split layout

    private var iPadLayout: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Device Preview", systemImage: "eye.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.text)
                Spacer()
                Toggle("Split", isOn: $viewModel.showSplitView)
                    .toggleStyle(.button)
                    .font(.caption)
                if viewModel.isRendering {
                    ProgressView().scaleEffect(0.7)
                } else if viewModel.renderTimeMs > 0 {
                    Text(String(format: "%.0fms", viewModel.renderTimeMs))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider().opacity(0.3)

            if viewModel.showSplitView {
                HStack(spacing: 1) {
                    // Original
                    previewColumn(
                        image: viewModel.original,
                        label: "Original",
                        labelColor: .secondary
                    )
                    Divider().opacity(0.4)
                    // Processed
                    previewColumn(
                        image: viewModel.processed ?? viewModel.original,
                        label: deviceLabel,
                        labelColor: Theme.blue,
                        bezel: profile
                    )
                }
            } else {
                previewColumn(
                    image: viewModel.processed ?? viewModel.original,
                    label: deviceLabel,
                    labelColor: Theme.blue,
                    bezel: profile
                )
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - iPhone: compact strip with toggle

    private var iPhoneLayout: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "eye.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.blue)
                Text("Device Preview · \(profile.rawValue)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Spacer()
                if viewModel.isRendering {
                    ProgressView().scaleEffect(0.6)
                }
                Toggle("Split", isOn: $viewModel.showSplitView)
                    .toggleStyle(.button)
                    .font(.caption2)
                    .tint(Theme.blue)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if viewModel.showSplitView {
                HStack(spacing: 8) {
                    compactPreviewCell(image: viewModel.original, label: "Original")
                    compactPreviewCell(image: viewModel.processed ?? viewModel.original, label: deviceLabel, tint: Theme.blue)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            } else {
                compactPreviewCell(image: viewModel.processed ?? viewModel.original, label: deviceLabel, tint: Theme.blue)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.blue.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Sub-components

    @ViewBuilder
    private func previewColumn(image: UIImage?, label: String, labelColor: Color, bezel: TargetDeviceProfile? = nil) -> some View {
        VStack(spacing: 6) {
            if let img = image {
                DeviceBezelView(image: img, profile: bezel)
                    .padding(8)
            } else {
                placeholderView
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(labelColor)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func compactPreviewCell(image: UIImage?, label: String, tint: Color = .secondary) -> some View {
        VStack(spacing: 4) {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(tint.opacity(0.3), lineWidth: 0.5)
                    )
            } else {
                placeholderView
                    .frame(height: 140)
            }
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a file to preview")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            )
    }

    private var deviceLabel: String {
        profile == .original ? "Unchanged" : profile.rawValue.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? profile.rawValue
    }
}

// MARK: - Device Bezel Renderer

/// Renders an image inside a realistic device bezel shape for the selected device profile.
struct DeviceBezelView: View {
    let image: UIImage
    let profile: TargetDeviceProfile?

    private var aspectRatio: CGFloat {
        guard let res = profile?.resolution else {
            return CGFloat(image.size.height) / max(image.size.width, 1)
        }
        return res.height / res.width
    }

    private var isColor: Bool {
        guard let p = profile else { return true }
        switch p {
        case .scribeColorsoft, .colorsoft7, .koboLibraColour, .koboClaraColour, .booxTabUltraCPro, .booxNoteAir3C:
            return true
        default:
            return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width * aspectRatio

            ZStack {
                // Device shell
                RoundedRectangle(cornerRadius: width * 0.06, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.22), Color(white: 0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                // Screen recess
                RoundedRectangle(cornerRadius: width * 0.04, style: .continuous)
                    .fill(Color(white: isColor ? 0.88 : 0.93))
                    .padding(width * 0.04)

                // Image in screen
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous))
                    .padding(width * 0.05)

                // Screen glare overlay (subtle)
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: width * 0.04, style: .continuous))
                .padding(width * 0.04)

                // E-ink badge
                if profile != nil, !isColor {
                    Text("E-Ink")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(width * 0.06)
                }
            }
            .frame(width: width, height: height)
        }
        .aspectRatio(1 / aspectRatio, contentMode: .fit)
    }
}
