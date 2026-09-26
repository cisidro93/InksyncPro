import SwiftUI
import UIKit

struct MediaDetailSheet: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    let onAction: (LibraryRowAction) -> Void
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var coverImage: UIImage?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Drag Pill
                InkSheetDragPill()
                
                // MARK: - Header (Cover & Meta)
                HStack(alignment: .top, spacing: 16) {
                    
                    // Cover Image
                    ZStack {
                         if let coverImage = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                             Image(uiImage: coverImage)
                                 .resizable()
                                 .aspectRatio(contentMode: .fill)
                         } else if let img = self.coverImage {
                             Image(uiImage: img)
                                 .resizable()
                                 .aspectRatio(contentMode: .fill)
                         } else {
                             Rectangle()
                                 .fill(Color.inkSurfaceRaised)
                             Image(systemName: pdf.contentType.icon)
                                 .font(.largeTitle)
                                 .foregroundColor(.gray)
                         }
                    }
                    .frame(
                        width: hSizeClass == .regular ? 120 : 100,
                        height: hSizeClass == .regular ? 180 : 150
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .inkSpecularBorder(cornerRadius: 12)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    .task {
                        if let img = conversionManager.getThumbnail(for: pdf) {
                            await MainActor.run { self.coverImage = img }
                        }
                    }
                    
                    // Metadata Info
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pdf.name)
                            .font(.system(size: hSizeClass == .regular ? 22 : 19, weight: .bold))
                            .foregroundColor(Color.inkTextPrimary)
                            .lineLimit(3)
                            
                        if let series = pdf.metadata.series, !series.isEmpty {
                            Text("\(series) \(pdf.metadata.issueNumber.map { "Issue #\($0)" } ?? "")")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.inkBlue)
                        }
                        
                        if let pub = pdf.metadata.publisher, !pub.isEmpty {
                            Text(pub)
                                .font(.caption)
                                .foregroundColor(Color.inkTextSecondary)
                        }
                        
                        Spacer(minLength: 4)
                        
                        // Type & Size Badges
                        HStack(spacing: hSizeClass == .regular ? 8 : 6) {
                            Text(pdf.contentType.rawValue.uppercased())
                                .font(.system(size: hSizeClass == .regular ? 10 : 9, weight: .bold))
                                .padding(.horizontal, hSizeClass == .regular ? 8 : 6)
                                .padding(.vertical, hSizeClass == .regular ? 5 : 4)
                                .background(.ultraThinMaterial)
                                .foregroundColor(pdf.contentType.badgeColor)
                                .clipShape(Capsule())
                                
                            Text(pdf.formattedSize)
                                .font(.system(size: hSizeClass == .regular ? 10 : 9, weight: .bold))
                                .padding(.horizontal, hSizeClass == .regular ? 8 : 6)
                                .padding(.vertical, hSizeClass == .regular ? 5 : 4)
                                .background(.ultraThinMaterial)
                                .foregroundColor(Color.inkTextPrimary)
                                .clipShape(Capsule())
                                
                            // Add Time Left Pill here if there's progress!
                            if let prog = ReaderProgressTracker.shared.progress(for: pdf.id), let mins = prog.estimatedMinutesRemaining, mins > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "timer")
                                        .font(.system(size: hSizeClass == .regular ? 9 : 8, weight: .bold))
                                    Text("\(mins)m")
                                        .font(.system(size: hSizeClass == .regular ? 10 : 9, weight: .bold))
                                }
                                .padding(.horizontal, hSizeClass == .regular ? 8 : 6)
                                .padding(.vertical, hSizeClass == .regular ? 5 : 4)
                                .background(.ultraThinMaterial)
                                .foregroundColor(Color.inkOrange)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.top, 4)
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                // MARK: - Action Grid
                
                VStack(spacing: 12) {
                    // Primary — Read
                    Button {
                        HapticEngine.selection()
                        handle(.read)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "book.pages.fill")
                            Text("READ NOW")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding()
                        .background(
                            LinearGradient(colors: [Color.inkBlue, Color(hex: "#4facfe")], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .inkSpecularBorder(cornerRadius: 14)
                        .shadow(color: Color.inkBlue.opacity(0.3), radius: 6, y: 3)
                    }

                    // Cloud files: smart Download vs Download & Convert CTA
                    if case .cloud = pdf.sourceMode {
                        let settingsReady = AppSettingsManager.shared.conversionSettings.isConfigured
                        Button {
                            HapticEngine.medium()
                            handle(.convert)
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: settingsReady ? "arrow.down.circle.fill" : "arrow.down.circle")
                                Text(settingsReady ? "DOWNLOAD & CONVERT" : "DOWNLOAD")
                                    .fontWeight(.bold)
                                Spacer()
                            }
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .padding()
                            .background(
                                LinearGradient(
                                    colors: [Color.inkGreen, Color(hex: "#059669")],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .inkSpecularBorder(cornerRadius: 14)
                            .shadow(color: Color.inkGreen.opacity(0.3), radius: 6, y: 3)
                        }
                        if !settingsReady {
                            Text("Configure conversion settings first to enable auto-convert on download.")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                    }

                    // Local files: Convert to EPUB for any non-EPUB format.
                    let localExt = pdf.url.pathExtension.lowercased()
                    if case .local = pdf.sourceMode, localExt != "epub" {
                        Button {
                            HapticEngine.medium()
                            handle(.convert)
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                Text("CONVERT TO EPUB")
                                    .fontWeight(.bold)
                                Spacer()
                            }
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .padding()
                            .background(
                                LinearGradient(
                                    colors: [Color.inkGreen, Color(hex: "#059669")],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .inkSpecularBorder(cornerRadius: 14)
                            .shadow(color: Color.inkGreen.opacity(0.3), radius: 6, y: 3)
                        }
                    }

                    // Send to Kindle — prominent dedicated button
                    Button {
                        HapticEngine.medium()
                        handle(.sendToKindle)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "paperplane.fill")
                            Text("SEND TO KINDLE")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [Color.inkOrange, Color.inkAmber],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .inkSpecularBorder(cornerRadius: 14)
                        .shadow(color: Color.inkOrange.opacity(0.35), radius: 6, y: 3)
                    }

                    // Secondary Duo
                    HStack(spacing: 12) {
                        actionButton(title: "Cover Studio", icon: "paintbrush.pointed.fill", color: .inkViolet, action: .covers)
                        actionButton(title: "Fetch Meta", icon: "magnifyingglass", color: .inkAmber, action: .fetchMetadata)
                    }
                    
                    // Utilities Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        squareButton(title: "Manual Edit", icon: "pencil.and.list.clipboard", action: .editMetadata)
                        squareButton(title: "Export Tools", icon: "square.and.arrow.up", action: .export)
                        squareButton(title: "AirDrop", icon: "airplayaudio", action: .share)
                        
                        squareButton(title: "Cloud Sync", icon: "icloud.and.arrow.up", action: .sync)
                        squareButton(title: "Add to Series", icon: "books.vertical", action: .addToSeries)
                        squareButton(title: "Rename", icon: "pencil", action: .rename)
                    }
                    
                    // Reading Status / Shelf Action
                    let hasReadingHistory = (pdf.metadata.lastReadPage ?? 0) > 0 || ReaderProgressTracker.shared.progress(for: pdf.id) != nil
                    if hasReadingHistory {
                        Button {
                            HapticEngine.selection()
                            ReaderProgressTracker.shared.clearReadingData(for: pdf.id, in: conversionManager)
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Clear Reading History")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .font(.system(size: 15))
                            .foregroundColor(.inkOrange)
                            .padding(.vertical, 14)
                            .background(Color.inkOrange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.inkOrange.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                    
                    // Destructive
                    Button {
                        HapticEngine.warning()
                        handle(.delete)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "trash")
                            Text("Delete File")
                            Spacer()
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.inkRed)
                        .padding()
                        .background(Color.inkRed.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.inkRed.opacity(0.3), lineWidth: 0.8)
                        )
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal)
                .frame(maxWidth: 680)
                
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        .background(
            ZStack {
                Color.inkBackground.ignoresSafeArea()
                if let img = self.coverImage ?? conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                    GeometryReader { geo in
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height * 0.45)
                            .blur(radius: 40)
                            .opacity(0.35)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [Color.clear, Color.inkBackground],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }.ignoresSafeArea(edges: .top)
                }
            }
        )
    }
    
    // MARK: - Components
    
    private func handle(_ action: LibraryRowAction) {
        dismiss()
        onAction(action)
    }
    
    @ViewBuilder
    private func actionButton(title: String, icon: String, color: Color, action: LibraryRowAction) -> some View {
        Button {
            HapticEngine.selection()
            handle(action)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundColor(.white)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .inkSpecularBorder(cornerRadius: 14)
        }
    }
    
    @ViewBuilder
    private func squareButton(title: String, icon: String, action: LibraryRowAction) -> some View {
        Button {
            HapticEngine.selection()
            handle(action)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(Color.inkTextPrimary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.inkTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(Color.inkSurfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .inkSpecularBorder(cornerRadius: 14)
        }
    }
}
