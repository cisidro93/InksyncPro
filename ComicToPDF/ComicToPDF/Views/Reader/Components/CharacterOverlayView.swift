import SwiftUI
import SwiftData

struct CharacterOverlayView: View {
    let seriesName: String
    let issueNumber: Int
    let pageIndex: Int
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // Fetch all characters
    @Query private var characters: [SDCharacterNode]
    @Query private var relationships: [SDRelationship]
    @Query private var appearances: [SDCharacterAppearance]
    
    @State private var selectedCharacter: SDCharacterNode?
    @State private var searchText = ""
    @State private var revealSpoilers = false
    
    // Dynamic page-level detection (Layer 1)
    private var detectedCharacters: [SDCharacterNode] {
        // Query characters that appear on this page from database (Layer 1)
        let pageCharacterIDs = appearances
            .filter { $0.issueNumber == issueNumber && $0.pageIndex == pageIndex }
            .map { $0.characterID }
        
        return characters.filter { pageCharacterIDs.contains($0.id) }
    }
    
    // Searchable/general cast suggestion fallback (Layer 3)
    private var filteredSearchCharacters: [SDCharacterNode] {
        if searchText.isEmpty {
            return characters.filter { !detectedCharacters.contains($0) }
        } else {
            return characters.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header with Swipe-down bar & Spoilers reveal toggle
                headerView
                
                if let character = selectedCharacter {
                    // Character detail view (Dossier + Progress-locked Relations)
                    characterDetailView(for: character)
                } else {
                    // Active Cast list + Search Fallback
                    castSelectionListView
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            if selectedCharacter != nil {
                Button {
                    withAnimation { selectedCharacter = nil }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Cast")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.purple)
                }
            } else {
                Text("Page Context")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.text)
            }
            
            Spacer()
            
            // Spoiler override button
            Button {
                withAnimation { revealSpoilers.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: revealSpoilers ? "eye.fill" : "eye.slash.fill")
                    Text(revealSpoilers ? "Spoilers: On" : "Hide Spoilers")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(revealSpoilers ? Color.red.opacity(0.2) : Color.white.opacity(0.1), in: Capsule())
                .foregroundColor(revealSpoilers ? .red : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.08)), alignment: .bottom)
    }
    
    // MARK: - Cast Selection List
    private var castSelectionListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. Detected on Page Section
                Text("Characters on Page \(pageIndex + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.purple)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                
                if detectedCharacters.isEmpty {
                    // OCR Scanner call-to-action or empty prompt
                    HStack {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundColor(Theme.textSecondary)
                        Text("No mapped characters for this page.")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                } else {
                    ForEach(detectedCharacters) { character in
                        characterRow(for: character)
                    }
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.horizontal, 20)
                
                // 2. General Cast Search (Layer 3 Fallback)
                Text("Search Series Cast")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 20)
                
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Theme.textSecondary)
                    TextField("Wolverine, Cyclops...", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(Theme.text)
                }
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                
                ForEach(filteredSearchCharacters) { character in
                    characterRow(for: character)
                }
            }
            .padding(.bottom, 20)
        }
    }
    
    @ViewBuilder
    private func characterRow(for character: SDCharacterNode) -> some View {
        Button {
            withAnimation { selectedCharacter = character }
        } label: {
            HStack(spacing: 12) {
                // Avatar Placeholder
                Circle()
                    .fill(LinearGradient(colors: [.purple, .inkBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(character.name.first ?? "C"))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                    if let first = character.firstAppearanceIssue {
                        Text("First: \(first)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(Theme.textSecondary)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Character Detail (Dossier & Relations)
    @ViewBuilder
    private func characterDetailView(for character: SDCharacterNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Profile dossier
                HStack(spacing: 16) {
                    Circle()
                        .fill(LinearGradient(colors: [.purple, .inkBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Text(String(character.name.first ?? "C"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(character.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Theme.text)
                        if let first = character.firstAppearanceIssue {
                            Text("First Appearance: \(first)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                if let bio = character.bio {
                    Text(bio)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineSpacing(4)
                        .padding(.horizontal, 20)
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.horizontal, 20)
                
                // Relationship Graph List
                Text("Relationships (Spoiler-Safe)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.purple)
                    .padding(.horizontal, 20)
                
                let activeRelations = relationships.filter {
                    $0.sourceCharacterID == character.id || $0.targetCharacterID == character.id
                }
                
                if activeRelations.isEmpty {
                    Text("No known relationships mapped for this character.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 12) {
                        ForEach(activeRelations) { relation in
                            relationRow(for: relation, source: character)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 30)
        }
    }
    
    @ViewBuilder
    private func relationRow(for relation: SDRelationship, source: SDCharacterNode) -> some View {
        let isSource = relation.sourceCharacterID == source.id
        let targetID = isSource ? relation.targetCharacterID : relation.sourceCharacterID
        let targetNode = characters.first(where: { $0.id == targetID })
        
        let isSpoiler = !revealSpoilers && (
            relation.visibleAfterIssueNumber > issueNumber ||
            (relation.visibleAfterIssueNumber == issueNumber && relation.visibleAfterPageIndex > pageIndex)
        )
        
        HStack {
            if let target = targetNode {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 32, height: 32)
                    .overlay(Text(String(target.name.first ?? "C")).font(.system(size: 12, weight: .bold)))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    
                    if isSpoiler {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                            Text("Spoiler hidden (unlocks issue #\(relation.visibleAfterIssueNumber))")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color.inkAmber)
                    } else {
                        Text(relation.type)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
                
                if isSpoiler {
                    Button("Unlock") {
                        withAnimation { revealSpoilers = true }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.purple)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
