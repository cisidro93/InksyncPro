import SwiftUI
import UIKit

struct MediaDetailSheet: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    let onAction: (LibraryRowAction) -> Void
    
    @State private var coverImage: UIImage?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                
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
                                 .fill(Color(white: 0.2))
                             Image(systemName: pdf.contentType.icon)
                                 .font(.largeTitle)
                                 .foregroundColor(.gray)
                         }
                    }
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .task {
                        if let img = conversionManager.getThumbnail(for: pdf) {
                            await MainActor.run { self.coverImage = img }
                        }
                    }
                    
                    // Metadata Info
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pdf.name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            
                        if let series = pdf.metadata.series, !series.isEmpty {
                            Text("\(series) \(pdf.metadata.issueNumber.map { "Issue #\($0)" } ?? "")")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.blue)
                        }
                        
                        if let pub = pdf.metadata.publisher, !pub.isEmpty {
                            Text(pub)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer(minLength: 8)
                        
                        // Type & Size Badges
                        HStack(spacing: 8) {
                            Text(pdf.contentType.rawValue.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .foregroundColor(pdf.contentType.badgeColor)
                                .clipShape(Capsule())
                                
                            Text(pdf.formattedSize)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                                
                            // Add Time Left Pill here if there's progress!
                            if let prog = ReaderProgressTracker.shared.progress(for: pdf.id), let mins = prog.estimatedMinutesRemaining, mins > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "timer")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("\(mins)m")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .foregroundColor(Color.orange)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.top, 4)
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.top, 24)
                
                // MARK: - Action Grid
                
                VStack(spacing: 12) {
                    // Primary — Read
                    Button {
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
                            LinearGradient(colors: [Color.blue, Color(red: 0.1, green: 0.5, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .blue.opacity(0.3), radius: 5, y: 3)
                    }

                    // Cloud files: smart Download vs Download & Convert CTA
                    if case .cloud = pdf.sourceMode {
                        let settingsReady = AppSettingsManager.shared.conversionSettings.isConfigured
                        Button {
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
                                    colors: [Color(red: 0.3, green: 0.7, blue: 0.3), Color(red: 0.1, green: 0.55, blue: 0.3)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Color.green.opacity(0.3), radius: 5, y: 3)
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
                    // The handleDetailAction .convert case routes local files directly
                    // to ConversionOrchestrator.convertComic() — the button was simply missing.
                    let localExt = pdf.url.pathExtension.lowercased()
                    if case .local = pdf.sourceMode, localExt != "epub" {
                        Button {
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
                                    colors: [Color(red: 0.3, green: 0.7, blue: 0.3), Color(red: 0.1, green: 0.55, blue: 0.3)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Color.green.opacity(0.3), radius: 5, y: 3)
                        }
                    }

                    // Send to Kindle — prominent dedicated button
                    Button {
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
                                colors: [Color(red: 0.98, green: 0.60, blue: 0.0), Color(red: 0.95, green: 0.35, blue: 0.0)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Color.orange.opacity(0.35), radius: 5, y: 3)
                    }

                    // Secondary Duo
                    HStack(spacing: 12) {
                        actionButton(title: "Cover Studio", icon: "paintbrush.pointed.fill", color: .purple, action: .covers)
                        actionButton(title: "Fetch Meta", icon: "magnifyingglass", color: .orange, action: .fetchMetadata)
                    }
                    
                    // Utilities Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        squareButton(title: "Manual Edit", icon: "pencil.and.list.clipboard", color: Color(white: 0.3), action: .editMetadata)
                        squareButton(title: "Export Tools", icon: "square.and.arrow.up", color: Color(white: 0.3), action: .export)
                        squareButton(title: "AirDrop", icon: "airplayaudio", color: Color(white: 0.3), action: .share)
                        
                        squareButton(title: "Cloud Sync", icon: "icloud.and.arrow.up", color: Color(white: 0.3), action: .sync)
                        squareButton(title: "Add to Series", icon: "books.vertical", color: Color(white: 0.3), action: .addToSeries)
                        squareButton(title: "Rename", icon: "pencil", color: Color(white: 0.3), action: .rename)
                    }
                    
                    // Destructive
                    Button {
                        handle(.delete)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "trash")
                            Text("Delete File")
                            Spacer()
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal)
                
            }
            .padding(.bottom, 40)
        }
        .background(
            ZStack {
                Color(red: 20/255, green: 20/255, blue: 22/255).ignoresSafeArea()
                if let img = self.coverImage ?? conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                    GeometryReader { geo in
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height * 0.45)
                            .blur(radius: 40)
                            .opacity(0.6)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [Color.clear, Color(red: 20/255, green: 20/255, blue: 22/255)],
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
    
    @ViewBuilder
    private func squareButton(title: String, icon: String, color: Color, action: LibraryRowAction) -> some View {
        Button {
            handle(action)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .foregroundColor(.white)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
