import SwiftUI
import SwiftData
import QuartzCore
import PencilKit

// MARK: - Data Models

enum GraphNodeType {
    case book, tag, note
}

struct GraphNode: Identifiable, Equatable {
    let id: String
    var position: CGPoint
    var velocity: CGVector = .zero
    let title: String
    let nodeType: GraphNodeType
    var connectionCount: Int = 1
    
    // Note specific metadata for HUD
    var fullText: String? = nil
    var userNote: String? = nil
    var bookTitle: String? = nil
    var colorHex: String? = nil
    var linkedNoteIDs: [String] = []

    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool { lhs.id == rhs.id }

    /// Visual dot radius
    var dotRadius: CGFloat {
        let base: CGFloat = 5.0
        let scale: CGFloat = 3.0
        return base + scale * CGFloat(log2(Double(connectionCount) + 1.0))
    }

    /// Hit-test radius
    var hitRadius: CGFloat { max(dotRadius * 1.5, 12) }
}

struct GraphEdge: Identifiable {
    let id: String
    let sourceID: String
    let targetID: String
}

// MARK: - Physics Engine

@MainActor
final class ZettelkastenGraphEngine: NSObject, ObservableObject {
    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var draggedNodeID: String? = nil
    /// Captured at the start of each pinch gesture — allows multiplicative scaling
    var pinchBaseScale: CGFloat = 1.0

    @Published var pathAnchorA: String? = nil
    @Published var pathAnchorB: String? = nil
    @Published var highlightedPathNodeIDs: Set<String> = []
    @Published var highlightedPathEdgeIDs: Set<String> = []

    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var tickCount: Int = 0

    // Physics tuning
    let repulsionStrength: Double = 7000.0
    let springStiffness: Double  = 0.022
    let springLength: Double     = 140.0
    let damping: Double          = 0.80
    let centerGravity: Double    = 0.015

    private var nodeIndex: [String: Int] = [:]

    private func rebuildNodeIndex() {
        nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
    }

    // MARK: Build Graph

