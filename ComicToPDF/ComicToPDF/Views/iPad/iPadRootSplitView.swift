import SwiftUI

struct iPadRootSplitView: View {
    @EnvironmentObject var manager: ConversionManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Binding var selectedTab: Int

    enum iPadSection: Int, Hashable, CaseIterable {
        case readNow = 0
        case library = 1
        case import_ = 2
        case devices = 3

        var title: String {
            switch self {
            case .readNow:  return "Read Now"
            case .library:  return "Library"
            case .import_:  return "Import"
            case .devices:  return "Devices"
            }
        }

        var icon: String {
            switch self {
            case .readNow:  return "book.open.fill"
            case .library:  return "books.vertical.fill"
            case .import_:  return "arrow.down.circle.fill"
            case .devices:  return "ipad.and.iphone"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            List(iPadSection.allCases, id: \.self, selection: $selectedTab) { section in
                Label(section.title, systemImage: section.icon)
                    .foregroundColor(
                        selectedTab == section.rawValue ? .inkBlue : .inkTextPrimary
                    )
                    .tag(section.rawValue) // Wire to selectedTab binding
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.inkBackground)
            .navigationTitle("InkSync Pro")
            .navigationBarTitleDisplayMode(.inline)
        } detail: {
            // Detail pane
            switch iPadSection(rawValue: selectedTab) ?? .readNow {
            case .readNow:
                ReadNowView()
            case .library:
                InkLibraryView()
            case .import_:
                ImportTriggerView()
            case .devices:
                DevicesView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
