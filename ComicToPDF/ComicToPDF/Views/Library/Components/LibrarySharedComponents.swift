import SwiftUI

enum LibraryRowAction {
    case read, covers, fetchMetadata, editMetadata, export, share, sync, rename, addToSeries, delete, favorite, details
}

// MARK: - Theme Colors
struct Theme {
    static let bg = Color.black
    static let surface = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let surfaceElevated = Color(red: 58/255, green: 58/255, blue: 60/255)
    static let orange = Color(red: 1, green: 159/255, blue: 10/255) // #FF9F0A
    static let blue = Color(red: 10/255, green: 132/255, blue: 255/255) // #0A84FF
    static let purple = Color(red: 191/255, green: 90/255, blue: 242/255) // #BF5AF2 
    static let green = Color(red: 48/255, green: 209/255, blue: 88/255) // #30D158
    static let text = Color.white
    static let textSecondary = Color(red: 142/255, green: 142/255, blue: 147/255) // #8E8E93
    static let textTertiary = Color(red: 99/255, green: 99/255, blue: 102/255) // #636366
}

// MARK: - Action Pill Component
struct ActionPill: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
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
        .background(Color.black)
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
                    .fill(Color.black.opacity(0.4))
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