    func buildGraph(
        from annotations: [SDAnnotation],
        pdfs: [SDConvertedPDF],
        showBooks: Bool,
        showTags: Bool,
        showNotes: Bool,
        searchText: String
    ) {
        var newNodes: [String: GraphNode] = [:]
        var newEdges: [GraphEdge] = []
        var connectionCounts: [String: Int] = [:]
        var edgeIDSet: Set<String> = []

        let screenCenter = CGPoint(
            x: UIScreen.main.bounds.width / 2,
            y: UIScreen.main.bounds.height / 2
        )

        var pdfNames: [UUID: String] = [:]
        for pdf in pdfs { pdfNames[pdf.id] = pdf.name }
        
        // Filter annotations based on search and basic visibility
        var targetAnnotations = annotations.filter { $0.kindRaw == "highlight" }
        
        if !searchText.isEmpty {
            targetAnnotations = targetAnnotations.filter {
                let text = $0.selectedText?.localizedCaseInsensitiveContains(searchText) ?? false
                let note = $0.noteText?.localizedCaseInsensitiveContains(searchText) ?? false
                let book = ($0.readwiseBookTitle ?? pdfNames[$0.pdfID] ?? "").localizedCaseInsensitiveContains(searchText)
                return text || note || book
            }
        }
        
        // Cap at 200 items for layout performance
        targetAnnotations = Array(targetAnnotations.prefix(200))
        
        func addEdge(source: String, target: String) {
            let edgeID = "\(source)_\(target)"
            let revEdge = "\(target)_\(source)"
            guard !edgeIDSet.contains(edgeID), !edgeIDSet.contains(revEdge) else { return }
            edgeIDSet.insert(edgeID)
            newEdges.append(GraphEdge(id: edgeID, sourceID: source, targetID: target))
            connectionCounts[source, default: 0] += 1
            connectionCounts[target, default: 0] += 1
        }
        
        var noteTags: [String: Set<String>] = [:]

        // 1. Map Annotations to nodes
        if showNotes {
            for ann in targetAnnotations {
                let annID = ann.id.uuidString
                let bookID = ann.pdfID.uuidString
                
                let bTitle: String
                if let rwTitle = ann.readwiseBookTitle, !rwTitle.isEmpty {
                    bTitle = rwTitle
                } else if let name = pdfNames[ann.pdfID] {
                    bTitle = name
                } else {
                    bTitle = "Book Snapshot"
                }
                
                // Create Book Node
                if showBooks && newNodes[bookID] == nil {
                    let angle = Double.random(in: 0..<2 * .pi)
                    let radius = Double.random(in: 80...220)
                    let pos = CGPoint(x: screenCenter.x + radius * cos(angle), y: screenCenter.y + radius * sin(angle))
                    newNodes[bookID] = GraphNode(id: bookID, position: pos, title: bTitle, nodeType: .book)
                }
                
                // Create Note Node
                let noteTitle = (ann.selectedText ?? ann.noteText ?? "Note").prefix(20).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
                let nAngle = Double.random(in: 0..<2 * .pi)
                let nRadius = Double.random(in: 140...280)
                let nPos = CGPoint(x: screenCenter.x + nRadius * cos(nAngle), y: screenCenter.y + nRadius * sin(nAngle))
                
                newNodes[annID] = GraphNode(
                    id: annID,
                    position: nPos,
                    title: String(noteTitle),
                    nodeType: .note,
                    fullText: ann.selectedText,
                    userNote: ann.noteText,
                    bookTitle: bTitle,
                    colorHex: ann.colorHex,
                    linkedNoteIDs: ann.linkedAnnotationIDs ?? []
                )
                
                // Link Note -> Book
                if showBooks {
                    addEdge(source: annID, target: bookID)
                }
                
                // Process Tags
                if showTags, let tags = ann.readwiseTags ?? ann.tags, !tags.isEmpty {
                    noteTags[annID] = Set(tags)
                    
                    for tag in tags.prefix(3) {
                        let tagID = "tag_\(tag.lowercased())"
                        if newNodes[tagID] == nil {
                            let tAngle = Double.random(in: 0..<2 * .pi)
                            let tRadius = Double.random(in: 160...320)
                            let tPos = CGPoint(x: screenCenter.x + tRadius * cos(tAngle), y: screenCenter.y + tRadius * sin(tAngle))
                            newNodes[tagID] = GraphNode(id: tagID, position: tPos, title: "#\(tag)", nodeType: .tag)
                        }
                        addEdge(source: annID, target: tagID)
                    }
                }
            }
        }
        
        // 2. Add user-defined linked annotation connections
        if showNotes {
            for ann in targetAnnotations {
                let annID = ann.id.uuidString
                if let linkedIDs = ann.linkedAnnotationIDs {
                    for destID in linkedIDs {
                        if newNodes[destID] != nil {
                            addEdge(source: annID, target: destID)
                        }
                    }
                }
            }
        }

        // 3. Connect co-occurring tags co-presence
        if showNotes && showTags {
            var tagToNotes: [String: [String]] = [:]
            for (noteID, tags) in noteTags {
                for tag in tags { tagToNotes[tag, default: []].append(noteID) }
            }
            var sharedTagCount: [String: Int] = [:]
            for notes in tagToNotes.values where notes.count > 1 {
                for i in 0..<notes.count {
                    for j in (i + 1)..<notes.count {
                        let pairKey = notes[i] < notes[j] ? "\(notes[i])|\(notes[j])" : "\(notes[j])|\(notes[i])"
                        sharedTagCount[pairKey, default: 0] += 1
                    }
                }
            }
            for (pairKey, count) in sharedTagCount where count >= 2 {
                let parts = pairKey.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let id1 = parts[0]; let id2 = parts[1]
                if let b1 = newNodes[id1]?.bookTitle, let b2 = newNodes[id2]?.bookTitle, b1 != b2 {
                    addEdge(source: id1, target: id2)
                }
            }
        }

        for key in newNodes.keys {
            newNodes[key]?.connectionCount = max(1, connectionCounts[key] ?? 1)
        }

        self.nodes = Array(newNodes.values)
        self.edges = newEdges
        rebuildNodeIndex()
        startSimulation()
    }

