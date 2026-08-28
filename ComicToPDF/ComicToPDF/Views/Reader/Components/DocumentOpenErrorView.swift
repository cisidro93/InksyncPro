import SwiftUI

/// Premium, frosted-glass error recovery view presented when a document fails to load or open in any reader engine.
struct DocumentOpenErrorView: View {
    let report: DocumentDiagnosticReport
    var onRetry: (() -> Void)? = nil
    var onDismiss: () -> Void
    
    @State private var isShowingLogs = false
    @State private var hasCopiedTrace = false
    @State private var isTechnicalDetailsExpanded = false
    
    var body: some View {
        ZStack {
            // Deep frosted backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header Shield Icon
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.red.opacity(0.35), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 50
                            )
                        )
                        .frame(width: 84, height: 84)
                    
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Circle()
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                        )
                    
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .red],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                
                // Document Info & Headline
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(report.fileExtension.uppercased())
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.8), in: Capsule())
                        
                        Text(report.formattedFileSize)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Text(report.fileName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                    
                    Text("Could not open document")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                }
                
                // Root Cause Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text("Reason for Failure")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                        Spacer()
                    }
                    
                    Text(report.rootCauseDescription)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    if !report.actionableRemediation.isEmpty {
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.vertical, 2)
                        
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.yellow)
                                .padding(.top, 2)
                            Text(report.actionableRemediation)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                
                // Technical Diagnostics Disclosure
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isTechnicalDetailsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 11))
                            Text("Technical Diagnostic Trace")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Spacer()
                            Image(systemName: isTechnicalDetailsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 4)
                    }
                    
                    if isTechnicalDetailsExpanded {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(report.formattedLogString)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 140)
                        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .padding(.horizontal, 16)
                
                // Action Buttons
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        // Copy Diagnostic Trace
                        Button {
                            UIPasteboard.general.string = report.formattedLogString
                            HapticEngine.success()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                hasCopiedTrace = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                await MainActor.run {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        hasCopiedTrace = false
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: hasCopiedTrace ? "checkmark.circle.fill" : "doc.on.doc.fill")
                                Text(hasCopiedTrace ? "Trace Copied!" : "Copy Trace")
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(hasCopiedTrace ? .green : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(hasCopiedTrace ? Color.green.opacity(0.4) : Color.white.opacity(0.15), lineWidth: 1)
                            )
                        }
                        
                        // View Flight Recorder Logs
                        Button {
                            isShowingLogs = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.rectangle.fill")
                                Text("View Logs")
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                        }
                    }
                    
                    HStack(spacing: 10) {
                        // Close / Go Back
                        Button {
                            onDismiss()
                        } label: {
                            Text("Close")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        
                        // Retry (if provided)
                        if let retry = onRetry {
                            Button {
                                HapticEngine.medium()
                                retry()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Retry")
                                }
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .shadow(color: .blue.opacity(0.3), radius: 6, y: 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(20)
            .frame(maxWidth: 440)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
            .padding(.horizontal, 20)
        }
        .sheet(isPresented: $isShowingLogs) {
            NavigationStack {
                LogsView()
            }
        }
    }
}
