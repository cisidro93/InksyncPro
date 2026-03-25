import SwiftUI

struct ReadNowView: View {
    @EnvironmentObject var manager: ConversionManager
    @State private var activeSheet: LibrarySheetDestination?

    // Extracted directly from persistence model heuristically
    var continueReading: [ConvertedPDF] {
        manager.visiblePDFs
            .filter { $0.isOnDevice || $0.lastConversionDate != nil }
            .sorted { ($0.lastConversionDate ?? .distantPast) > ($1.lastConversionDate ?? .distantPast) }
            .prefix(4)
            .map { $0 }
    }

    var recentlyAdded: [ConvertedPDF] {
        manager.visiblePDFs
            .sorted(by: { $0.lastModified > $1.lastModified })
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        
                        // Continue Reading
                        if !continueReading.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Continue Reading")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.inkTextPrimary)
                                    .padding(.horizontal, 20)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(continueReading) { pdf in
                                            BookCard(
                                                pdf: pdf,
                                                manager: manager,
                                                isSelected: false,
                                                isBatchMode: false,
                                                onTap: { activeSheet = .details(pdf) },
                                                onLongPress: {},
                                                onContextAction: { _ in }
                                            )
                                            .scaleEffect(1.1) // slightly larger for hero section
                                            .padding(.vertical, 10) // padding to avoid clipping scale
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                            }
                            .padding(.top, 10)
                        }

                        // Just Added
                        if !recentlyAdded.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Recently Added")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.inkTextPrimary)
                                    .padding(.horizontal, 20)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(recentlyAdded) { pdf in
                                            BookCard(
                                                pdf: pdf,
                                                manager: manager,
                                                isSelected: false,
                                                isBatchMode: false,
                                                onTap: { activeSheet = .details(pdf) },
                                                onLongPress: {},
                                                onContextAction: { _ in }
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                            }
                        }

                        if continueReading.isEmpty && recentlyAdded.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Read Now")
            .sheet(item: $activeSheet) { dest in
                Text("Destination: \(String(describing: dest))")
                    .environmentObject(manager)
            }
        }
    }

    @ViewBuilder
    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 48))
                .foregroundColor(.inkTextSecondary)
            Text("Nothing to read yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.inkTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}
