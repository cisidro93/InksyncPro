import SwiftUI
import PDFKit

/// Glassmorphic Hyperlink Page Preview HUD Modal for InksyncPro
/// Intercepts PDF hyperlinks / PDFActionGoTo, displaying a live rendered thumbnail
/// preview of the target page before jumping, complete with 1-tap confirmation.
struct HyperlinkPreviewHUD: View {
    let targetPageIndex: Int
    let targetPage: PDFPage
    let onConfirmJump: () -> Void
    let onDismiss: () -> Void
    
    @State private var pageThumbnail: UIImage? = nil
    
    var body: some View {
        VStack(spacing: 16) {
            // Header Bar
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.inkGreen)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hyperlink Destination")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Page \(targetPageIndex + 1)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                Button(action: {
                    HapticEngine.light()
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            // Rendered Page Thumbnail Frame
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.4))
                    .frame(height: 280)
                
                if let thumb = pageThumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.inkGreen)
                        Text("Rendering Page Preview...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 16)
            
            // Action Buttons
            HStack(spacing: 12) {
                Button(action: {
                    HapticEngine.light()
                    onDismiss()
                }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                
                Button(action: {
                    HapticEngine.medium()
                    onConfirmJump()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Jump to Page \(targetPageIndex + 1)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.inkGreen)
                    .clipShape(Capsule())
                    .shadow(color: Color.inkGreen.opacity(0.4), radius: 8, y: 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 24, y: 10)
        .task {
            renderThumbnail()
        }
    }
    
    private func renderThumbnail() {
        let size = CGSize(width: 300, height: 400)
        let thumb = targetPage.thumbnail(of: size, for: .cropBox)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            self.pageThumbnail = thumb
        }
    }
}
