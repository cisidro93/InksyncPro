import SwiftUI

// MARK: - CloudAwareLoadingView
// Shown during ReaderView's isLoading phase.
// • Cloud file  → shows a branded iCloud icon + live download percentage bar
// • Local file  → shows the original "Opening Book…" spinner
//
// This view observes CloudDownloadManager.streamProgress so it updates automatically
// as bytes arrive without requiring any additional @State threading in ReaderView.

struct CloudAwareLoadingView: View {
    let pdf: ConvertedPDF?

    @ObservedObject private var downloadManager = CloudDownloadManager.shared

    private var remoteID: String? {
        guard let pdf, case .cloud(_, let id) = pdf.sourceMode else { return nil }
        return id
    }

    private var streamFraction: Double? {
        guard let id = remoteID else { return nil }
        return downloadManager.streamProgress[id]
    }

    private var isCloudFile: Bool { remoteID != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            if isCloudFile {
                cloudLoadingContent
            } else {
                localLoadingContent
            }
        }
    }

    // MARK: - Cloud Loading UI
    private var cloudLoadingContent: some View {
        VStack(spacing: 24) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse, isActive: streamFraction == nil || streamFraction! < 1.0)
            }

            VStack(spacing: 8) {
                Text("Streaming from Cloud")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                if let name = pdf?.name {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260)
                }
            }

            // Progress bar
            VStack(spacing: 6) {
                if let fraction = streamFraction, fraction > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.orange, .yellow],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * CGFloat(fraction))
                                .animation(.easeInOut(duration: 0.3), value: fraction)
                        }
                    }
                    .frame(width: 240, height: 6)

                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                        .contentTransition(.numericText())
                        .animation(.easeInOut, value: Int(fraction * 100))
                } else {
                    // Indeterminate — waiting for URL resolution / first bytes
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                        .frame(width: 240)
                        .scaleEffect(x: 1, y: 1.5)

                    Text("Connecting…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Text("Files stay in the cloud — this session only")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Local Loading UI
    private var localLoadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Opening Book…")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}
