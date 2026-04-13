import SwiftUI

enum LibraryRowAction {
    case read, covers, fetchMetadata, editMetadata, export, share, sync, rename, addToSeries, delete, favorite, details, toggleVault
}

// MARK: - Theme Colors
struct Theme {
    static let bg = Color(UIColor.systemBackground)
    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    static let surfaceElevated = Color(UIColor.tertiarySystemGroupedBackground)
    static let orange = Color.orange
    static let blue = Color.blue
    static let purple = Color.purple
    static let green = Color.green
    static let red = Color.red
    static let text = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(UIColor.tertiaryLabel)
}

// MARK: - Action Pill Component
struct ActionPill: View {
    let title: String
    let icon: String
    let color: Color // Used to tint the icon in the new Liquid Glass look
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(LinearGradient(colors: [Theme.text.opacity(0.4), Theme.text.opacity(0.0)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: Color(UIColor.systemBackground).opacity(0.15), radius: 8, y: 4)
        }
    }
}

// MARK: - Empty State
struct ModernEmptyState: View {
    var onImport: () -> Void
    var onFolderImport: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Simulated "Bookshelf" Icon using SF Symbols stack
            ZStack(alignment: .bottom) {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundColor(Theme.surfaceElevated)
                
                // Shelf line
                Rectangle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 120, height: 4)
                    .offset(y: 4)
            }
            .padding(.bottom, 20)
            
            Text("Your Library is Empty")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(Theme.text)
            
            Button(action: onImport) {
                HStack {
                    Image(systemName: "plus")
                    Text("Import Comic")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Theme.blue)
                .cornerRadius(12)
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Comic Zeal Scrubber
struct ComicZealScrubber: View {
    let onScrub: (String) -> Void
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ#")
    @State private var activeLetter: String? = nil
    
    var body: some View {
        GeometryReader { geo in
            let itemHeight = geo.size.height / CGFloat(letters.count)
            
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { char in
                    Text(String(char))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(activeLetter == String(char) ? Theme.blue : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: itemHeight)
                }
            }
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value: value, itemHeight: itemHeight)
                    }
                    .onEnded { _ in
                        activeLetter = nil
                    }
            )
        }
        .frame(width: 24)
    }
    
    private func handleDrag(value: DragGesture.Value, itemHeight: CGFloat) {
        let index = Int(value.location.y / itemHeight)
        if index >= 0 && index < letters.count {
            let letter = String(letters[index])
            if activeLetter != letter {
                activeLetter = letter
                onScrub(letter)
                let generator = UISelectionFeedbackGenerator()
                generator.selectionChanged()
            }
        }
    }
}