    // MARK: Simulation Loop

    func startSimulation() {
        stopSimulation()
        tickCount = 0
        displayLink = CADisplayLink(target: self, selector: #selector(physicsTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopSimulation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func physicsTick() {
        tickCount += 1
        var forces: [String: CGVector] = [:]
        for node in nodes { forces[node.id] = .zero }

        let center = CGPoint(
            x: UIScreen.main.bounds.width / 2,
            y: UIScreen.main.bounds.height / 2
        )

        // 1. Repulsion
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let n1 = nodes[i]; let n2 = nodes[j]
                let dx = n1.position.x - n2.position.x
                let dy = n1.position.y - n2.position.y
                let distSq = dx * dx + dy * dy
                guard distSq > 1, distSq < 150_000 else { continue }
                let dist = sqrt(distSq)
                let force = repulsionStrength / distSq
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[n1.id]?.dx += fx; forces[n1.id]?.dy += fy
                forces[n2.id]?.dx -= fx; forces[n2.id]?.dy -= fy
            }
        }

        // 2. Spring Attraction along edges
        for edge in edges {
            guard let i1 = nodeIndex[edge.sourceID],
                  let i2 = nodeIndex[edge.targetID],
                  i1 < nodes.count, i2 < nodes.count else { continue }
            let n1 = nodes[i1]; let n2 = nodes[i2]
            let dx = n2.position.x - n1.position.x
            let dy = n2.position.y - n1.position.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0 else { continue }
            let displacement = dist - springLength
            let force = springStiffness * displacement
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force
            forces[n1.id]?.dx += fx; forces[n1.id]?.dy += fy
            forces[n2.id]?.dx -= fx; forces[n2.id]?.dy -= fy
        }

        // 3. Center gravity & velocity integration
        for i in 0..<nodes.count {
            guard nodes[i].id != draggedNodeID else { continue }
            let dx = center.x - nodes[i].position.x
            let dy = center.y - nodes[i].position.y
            forces[nodes[i].id]?.dx += dx * centerGravity
            forces[nodes[i].id]?.dy += dy * centerGravity

            let f = forces[nodes[i].id]!
            let mass = Double(nodes[i].connectionCount) * 0.6 + 1.0
            nodes[i].velocity.dx = (nodes[i].velocity.dx + f.dx / mass) * damping
            nodes[i].velocity.dy = (nodes[i].velocity.dy + f.dy / mass) * damping

            let speedSq = nodes[i].velocity.dx * nodes[i].velocity.dx
                        + nodes[i].velocity.dy * nodes[i].velocity.dy
            let maxSpeed: Double = 35.0
            if speedSq > maxSpeed * maxSpeed {
                let speed = sqrt(speedSq)
                nodes[i].velocity.dx = (nodes[i].velocity.dx / speed) * maxSpeed
                nodes[i].velocity.dy = (nodes[i].velocity.dy / speed) * maxSpeed
            }
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }

        let threshold: Double = 0.35
        let isAsleep = nodes.allSatisfy {
            abs($0.velocity.dx) < threshold && abs($0.velocity.dy) < threshold
        }
        if (isAsleep || tickCount > 200) && draggedNodeID == nil { stopSimulation() }
    }

    deinit { displayLink?.invalidate() }
}

// MARK: - Canvas View

