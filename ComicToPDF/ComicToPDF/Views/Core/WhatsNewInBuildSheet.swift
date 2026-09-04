//
//  WhatsNewInBuildSheet.swift
//  ComicToPDF
//
//  Created for InkSync Pro.
//  Point-Free Swift 6 & Apple Design Standards.
//

import SwiftUI

struct WhatsNewInBuildSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .yellow],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .padding(.top, 24)
                        
                        Text("What's New in InkSync Pro")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        
                        // Live Build Pill
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text(AppBuildInfo.formattedBadge)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.inkSurface.opacity(0.8))
                        )
                    }
                    
                    // Features list
                    ScrollView {
                        VStack(spacing: 16) {
                            FeatureRow(
                                icon: "highlighter",
                                color: .yellow,
                                title: "PDF Native Highlighting",
                                description: "Fixed ISO quad-point geometry and forced tile invalidation for crisp, instant vector highlights."
                            )
                            
                            FeatureRow(
                                icon: "book.pages",
                                color: .orange,
                                title: "EPUB 3D Curl Selection",
                                description: "Preserved text selection range during HUD taps with instant page snapshot re-rasterization."
                            )
                            
                            FeatureRow(
                                icon: "slider.horizontal.3",
                                color: .blue,
                                title: "Modular Settings Experience",
                                description: "Refactored preferences into clean, categorized iOS subpages with prominent build verification."
                            )
                            
                            FeatureRow(
                                icon: "tag.fill",
                                color: .purple,
                                title: "Live Build ID Stamping",
                                description: "Loading screen and Settings now display the exact Git commit SHA and build number."
                            )
                        }
                        .padding(.horizontal, 20)
                    }
                    
                    Spacer()
                    
                    // Acknowledge Button
                    Button {
                        AppBuildInfo.markCurrentBuildAsSeen()
                        dismiss()
                        onDismiss?()
                    } label: {
                        Text("Continue")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.orange)
                            )
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        AppBuildInfo.markCurrentBuildAsSeen()
                        dismiss()
                        onDismiss?()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.inkSurface.opacity(0.5))
        )
    }
}
