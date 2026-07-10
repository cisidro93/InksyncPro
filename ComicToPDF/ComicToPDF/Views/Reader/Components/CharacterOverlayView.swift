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
                
                // Interactive Node Graph
                CharacterGraphView(
                    sourceCharacter: character,
                    allCharacters: characters,
                    allRelationships: relationships,
                    currentIssue: issueNumber,
                    currentPageIndex: pageIndex,
                    revealSpoilers: revealSpoilers,
                    selectedCharacter: $selectedCharacter
                )
                
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

// MARK: - Interactive Character Graph View
private struct CharacterGraphView: View {
    let sourceCharacter: SDCharacterNode
    let allCharacters: [SDCharacterNode]
    let allRelationships: [SDRelationship]
    let currentIssue: Int
    let currentPageIndex: Int
    let revealSpoilers: Bool
    
    @Binding var selectedCharacter: SDCharacterNode?
    
    // Resolve active relationships
    private var resolvedRelations: [(target: SDCharacterNode, type: String, isSpoiler: Bool)] {
        let active = allRelationships.filter {
            $0.sourceCharacterID == sourceCharacter.id || $0.targetCharacterID == sourceCharacter.id
        }
        
        return active.compactMap { relation in
            let isSource = relation.sourceCharacterID == sourceCharacter.id
            let targetID = isSource ? relation.targetCharacterID : relation.sourceCharacterID
            guard let target = allCharacters.first(where: { $0.id == targetID }) else { return nil }
            
            let isSpoiler = !revealSpoilers && (
                relation.visibleAfterIssueNumber > currentIssue ||
                (relation.visibleAfterIssueNumber == currentIssue && relation.visibleAfterPageIndex > currentPageIndex)
            )
            
            return (target: target, type: relation.type, isSpoiler: isSpoiler)
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            Text("Interactive Relationship Graph")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.purple.opacity(0.85))
                .tracking(1.0)
                .padding(.top, 14)
            
            if resolvedRelations.isEmpty {
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Text(String(sourceCharacter.name.first ?? "C"))
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))
                        )
                    Text("No relationships mapped for this issue progress.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(height: 240)
            } else {
                ZStack {
                    // Dashed vector connector lines
                    GeometryReader { geo in
                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let R: CGFloat = 100
                        
                        Path { path in
                            let count = resolvedRelations.count
                            for i in 0..<count {
                                let angle = Double(i) * (2.0 * .pi / Double(count)) - (.pi / 2.0)
                                let endPoint = CGPoint(
                                    x: center.x + R * CGFloat(cos(angle)),
                                    y: center.y + R * CGFloat(sin(angle))
                                )
                                path.move(to: center)
                                path.addLine(to: endPoint)
                            }
                        }
                        .stroke(
                            LinearGradient(
                                colors: [.purple.opacity(0.6), .blue.opacity(0.2)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        
                        // Small relationship text badges inside lines
                        let count = resolvedRelations.count
                        ForEach(0..<count, id: \.self) { i in
                            let relation = resolvedRelations[i]
                            let angle = Double(i) * (2.0 * .pi / Double(count)) - (.pi / 2.0)
                            let midPoint = CGPoint(
                                x: center.x + (R * 0.5) * CGFloat(cos(angle)),
                                y: center.y + (R * 0.5) * CGFloat(sin(angle))
                            )
                            
                            HStack(spacing: 2) {
                                if relation.isSpoiler {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8))
                                }
                                Text(relation.isSpoiler ? "Locked" : relation.type.capitalized)
                            }
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(relation.isSpoiler ? Color.orange.opacity(0.9) : Color.purple.opacity(0.85))
                            )
                            .foregroundColor(.white)
                            .position(midPoint)
                        }
                    }
                    
                    // Circular nodes layer
                    GeometryReader { geo in
                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let R: CGFloat = 100
                        
                        // Center Node (selectedCharacter)
                        NodeView(character: sourceCharacter, isCenter: true, isSpoiler: false)
                            .position(center)
                        
                        // Surrounding Nodes
                        let count = resolvedRelations.count
                        ForEach(0..<count, id: \.self) { i in
                            let relation = resolvedRelations[i]
                            let angle = Double(i) * (2.0 * .pi / Double(count)) - (.pi / 2.0)
                            let nodePoint = CGPoint(
                                x: center.x + R * CGFloat(cos(angle)),
                                y: center.y + R * CGFloat(sin(angle))
                            )
                            
                            Button {
                                if !relation.isSpoiler {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        selectedCharacter = relation.target
                                    }
                                    HapticEngine.light()
                                }
                            } label: {
                                NodeView(character: relation.target, isCenter: false, isSpoiler: relation.isSpoiler)
                            }
                            .buttonStyle(.plain)
                            .disabled(relation.isSpoiler)
                            .position(nodePoint)
                        }
                    }
                }
                .frame(height: 240)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

private struct NodeView: View {
    let character: SDCharacterNode
    let isCenter: Bool
    let isSpoiler: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isCenter ? [.purple, .blue] : [.white.opacity(0.08), .white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: isCenter ? 52 : 38, height: isCenter ? 52 : 38)
                    .shadow(color: isCenter ? .purple.opacity(0.4) : .clear, radius: 6)
                    .overlay(
                        Circle()
                            .stroke(isCenter ? Color.white.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
                    )
                
                if isSpoiler {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                } else {
                    Text(String(character.name.first ?? "C"))
                        .font(.system(size: isCenter ? 18 : 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            
            Text(isSpoiler ? "Locked Relation" : character.name.components(separatedBy: " ").first ?? character.name)
                .font(.system(size: 9, weight: isCenter ? .bold : .medium, design: .rounded))
                .foregroundColor(isSpoiler ? .orange.opacity(0.85) : .white)
                .lineLimit(1)
                .frame(width: 80)
        }
    }
}