struct ZettelkastenGraphView: View {
    let annotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]

    @Environment(\.modelContext) private var modelContext
    @StateObject private var engine = ZettelkastenGraphEngine()
    @Environment(\.colorScheme) private var colorScheme

    // Filters and search
    @State private var showBooks = true
    @State private var showTags = true
    @State private var showNotes = true
    @State private var searchText = ""

    // Selection and Link drawing states
    @State private var selectedNodeID: String? = nil
    @State private var hoverNodeID: String? = nil
    @State private var isPanning = false
    @State private var canvasSize: CGSize = UIScreen.main.bounds.size

    // Link Mode parameters
    @State private var isLinkMode = false
    @State private var linkStartNodeID: String? = nil
    @State private var linkCurrentPoint: CGPoint? = nil

    // Sidebar Note editing state
    @State private var editingNoteText = ""

    // MARK: Theme styles

    private var bgColor: Color {
        colorScheme == .dark
            ? Color(hex: "#0F0F12") // deep black-charcoal
            : Color(hex: "#F5F5F7") // off-white
    }
    private var gridDotColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.04)
    }
    private var edgeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    private var edgeHoverColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.4)
    }
    private var labelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.7)
    }

    private func bookColor(_ alpha: CGFloat) -> Color { Color.inkAccentKnowledge.opacity(alpha) }
    private func tagColor(_ alpha: CGFloat) -> Color { Color.orange.opacity(alpha) }
    private func noteColor(_ alpha: CGFloat) -> Color { Color.green.opacity(alpha) }

    private func nodeFill(for node: GraphNode, alpha: CGFloat) -> Color {
        switch node.nodeType {
        case .book: return bookColor(alpha)
        case .tag: return tagColor(alpha)
        case .note:
            if let customHex = node.colorHex {
                return Color(hex: customHex).opacity(alpha)
            }
            return noteColor(alpha)
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            bgColor.ignoresSafeArea()

            // Visual Grid Dots
            Canvas { ctx, size in
                let spacing: CGFloat = 28
                for x in stride(from: 0, through: size.width, by: spacing) {
                    for y in stride(from: 0, through: size.height, by: spacing) {
                        let dot = CGRect(x: x - 1, y: y - 1, width: 1.5, height: 1.5)
                        ctx.fill(Path(ellipseIn: dot), with: .color(gridDotColor))
                    }
                }
            }
            .ignoresSafeArea()

            // Main Force Graph Canvas
            Canvas { context, size in
                canvasSize = size

                // Camera Transforms (Offset & Scale)
                context.translateBy(x: engine.offset.width + size.width / 2,
                                    y: engine.offset.height + size.height / 2)
                context.scaleBy(x: engine.scale, y: engine.scale)
                context.translateBy(x: -size.width / 2, y: -size.height / 2)

                // 1. Draw Edges
                for edge in engine.edges {
                    guard let src = engine.nodes.first(where: { $0.id == edge.sourceID }),
                          let tgt = engine.nodes.first(where: { $0.id == edge.targetID }) else { continue }

                    var path = Path()
                    path.move(to: src.position)
                    path.addLine(to: tgt.position)

                    let isAdjacentToHover = hoverNodeID == src.id || hoverNodeID == tgt.id
                    let isSelectedConnection = selectedNodeID == src.id || selectedNodeID == tgt.id

                    if isSelectedConnection {
                        context.stroke(path, with: .color(Color.pink.opacity(0.7)), lineWidth: 1.5)
                    } else if isAdjacentToHover {
                        context.stroke(path, with: .color(edgeHoverColor), lineWidth: 1.2)
                    } else {
                        context.stroke(path, with: .color(edgeColor), lineWidth: 0.6)
                    }
                }

                // 2. Draw Active Drag-Linking Line
                if isLinkMode,
                   let startID = linkStartNodeID,
                   let startNode = engine.nodes.first(where: { $0.id == startID }),
                   let currentPt = linkCurrentPoint {
                    var path = Path()
                    path.move(to: startNode.position)
                    path.addLine(to: currentPt)
                    context.stroke(
                        path,
                        with: .color(Color.pink.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 3])
                    )
                }

                // 3. Draw Nodes
                for node in engine.nodes {
                    let r = node.dotRadius
                    let rect = CGRect(
                        x: node.position.x - r,
                        y: node.position.y - r,
                        width: r * 2,
                        height: r * 2
                    )

                    let isSelected = selectedNodeID == node.id
                    let isHovered  = hoverNodeID == node.id
                    let isDimmed   = (hoverNodeID != nil && !isHovered) || (selectedNodeID != nil && !isSelected)

                    if isSelected {
                        // Core glowing halo
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.5, dy: -r * 0.5)),
                                     with: .color(Color.pink.opacity(0.18)))
                        context.fill(Path(ellipseIn: rect), with: .color(nodeFill(for: node, alpha: 1.0)))
                        context.stroke(Path(ellipseIn: rect), with: .color(Color.pink), lineWidth: 1.5)
                    } else if isHovered {
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.4, dy: -r * 0.4)),
                                     with: .color(nodeFill(for: node, alpha: 0.2)))
                        context.fill(Path(ellipseIn: rect), with: .color(nodeFill(for: node, alpha: 1.0)))
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.4)), lineWidth: 1.0)
                    } else {
                        let fill = isDimmed ? nodeFill(for: node, alpha: 0.2) : nodeFill(for: node, alpha: 0.85)
                        context.fill(Path(ellipseIn: rect), with: .color(fill))
                        if !isDimmed {
                            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.15)), lineWidth: 0.7)
                        }
                    }

                    // Render SF symbols inside nodes when zoomed in
                    if engine.scale > 0.65 && r > 6.5 {
                        let symbol: String
                        switch node.nodeType {
                        case .book: symbol = "book.closed.fill"
                        case .tag: symbol = "tag.fill"
                        case .note: symbol = "note.text"
                        }
                        
                        context.draw(
                            Text(Image(systemName: symbol))
                                .font(.system(size: r * 0.95))
                                .foregroundColor(.white.opacity(0.9)),
                            at: node.position
                        )
                    }

                    // Render labels
                    let showLabel = engine.scale > 0.45 && (isHovered || isSelected || (hoverNodeID == nil && selectedNodeID == nil && node.connectionCount >= 4))
                    if showLabel {
                        let truncated = node.title.count > 25
                            ? String(node.title.prefix(23)) + "…"
                            : node.title
                        let labelPt = CGPoint(x: node.position.x, y: node.position.y + r + 8)
                        let weight: Font.Weight = isSelected ? .bold : (node.connectionCount >= 8 ? .semibold : .regular)
                        context.draw(
                            Text(truncated)
                                .font(.system(size: 9.5, weight: weight))
                                .foregroundColor(isSelected ? Color.pink : labelColor),
                            at: labelPt
                        )
                    }
                }
            }
            .ignoresSafeArea()
            // Gestures
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let touchPos = applyInverseCamera(val.location)
                        
                        if isLinkMode {
                            // Link mode drawing phase
                            if linkStartNodeID == nil {
                                if let tapped = engine.nodes.first(where: {
                                    $0.nodeType == .note && distance(from: $0.position, to: touchPos) < $0.hitRadius
                                }) {
                                    linkStartNodeID = tapped.id
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                            linkCurrentPoint = touchPos
                        } else {
                            // Standard Panning or Node Dragging
                            if engine.draggedNodeID == nil {
                                if let tapped = engine.nodes.first(where: {
                                    distance(from: $0.position, to: touchPos) < $0.hitRadius
                                }) {
                                    guard !isPanning else { return }
                                    engine.draggedNodeID = tapped.id
                                    hoverNodeID = tapped.id
                                    selectedNodeID = tapped.id
                                    engine.startSimulation()
                                } else {
                                    // Empty area pan
                                    if val.translation.width * val.translation.width +
                                       val.translation.height * val.translation.height > 64 {
                                        isPanning = true
                                        hoverNodeID = nil
                                    }
                                    engine.offset.width += val.translation.width / engine.scale
                                    engine.offset.height += val.translation.height / engine.scale
                                }
                            }
                            
                            if let dragged = engine.draggedNodeID,
                               let idx = engine.nodes.firstIndex(where: { $0.id == dragged }) {
                                engine.nodes[idx].position = touchPos
                                engine.nodes[idx].velocity = .zero
                            }
                        }
                    }
                    .onEnded { val in
                        if isLinkMode {
                            if let startID = linkStartNodeID, let currentPt = linkCurrentPoint {
                                if let targetNode = engine.nodes.first(where: {
                                    $0.nodeType == .note && $0.id != startID && distance(from: $0.position, to: currentPt) < $0.hitRadius
                                }) {
                                    connectNodes(source: startID, target: targetNode.id)
                                }
                            }
                            linkStartNodeID = nil
                            linkCurrentPoint = nil
                        } else {
                            // Clear tap on empty canvas clears inspector
                            if !isPanning && engine.draggedNodeID == nil {
                                let touchPos = applyInverseCamera(val.location)
                                let hitNode = engine.nodes.first(where: {
                                    distance(from: $0.position, to: touchPos) < $0.hitRadius
                                })
                                if hitNode == nil {
                                    selectedNodeID = nil
                                    hoverNodeID = nil
                                }
                            }
                            engine.draggedNodeID = nil
                            isPanning = false
                        }
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        // Multiplicative: multiply the scale captured at gesture-start by the
                        // gesture's relative magnitude. This prevents scale jumping back to 1.0
                        // every time a new pinch begins (magnitude always starts near 1.0).
                        engine.scale = min(max(engine.pinchBaseScale * val.magnitude, 0.15), 4.0)
                    }
                    .onEnded { val in
                        engine.pinchBaseScale = engine.scale
                    }
            )

            // Canvas overlays (Filters, Controls, Sidebar)
            controlsLayer
            
            sidebarLayer
        }
        .onAppear { rebuildGraph() }
        .onDisappear { engine.stopSimulation() }
        .onChange(of: searchText) { _, _ in rebuildGraph() }
        .onChange(of: showNotes) { _, _ in rebuildGraph() }
        .onChange(of: showTags) { _, _ in rebuildGraph() }
        .onChange(of: showBooks) { _, _ in rebuildGraph() }
        .onChange(of: selectedNodeID) { _, newID in
            if let newID = newID,
               let node = engine.nodes.first(where: { $0.id == newID }),
               node.nodeType == .note {
                editingNoteText = node.userNote ?? ""
            } else {
                editingNoteText = ""
            }
        }
    }

    // MARK: - Floating Control Deck

    private var controlsLayer: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Search / Filter row
            HStack(spacing: 12) {
                // Search Field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.inkTextTertiary)
                    TextField("Search mind map...", text: $searchText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkTextPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
                .frame(width: 220)

                // Scope / Reset Zoom button
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        engine.scale = 1.0
                        engine.offset = .zero
                    }
                } label: {
                    Image(systemName: "scope")
                        .font(.subheadline.bold())
                        .foregroundColor(Color.inkAccentKnowledge)
                        .padding(8)
                        .background(Color.inkSurfaceRaised, in: Circle())
                        .overlay(Circle().strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
                }
            }
            .padding(.top, 16)
            .padding(.leading, 16)

            // Filtering capsules
            HStack(spacing: 8) {
                filterBadge(isOn: $showNotes, label: "Notes", color: noteColor(0.9))
                filterBadge(isOn: $showBooks, label: "Books", color: bookColor(0.9))
                filterBadge(isOn: $showTags, label: "Tags", color: tagColor(0.9))
            }
            .padding(.leading, 16)

            Spacer()

            // Floating canvas tools (zoom + Link Mode toggle)
            VStack(spacing: 8) {
                Button {
                    withAnimation { engine.scale = min(engine.scale + 0.25, 4.0) }
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.bold())
                        .foregroundColor(Color.inkTextPrimary)
                        .frame(width: 38, height: 38)
                        .background(Color.inkSurfaceRaised)
                }

                Button {
                    withAnimation { engine.scale = max(engine.scale - 0.25, 0.15) }
                } label: {
                    Image(systemName: "minus")
                        .font(.subheadline.bold())
                        .foregroundColor(Color.inkTextPrimary)
                        .frame(width: 38, height: 38)
                        .background(Color.inkSurfaceRaised)
                }

                Divider()
                    .frame(width: 38)

                // Link Mode toggle (renders glowing pink when active)
                Button {
                    isLinkMode.toggle()
                    if isLinkMode {
                        selectedNodeID = nil
                        hoverNodeID = nil
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Image(systemName: isLinkMode ? "link.badge.plus" : "link")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(isLinkMode ? .white : Color.inkAccentKnowledge)
                        .frame(width: 38, height: 38)
                        .background(isLinkMode ? Color.pink : Color.inkSurfaceRaised)
                }
            }
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
            .padding(.leading, 16)
            .padding(.bottom, 24)
        }
    }

    private func filterBadge(isOn: Binding<Bool>, label: String, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn.wrappedValue ? color : Color.inkTextTertiary)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isOn.wrappedValue ? Color.inkTextPrimary : Color.inkTextTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn.wrappedValue ? Color.inkSurfaceRaised : Color.inkBackground.opacity(0.4), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn.wrappedValue ? Color.inkBorderSubtle : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slide-In Sidebar Note Inspector

    private var sidebarLayer: some View {
        Group {
            if let selectedID = selectedNodeID,
               let node = engine.nodes.first(where: { $0.id == selectedID }) {
                HStack(spacing: 0) {
                    Spacer()
                    sidebarInspector(for: node)
                        .frame(width: 320)
                        .background(Color.inkSurfaceRaised)
                        .overlay(
                            Rectangle()
                                .fill(Color.inkBorderSubtle)
                                .frame(width: 0.5)
                                .frame(maxHeight: .infinity),
                            alignment: .leading
                        )
                        .transition(.move(edge: .trailing))
                        .shadow(color: Color.black.opacity(0.12), radius: 15, x: -8, y: 0)
                }
                .zIndex(100)
            }
        }
    }

    private func sidebarInspector(for node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack {
                Text(node.nodeType == .note ? "Zettel Note" : (node.nodeType == .book ? "Book Source" : "Tag Group"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkTextPrimary)
                Spacer()
                Button {
                    withAnimation { selectedNodeID = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.inkTextTertiary)
                }
            }
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title/Source Info
                    VStack(alignment: .leading, spacing: 4) {
                        Label(node.nodeType == .note ? "Highlight Source" : "Title", systemImage: "info.circle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.inkTextTertiary)
                        Text(node.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.inkTextPrimary)
                            .lineLimit(2)
                        
                        if let book = node.bookTitle {
                            Text("From: \(book)")
                                .font(.caption)
                                .foregroundStyle(Color.inkTextSecondary)
                        }
                    }

                    if node.nodeType == .note {
                        // Serif Highlight Text
                        if let fullText = node.fullText, !fullText.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected Text")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.inkTextTertiary)
                                Text("\"\(fullText)\"")
                                    .font(.system(size: 13, weight: .regular, design: .serif))
                                    .lineSpacing(4)
                                    .foregroundStyle(Color.inkTextSecondary)
                                    .padding(10)
                                    .background(Color.inkBackground.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        // Auto-saving Note TextEditor
                        VStack(alignment: .leading, spacing: 6) {
                            Label("User Note (Auto-Saves)", systemImage: "pencil")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.inkTextTertiary)
                            TextEditor(text: $editingNoteText)
                                .font(.system(size: 13))
                                .frame(height: 90)
                                .padding(8)
                                .background(Color.inkBackground, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
                                .onChange(of: editingNoteText) { _, newText in
                                    updateAnnotationNote(node.id, newNote: newText)
                                }
                        }

                        // Custom Connections lists (Disconnect capability)
                        let linkedNotes = getConnectedNoteNodes(for: node)
                        if !linkedNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Linked Annotation Connections", systemImage: "point.3.connected.trianglepath.dotted")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.inkTextTertiary)
                                
                                ForEach(linkedNotes) { conn in
                                    HStack {
                                        Text(conn.title)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .foregroundStyle(Color.inkTextPrimary)
                                        Spacer()
                                        Button {
                                            disconnectNodes(nodeA: node.id, nodeB: conn.id)
                                        } label: {
                                            Image(systemName: "link.badge.plus")
                                                .font(.caption2)
                                                .foregroundColor(Color.red)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(Color.inkBackground.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        // Sidebar Action buttons
                        VStack(spacing: 8) {
                            Button {
                                isLinkMode = true
                                linkStartNodeID = node.id
                                selectedNodeID = nil
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } label: {
                                Label("Link this node to another...", systemImage: "link.badge.plus")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.pink, in: RoundedRectangle(cornerRadius: 8))
                            }
                            
                            if let uuid = UUID(uuidString: node.id),
                               let matchedPDF = pdfs.first(where: { $0.id == annotations.first(where: { $0.id == uuid })?.pdfID }) {
                                Button {
                                    // Jump to reader
                                    let ann = annotations.first(where: { $0.id == uuid })
                                    AppRouter.shared.presentFullScreen(.read(matchedPDF))
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("Reader_JumpToPage"),
                                            object: nil,
                                            userInfo: ["pageIndex": ann?.pageIndex ?? 0]
                                        )
                                    }
                                } label: {
                                    Label("Open in Reader", systemImage: "book.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.inkAccentKnowledge)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.inkAccentKnowledge.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.inkAccentKnowledge.opacity(0.25), lineWidth: 0.5))
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
        }
        .padding(20)
    }

    // MARK: - Model Updates

    private func updateAnnotationNote(_ idString: String, newNote: String) {
        guard let uuid = UUID(uuidString: idString) else { return }
        let fetchDescriptor = FetchDescriptor<SDAnnotation>()
        if let all = try? modelContext.fetch(fetchDescriptor),
           let target = all.first(where: { $0.id == uuid }) {
            target.noteText = newNote
            target.modifiedAt = Date()
            try? modelContext.save()
        }
    }

    private func connectNodes(source: String, target: String) {
        guard let uuidSource = UUID(uuidString: source),
              let uuidTarget = UUID(uuidString: target) else { return }

        let fetchDescriptor = FetchDescriptor<SDAnnotation>()
        if let all = try? modelContext.fetch(fetchDescriptor) {
            let annSource = all.first(where: { $0.id == uuidSource })
            let annTarget = all.first(where: { $0.id == uuidTarget })

            if let annSource = annSource, let annTarget = annTarget {
                var linksSource = annSource.linkedAnnotationIDs ?? []
                if !linksSource.contains(target) {
                    linksSource.append(target)
                    annSource.linkedAnnotationIDs = linksSource
                }

                var linksTarget = annTarget.linkedAnnotationIDs ?? []
                if !linksTarget.contains(source) {
                    linksTarget.append(source)
                    annTarget.linkedAnnotationIDs = linksTarget
                }

                try? modelContext.save()
                
                // Rebuild locally
                rebuildGraph()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func disconnectNodes(nodeA: String, nodeB: String) {
        guard let uuidA = UUID(uuidString: nodeA),
              let uuidB = UUID(uuidString: nodeB) else { return }

        let fetchDescriptor = FetchDescriptor<SDAnnotation>()
        if let all = try? modelContext.fetch(fetchDescriptor) {
            let annA = all.first(where: { $0.id == uuidA })
            let annB = all.first(where: { $0.id == uuidB })

            if let annA = annA {
                var links = annA.linkedAnnotationIDs ?? []
                links.removeAll(where: { $0 == nodeB })
                annA.linkedAnnotationIDs = links
            }
            if let annB = annB {
                var links = annB.linkedAnnotationIDs ?? []
                links.removeAll(where: { $0 == nodeA })
                annB.linkedAnnotationIDs = links
            }

            try? modelContext.save()
            
            // Rebuild locally
            rebuildGraph()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func getConnectedNoteNodes(for node: GraphNode) -> [GraphNode] {
        let links = node.linkedNoteIDs
        return engine.nodes.filter { $0.nodeType == .note && links.contains($0.id) }
    }

    private func rebuildGraph() {
        engine.buildGraph(
            from: annotations,
            pdfs: pdfs,
            showBooks: showBooks,
            showTags: showTags,
            showNotes: showNotes,
            searchText: searchText
        )
    }

    // MARK: - Helpers

    private func applyInverseCamera(_ point: CGPoint) -> CGPoint {
        let size = canvasSize.width > 0 ? canvasSize : UIScreen.main.bounds.size
        var p = point
        p.x -= size.width / 2; p.y -= size.height / 2
        p.x /= engine.scale;   p.y /= engine.scale
        p.x -= engine.offset.width; p.y -= engine.offset.height
        p.x += size.width / 2;  p.y += size.height / 2
        return p
    }

    private func distance(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
        let dx = p1.x - p2.x; let dy = p1.y - p2.y
        return sqrt(dx * dx + dy * dy)
    }
}
