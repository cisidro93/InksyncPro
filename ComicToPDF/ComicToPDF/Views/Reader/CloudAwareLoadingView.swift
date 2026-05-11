import SwiftUI

// MARK: - CloudAwareLoadingView
// Shown during ReaderView's isLoading phase.
//
// Fast path  (CBZ/ZIP/EPUB) → 2 phases, both complete in < 1 second:
//   1. "Connecting…"     — resolving auth'd download URL
//   2. "Reading index…"  — fetching ZIP central directory (~50ms)
//   Then reader opens immediately with no wait for page data.
//
// Fallback path (CBR/RAR) → Full progress bar with % until download completes.
//
// Local file → Plain spinner (unchanged from before).

struct CloudAwareLoadingView: View {
    let pdf: ConvertedPDF?

    @ObservedObject private var coordinator = CloudStreamCoordinator.shared
    @ObservedObject private var downloadManager = CloudDownloadManager.shared

    private var remoteID: String? {
        guard let pdf, case .cloud(_, let id) = pdf.sourceMode else { return nil }
        return id
    }

    private var isCloudFile: Bool {
        guard let pdf else { return false }
        if case .cloud = pdf.sourceMode { return true }
        return false
    }

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

    @ViewBuilder
    private var cloudLoadingContent: some View {
        VStack(spacing: 24) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: iconName)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse, isActive: coordinator.phase != .ready)
                    .animation(.easeInOut, value: coordinator.phase)
            }

            VStack(spacing: 8) {
                Text(headlineText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: headlineText)

                if let name = pdf?.name {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260)
                }
            }

            // Progress indicator
            if case .downloading(let fraction) = coordinator.phase {
                // CBR fallback — show full percentage bar
                VStack(spacing: 6) {
                    if fraction > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [.orange, .yellow],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: geo.size.width * CGFloat(fraction))
                                    .animation(.easeInOut(duration: 0.3), value: fraction)
                            }
                        }
                        .frame(width: 240, height: 6)

                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                            .contentTransition(.numericText())
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.orange)
                            .frame(width: 240)
                            .scaleEffect(x: 1, y: 1.5)
                    }
                }
            } else {
                switch coordinator.phase {
                case .resolvingURL, .fetchingIndex, .extracting:
                    // Show indeterminate bar for these transition phases
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                        .frame(width: 240)
                        .scaleEffect(x: 1, y: 1.5)
                default:
                    EmptyView()
                }
            }

            Text(footerText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
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

    // MARK: - Dynamic Text

    private var headlineText: String {
        switch coordinator.phase {
        case .idle:             return "Preparing…"
        case .resolvingURL:     return "Connecting to Cloud…"
        case .fetchingIndex:    return "Reading File Index…"
        case .downloading:      return "Downloading Archive…"
        case .extracting:       return "Unpacking Archive…"
        case .ready:            return "Opening…"
        case .failed:           return "Connection Failed"
        }
    }

    private var iconName: String {
        switch coordinator.phase {
        case .downloading, .extracting: return "arrow.down.circle"
        default:                         return "icloud.and.arrow.down"
        }
    }

    private var footerText: String {
        switch coordinator.phase {
        case .downloading:  return "RAR archive — requires full download"
        case .extracting:   return "Extracting pages — storage cleared when done"
        default:            return "Files stay in the cloud — this session only"
        }
    }
}
