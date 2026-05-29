import SwiftUI
import SwiftData

struct BetaMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    @StateObject private var libraryStore: BetaLibraryStore
    @StateObject private var kindleService: BetaKindleService
    
    @State private var selectedTab = 0 // 0 = Library, 1 = Highlights, 2 = Kindle Sync
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    init(modelContext: ModelContext) {
        let store = BetaLibraryStore(modelContext: modelContext)
        _libraryStore = StateObject(wrappedValue: store)
        _kindleService = StateObject(wrappedValue: BetaKindleService(modelContext: modelContext))
    }
    
    var body: some View {
        Group {
            if sizeClass == .compact {
                iPhoneLayout
            } else {
                iPadLayout
            }
        }
        .environmentObject(libraryStore)
        .environmentObject(kindleService)
        .preferredColorScheme(.dark) // Sleek, premium dark mode by default
    }
    
    // MARK: - iPhone Layout
    
    private var iPhoneLayout: some View {
        ZStack(alignment: .bottom) {
            // Main Tab Content
            Group {
                switch selectedTab {
                case 0:
                    BetaLibraryView()
                case 1:
                    BetaHighlightView()
                case 2:
                    BetaKindleConvertView()
                default:
                    BetaLibraryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 70) // Prevent tab bar covering content
            }
            
            // Floating Translucent Tab Bar
            HStack(spacing: 40) {
                tabButton(icon: "books.vertical.fill", title: "Library", index: 0)
                tabButton(icon: "highlighter", title: "Highlights", index: 1)
                tabButton(icon: "wifi.and.ipad", title: "Sideload", index: 2)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 25)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.4))
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            )
            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 20)
            .padding(.bottom, 15)
        }
        .ignoresSafeArea(edges: .bottom)
        .background(
            LinearGradient(colors: [Color(hex: "#0F0F12"), Color(hex: "#1A1A24")], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
    
    private func tabButton(icon: String, title: String, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = index
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.orange : Color.gray)
                    .scaleEffect(isSelected ? 1.15 : 1.0)
                    .frame(height: 24)
                
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.gray)
            }
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - iPad Layout
    
    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar List
            List(selection: $selectedTab) {
                Section("Inksync Pro") {
                    NavigationLink(value: 0) {
                        Label("Library", systemImage: "books.vertical.fill")
                    }
                    NavigationLink(value: 1) {
                        Label("Highlights", systemImage: "highlighter")
                    }
                    NavigationLink(value: 2) {
                        Label("Kindle Sideload", systemImage: "wifi.and.ipad")
                    }
                }
            }
            .navigationTitle("Inksync")
            .listStyle(.sidebar)
            .background(.thinMaterial)
        } detail: {
            // Detail view based on selected tab
            Group {
                switch selectedTab {
                case 0:
                    BetaLibraryView()
                case 1:
                    BetaHighlightView()
                case 2:
                    BetaKindleConvertView()
                default:
                    BetaLibraryView()
                }
            }
            .background(
                LinearGradient(colors: [Color(hex: "#121216"), Color(hex: "#1E1E28")], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// Color Hex Initializer Helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
