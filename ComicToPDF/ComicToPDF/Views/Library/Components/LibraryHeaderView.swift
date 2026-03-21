import SwiftUI

struct LibraryHeaderView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Bindings to parent view
    @Binding var searchText: String
    @Binding var sortOption: ModernLibraryView.SortOption
    @Binding var viewStyle: ModernLibraryView.LibraryViewStyle
    @Binding var tapAction: LibraryTapAction
    @Binding var activeSheet: ModernLibraryView.SidebarSheet?
    @Binding var isBatchMode: Bool
    @Binding var multiSelection: Set<UUID>
    @Binding var batchMergeItems: [ConvertedPDF]
    @Binding var showingBatchMergeReorder: Bool
    
    // Vault unlock callback
    var onVaultToggle: () -> Void
    var onSelectAll: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 16) {
            
            // Row 1: Integrated Search & Title
            HStack(spacing: 12) {
                // Title / Brand
                HStack(spacing: 6) {
                     Image(systemName: "books.vertical.fill")
                         .font(.system(size: 24, weight: .bold))
                         .foregroundStyle(Theme.orange.gradient)
                     Text("Library")
                         .font(.system(size: 28, weight: .bold))
                         .foregroundColor(.white)
                         .fixedSize(horizontal: true, vertical: false)
                }
                
                Spacer()
                
                // Large Integrated Search Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    
                    TextField("Search Collection...", text: $searchText)
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .tint(Theme.orange)
                    
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(.ultraThinMaterial) // Liquid Glass Field
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
                .frame(maxWidth: 400) // Constrain width on large screens
                
                // ✅ Sort Menu
                Menu {
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(ModernLibraryView.SortOption.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                }
                
                // ✅ Grid / List Toggle
                Button {
                    withAnimation {
                        viewStyle = viewStyle == .grid ? .list : .grid
                    }
                } label: {
                    Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                }
                
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // Row 2: Cohesive Action Center (Scrollable Pills)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    
                    // 1. Target Selector Pill (Fixed & Prominent)
                    Menu {
                        Section("Standard Formats") {
                            Picker("Target Format", selection: $conversionManager.conversionSettings.outputFormat) {
                                ForEach(OutputFormat.allCases) { format in
                                    Label(format.rawValue, systemImage: format.icon).tag(format)
                                }
                            }
                        }
                        
                        if !conversionManager.conversionPresets.isEmpty {
                            Section("Custom Profiles") {
                                ForEach(conversionManager.conversionPresets) { preset in
                                    Button {
                                        conversionManager.conversionSettings = preset.settings
                                    } label: {
                                        Label(preset.name, systemImage: "list.clipboard.fill")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("TARGET")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                                .tracking(1)
                            
                            // Separator
                            Rectangle().fill(Theme.textSecondary.opacity(0.3)).frame(width: 1, height: 12)
                            
                            // Value
                            Text(conversionManager.conversionSettings.outputFormat.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.orange)
                                .fixedSize() // Prevent truncation
                            
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thickMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    
                    // Divider
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 24)
                    
                    // 2. Action Pick
                    Menu {
                        Picker("Tap Action", selection: $tapAction) {
                            ForEach(LibraryTapAction.allCases, id: \.self) { action in
                                Text(action.rawValue).tag(action)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("TAP ACTION:")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                                .tracking(1)
                            
                            HStack(spacing: 4) {
                                Text(tapAction.rawValue)
                                    .font(.system(size: 14, weight: .semibold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(Theme.orange)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thickMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                    
                    // 3. Action Pills
                    Group {
                        ActionPill(title: "Import", icon: "doc.badge.plus", color: Theme.orange) {
                            activeSheet = .importer
                        }
                        ActionPill(title: "Wi-Fi", icon: "wifi", color: Theme.blue) { activeSheet = .wifi }
                        ActionPill(title: "Cloud", icon: "icloud", color: Theme.blue) { activeSheet = .cloud }
                    }
                    Group {
                        ActionPill(title: "Merge", icon: "arrow.triangle.merge", color: Theme.blue) { activeSheet = .merge }
                        ActionPill(title: "Convert & Merge", icon: "doc.on.doc.fill", color: Theme.purple, action: {
                            if multiSelection.count >= 2 {
                                batchMergeItems = conversionManager.convertedPDFs.filter { multiSelection.contains($0.id) }
                                showingBatchMergeReorder = true
                            } else {
                                withAnimation { isBatchMode = true }
                                conversionManager.appAlert = AppAlert(title: "Select Issues", message: "Select 2 or more issues from your library, then tap Convert & Merge again.")
                            }
                        })
                        ActionPill(title: "Vault", icon: conversionManager.isVaultUnlocked ? "lock.open.fill" : "lock.fill", color: conversionManager.isVaultUnlocked ? Theme.orange : Theme.blue) { 
                            onVaultToggle() 
                        }
                    }
                    
                    // 3. Selection / Batch
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isBatchMode.toggle()
                            if !isBatchMode { multiSelection.removeAll() }
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.badge.questionmark")
                            Text(isBatchMode ? "Done" : "Select")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isBatchMode ? .white : Theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(isBatchMode ? AnyShapeStyle(Theme.orange) : AnyShapeStyle(.thickMaterial))
                        .clipShape(Capsule())
                    }
                    
                    if isBatchMode {
                        Button(action: {
                            onSelectAll?()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.square.fill")
                                Text("All")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.blue)
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
        }
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.05)),
            alignment: .bottom
        )
    }
}
