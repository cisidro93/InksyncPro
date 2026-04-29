import SwiftUI
import SwiftData
import QuartzCore

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

    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool { lhs.id == rhs.id }

    /// Visual dot radius — logarithmic scale keeps highly-connected hubs visible
    /// without dominating the canvas the way a linear mapping does.
    /// Base 4pt for isolated nodes, up to ~14pt for the most-connected hubs.
    var dotRadius: CGFloat {
        let base: CGFloat = 4.0
        let scale: CGFloat = 2.8
        return base + scale * CGFloat(log2(Double(connectionCount) + 1.0))
    }

    /// Hit-test radius is larger than the visual dot so fingers can tap easily.
    var hitRadius: CGFloat { max(dotRadius * 2.2, 18) }
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

    @Published var pathAnchorA: String? = nil
    @Published var pathAnchorB: String? = nil
    @Published var highlightedPathNodeIDs: Set<String> = []
    @Published var highlightedPathEdgeIDs: Set<String> = []

    private var displayLink: CADisplayLink?
    private var tickCount: Int = 0

    // ── Physics tuning ──────────────────────────────────────────────────────
    // Stronger repulsion + shorter spring → nodes settle further apart,
    // recreating the airy-but-connected look of Recall / Obsidian.
    let repulsionStrength: Double = 6000.0
    let springStiffness: Double  = 0.018
    let springLength: Double     = 160.0
    let damping: Double          = 0.82
    let centerGravity: Double    = 0.012

    override init() { super.init() }

    // MARK: Build

    func buildGraph(from annotations: [SDAnnotation], pdfs: [SDConvertedPDF]) {
        var newNodes: [String: GraphNode] = [:]
        var newEdges: [GraphEdge] = []
        var connectionCounts: [String: Int] = [:]

        let screenCenter = CGPoint(x: UIScreen.main.bounds.width / 2,
                                   y: UIScreen.main.bounds.height / 2)

        var pdfNames: [UUID: String] = [:]
        for pdf in pdfs { pdfNames[pdf.id] = pdf.name }
        
        // 1. Process Annotations as Nodes
        // Limit to 250 most recent/relevant annotations to prevent Canvas death on large datasets
        let targetAnnotations = Array(annotations.prefix(250))
        
        // Helper to safely add an edge
        func addEdge(source: String, target: String) {
            let edgeID = "\(source)_\(target)"
            let revEdge = "\(target)_\(source)"
            if !newEdges.contains(where: { $0.id == edgeID || $0.id == revEdge }) {
                newEdges.append(GraphEdge(id: edgeID, sourceID: source, targetID: target))
                connectionCounts[source, default: 0] += 1
                connectionCounts[target, default: 0] += 1
            }
        }
        
        // Semantic Link processing
        var noteTags: [String: Set<String>] = [:]

        for ann in targetAnnotations {
            let annID = ann.id.uuidString
            let bookID = ann.pdfID.uuidString
            
            let bTitle: String
            if let rwTitle = ann.readwiseBookTitle, !rwTitle.isEmpty {
                bTitle = rwTitle
            } else if let name = pdfNames[ann.pdfID] {
                bTitle = name
            } else {
                bTitle = "Unknown Book"
            }
            
            // Create Book Node
            if newNodes[bookID] == nil {
                let angle = Double.random(in: 0..<2 * .pi)
                let radius = Double.random(in: 80...280)
                let pos = CGPoint(x: screenCenter.x + radius * cos(angle), y: screenCenter.y + radius * sin(angle))
                newNodes[bookID] = GraphNode(id: bookID, position: pos, title: bTitle, nodeType: .book)
            }
            
            // Create Note Node
            let noteTitle = (ann.selectedText ?? ann.noteText ?? "Note").prefix(24).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
            let nAngle = Double.random(in: 0..<2 * .pi)
            let nRadius = Double.random(in: 120...320)
            let nPos = CGPoint(x: screenCenter.x + nRadius * cos(nAngle), y: screenCenter.y + nRadius * sin(nAngle))
            
            newNodes[annID] = GraphNode(id: annID, position: nPos, title: String(noteTitle), nodeType: .note, fullText: ann.selectedText, userNote: ann.noteText, bookTitle: bTitle, colorHex: ann.colorHex)
            
            // Link Note -> Book
            addEdge(source: annID, target: bookID)
            
            // Process Tags
            if let tags = ann.readwiseTags ?? ann.tags, !tags.isEmpty {
                noteTags[annID] = Set(tags)
                
                for tag in tags.prefix(3) {
                    let tagID = "tag_\(tag.lowercased())"
                    if newNodes[tagID] == nil {
                        let tAngle = Double.random(in: 0..<2 * .pi)
                        let tRadius = Double.random(in: 150...350)
                        let tPos = CGPoint(x: screenCenter.x + tRadius * cos(tAngle), y: screenCenter.y + tRadius * sin(tAngle))
                        newNodes[tagID] = GraphNode(id: tagID, position: tPos, title: "#\(tag)", nodeType: .tag)
                    }
                    // Link Note -> Tag
                    addEdge(source: annID, target: tagID)
                }
            }
        }
        
        // 2. Semantic Linking (Bi-directional Edges between Notes sharing multiple tags)
        let noteIDs = Array(noteTags.keys)
        for i in 0..<noteIDs.count {
            for j in (i + 1)..<noteIDs.count {
                let id1 = noteIDs[i]
                let id2 = noteIDs[j]
                
                // Don't semantically link notes from the exact same book (they are already linked via the book node)
                if let b1 = newNodes[id1]?.bookTitle, let b2 = newNodes[id2]?.bookTitle, b1 != b2 {
                    let shared = noteTags[id1]!.intersection(noteTags[id2]!)
                    if shared.count >= 2 { // Semantic threshold: 2 shared tags
                        addEdge(source: id1, target: id2)
                    }
                }
            }
        }

        for key in newNodes.keys {
            newNodes[key]?.connectionCount = max(1, connectionCounts[key] ?? 1)
        }

        self.nodes = Array(newNodes.values)
        self.edges = newEdges
        startSimulation()
    }

    // MARK: Simulation

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

        let center = CGPoint(x: UIScreen.main.bounds.width / 2,
                             y: UIScreen.main.bounds.height / 2)

        // 1. Repulsion (Barnes-Hut approximation not needed under ~300 nodes)
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let n1 = nodes[i]; let n2 = nodes[j]
                let dx = n1.position.x - n2.position.x
                let dy = n1.position.y - n2.position.y
                let distSq = dx * dx + dy * dy
                guard distSq > 1, distSq < 160_000 else { continue }
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
            guard let i1 = nodes.firstIndex(where: { $0.id == edge.sourceID }),
                  let i2 = nodes.firstIndex(where: { $0.id == edge.targetID }) else { continue }
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

        // 3. Weak center gravity + velocity integration
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

            // Cap velocity
            let speedSq = nodes[i].velocity.dx * nodes[i].velocity.dx
                        + nodes[i].velocity.dy * nodes[i].velocity.dy
            let maxSpeed: Double = 40.0
            if speedSq > maxSpeed * maxSpeed {
                let speed = sqrt(speedSq)
                nodes[i].velocity.dx = (nodes[i].velocity.dx / speed) * maxSpeed
                nodes[i].velocity.dy = (nodes[i].velocity.dy / speed) * maxSpeed
            }
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }

        // Auto-sleep once settled (also stops after 600 ticks ~10s as a safety net)
        let threshold: Double = 0.3
        let isAsleep = nodes.allSatisfy {
            abs($0.velocity.dx) < threshold && abs($0.velocity.dy) < threshold
        }
        if (isAsleep || tickCount > 600) && draggedNodeID == nil { stopSimulation() }
    }

    // MARK: Path Finding (BFS shortest path)

    func setPathAnchor(_ nodeID: String) {
        if pathAnchorA == nil {
            pathAnchorA = nodeID
            pathAnchorB = nil
            highlightedPathNodeIDs = [nodeID]
            highlightedPathEdgeIDs = []
        } else if pathAnchorB == nil, nodeID != pathAnchorA {
            pathAnchorB = nodeID
            computeShortestPath()
        } else {
            pathAnchorA = nodeID
            pathAnchorB = nil
            highlightedPathNodeIDs = [nodeID]
            highlightedPathEdgeIDs = []
        }
    }

    func clearPath() {
        pathAnchorA = nil; pathAnchorB = nil
        highlightedPathNodeIDs = []; highlightedPathEdgeIDs = []
    }

    private func computeShortestPath() {
        guard let src = pathAnchorA, let dst = pathAnchorB else { return }
        var adj: [String: [(nodeID: String, edgeID: String)]] = [:]
        for edge in edges {
            adj[edge.sourceID, default: []].append((edge.targetID, edge.id))
            adj[edge.targetID, default: []].append((edge.sourceID, edge.id))
        }
        var visited: Set<String> = [src]
        var queue: [(nodeID: String, path: [String], edgePath: [String])] = [(src, [src], [])]
        var foundNodePath: [String] = []
        var foundEdgePath: [String] = []
        while !queue.isEmpty {
            let (current, nodePath, edgePath) = queue.removeFirst()
            if current == dst { foundNodePath = nodePath; foundEdgePath = edgePath; break }
            for neighbor in adj[current] ?? [] {
                if !visited.contains(neighbor.nodeID) {
                    visited.insert(neighbor.nodeID)
                    queue.append((neighbor.nodeID, nodePath + [neighbor.nodeID], edgePath + [neighbor.edgeID]))
                }
            }
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            highlightedPathNodeIDs = Set(foundNodePath)
            highlightedPathEdgeIDs = Set(foundEdgePath)
        }
    }

    deinit { displayLink?.invalidate() }
}

// MARK: - Canvas View

struct ZettelkastenGraphView: View {
    let annotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]

    @StateObject private var engine = ZettelkastenGraphEngine()
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoverNodeID: String? = nil
    @State private var canvasSize: CGSize = UIScreen.main.bounds.size
    @State private var labelScale: CGFloat = 1.0  // zoomed-in label suppression

    // MARK: Theme colors

    private var bgColor: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.12)   // deep charcoal
            : Color(red: 0.96, green: 0.96, blue: 0.97)   // near-white
    }
    private var gridDotColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.05)
    }
    private var edgeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
    private var edgeHoverColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55)
    }
    private var labelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.80) : Color.black.opacity(0.78)
    }
    private var hudFg: Color {
        colorScheme == .dark ? .white.opacity(0.60) : .black.opacity(0.55)
    }

    // ── Recall-style dot colors: filled inner core + subtle outer ring ───────
    private func bookFill(_ alpha: CGFloat) -> Color {
        (colorScheme == .dark
            ? Color(red: 0.42, green: 0.68, blue: 1.00)   // soft blue
            : Color(red: 0.20, green: 0.48, blue: 0.90))
        .opacity(alpha)
    }
    private func tagFill(_ alpha: CGFloat) -> Color {
        (colorScheme == .dark
            ? Color(red: 1.00, green: 0.72, blue: 0.30)   // warm amber
            : Color(red: 0.85, green: 0.48, blue: 0.10))
        .opacity(alpha)
    }
    private func noteFill(_ alpha: CGFloat) -> Color {
        (colorScheme == .dark
            ? Color(red: 0.60, green: 0.85, blue: 0.40)   // soft green
            : Color(red: 0.30, green: 0.75, blue: 0.20))
        .opacity(alpha)
    }
    
    private func nodeFill(for node: GraphNode, alpha: CGFloat) -> Color {
        switch node.nodeType {
        case .tag: return tagFill(alpha)
        case .book: return bookFill(alpha)
        case .note: 
            if let customHex = node.colorHex {
                return Color(hex: customHex).opacity(alpha)
            }
            return noteFill(alpha)
        }
    }

    private var isPathMode: Bool { engine.pathAnchorA != nil }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            bgColor.ignoresSafeArea()

            // Background grid dots (matches Recall aesthetic)
            Canvas { ctx, size in
                let spacing: CGFloat = 28
                for x in stride(from: 0, through: size.width, by: spacing) {
                    for y in stride(from: 0, through: size.height, by: spacing) {
                        let dot = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                        ctx.fill(Path(ellipseIn: dot), with: .color(gridDotColor))
                    }
                }
            }
            .ignoresSafeArea()

            // Main force-directed graph
            Canvas { context, size in
                canvasSize = size
                labelScale = engine.scale

                // Camera
                context.translateBy(x: engine.offset.width + size.width / 2,
                                    y: engine.offset.height + size.height / 2)
                context.scaleBy(x: engine.scale, y: engine.scale)
                context.translateBy(x: -size.width / 2, y: -size.height / 2)

                let pathActive = !engine.highlightedPathEdgeIDs.isEmpty

                // ──────────────────────── EDGES ──────────────────────────────
                for edge in engine.edges {
                    guard let src = engine.nodes.first(where: { $0.id == edge.sourceID }),
                          let tgt = engine.nodes.first(where: { $0.id == edge.targetID }) else { continue }

                    var path = Path()
                    path.move(to: src.position)
                    path.addLine(to: tgt.position)

                    let isOnPath = engine.highlightedPathEdgeIDs.contains(edge.id)
                    let isAdjacentToHover = hoverNodeID == src.id || hoverNodeID == tgt.id

                    if pathActive {
                        if isOnPath {
                            // Glowing highlighted path
                            context.stroke(path, with: .color(Color.cyan.opacity(0.20)), lineWidth: 5)
                            context.stroke(path, with: .color(Color.cyan.opacity(0.90)), lineWidth: 1.5)
                        } else {
                            context.stroke(path, with: .color(edgeColor.opacity(0.08)), lineWidth: 0.5)
                        }
                    } else if isAdjacentToHover {
                        context.stroke(path, with: .color(edgeHoverColor), lineWidth: 1.5)
                    } else {
                        // Hairline edges — matches Recall/Obsidian feel
                        context.stroke(path, with: .color(edgeColor), lineWidth: 0.7)
                    }
                }

                // ──────────────────────── NODES ──────────────────────────────
                for node in engine.nodes {
                    let r = node.dotRadius
                    let rect = CGRect(x: node.position.x - r, y: node.position.y - r,
                                      width: r * 2, height: r * 2)

                    let isOnPath  = engine.highlightedPathNodeIDs.contains(node.id)
                    let isAnchor  = node.id == engine.pathAnchorA || node.id == engine.pathAnchorB
                    let isHovered = hoverNodeID == node.id
                    let isDimmed  = hoverNodeID != nil && !isHovered

                    if pathActive {
                        if isAnchor {
                            // Soft glow ring
                            context.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.8, dy: -r * 0.8)),
                                         with: .color(Color.cyan.opacity(0.18)))
                            // Inner core
                            context.fill(Path(ellipseIn: rect), with: .color(Color.cyan))
                            context.stroke(Path(ellipseIn: rect),
                                           with: .color(Color.white.opacity(0.9)), lineWidth: 1.5)
                        } else if isOnPath {
                            context.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.5, dy: -r * 0.5)),
                                         with: .color(Color.cyan.opacity(0.12)))
                            context.fill(Path(ellipseIn: rect), with: .color(nodeFill(for: node, alpha: 1.0)))
                            context.stroke(Path(ellipseIn: rect),
                                           with: .color(Color.cyan.opacity(0.9)), lineWidth: 1.2)
                        } else {
                            context.fill(Path(ellipseIn: rect), with: .color(nodeFill(for: node, alpha: 0.12)))
                        }
                    } else if isHovered {
                        // Hover: add a soft halo ring then solid core
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.6, dy: -r * 0.6)),
                                     with: .color(nodeFill(for: node, alpha: 0.20)))
                        context.fill(Path(ellipseIn: rect), with: .color(nodeFill(for: node, alpha: 1.0)))
                        context.stroke(Path(ellipseIn: rect),
                                       with: .color(colorScheme == .dark ? .white.opacity(0.5) : .black.opacity(0.3)),
                                       lineWidth: 1.0)
                    } else {
                        // Normal: solid core, tiny stroke ring — just like Recall dots
                        let fill = isDimmed ? nodeFill(for: node, alpha: 0.25) : nodeFill(for: node, alpha: 0.90)
                        context.fill(Path(ellipseIn: rect), with: .color(fill))
                        if !isDimmed {
                            // Very subtle outer stroke keeps dots from blending into edges
                            let strokeAlpha: CGFloat = colorScheme == .dark ? 0.18 : 0.20
                            context.stroke(Path(ellipseIn: rect),
                                           with: .color(Color.white.opacity(strokeAlpha)), lineWidth: 0.8)
                        }
                    }

                    // ─── Labels ─────────────────────────────────────────────
                    // Show label if: on path/anchor; or hovered; or highly connected and nothing else hovered.
                    // Hide at high zoom-out (scale < 0.5) to prevent a wall of unreadable text.
                    let scaleOK = engine.scale > 0.45
                    let showLabel = scaleOK && (
                        pathActive ? (isOnPath || isAnchor) :
                        (isHovered || (hoverNodeID == nil && node.connectionCount >= 5))
                    )

                    if showLabel {
                        let truncated = node.title.count > 28
                            ? String(node.title.prefix(26)) + "…"
                            : node.title
                        let labelPt = CGPoint(x: node.position.x, y: node.position.y + r + 9)
                        let weight: Font.Weight = node.connectionCount >= 10 ? .semibold : .regular
                        context.draw(
                            Text(truncated)
                                .font(.system(size: 9.5, weight: weight))
                                .foregroundColor(isAnchor ? .cyan : labelColor),
                            at: labelPt
                        )
                    }
                }
            }
            // MARK: Gestures
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        if case .second(true, let drag?) = value {
                            let touchPos = applyInverseCamera(drag.startLocation)
                            if let tapped = engine.nodes.first(where: {
                                distance(from: $0.position, to: touchPos) < $0.hitRadius
                            }) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    engine.setPathAnchor(tapped.id)
                                }
                            }
                        }
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let touchPos = applyInverseCamera(val.location)
                        if engine.draggedNodeID == nil {
                            if let tapped = engine.nodes.first(where: {
                                distance(from: $0.position, to: touchPos) < $0.hitRadius
                            }) {
                                engine.draggedNodeID = tapped.id
                                hoverNodeID = tapped.id
                                engine.startSimulation()
                            } else {
                                hoverNodeID = nil
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
                    .onEnded { _ in
                        engine.draggedNodeID = nil
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        engine.scale = min(max(val.magnitude, 0.1), 5.0)
                    }
            )

            // MARK: HUD — bottom left stat pill (matches Recall)
            VStack(alignment: .leading, spacing: 8) {
                if isPathMode {
                    HStack(spacing: 8) {
                        if engine.pathAnchorA != nil && engine.pathAnchorB == nil {
                            Label("Long-press second node to trace path", systemImage: "hand.tap")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial).clipShape(Capsule())
                        }
                        Button { withAnimation { engine.clearPath() } } label: {
                            Label("Clear Path", systemImage: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial).clipShape(Capsule())
                        }
                    }
                }

                // Stat pill
                HStack(spacing: 5) {
                    Circle().fill(bookFill(0.9)).frame(width: 7, height: 7)
                    Text("\(engine.nodes.filter { $0.nodeType == .book }.count) books")
                        .font(.system(size: 11, weight: .medium))
                    Circle().fill(tagFill(0.9)).frame(width: 7, height: 7)
                    Text("\(engine.nodes.filter { $0.nodeType == .tag }.count) tags")
                        .font(.system(size: 11, weight: .medium))
                    Circle().fill(noteFill(0.9)).frame(width: 7, height: 7)
                    Text("\(engine.nodes.filter { $0.nodeType == .note }.count) notes")
                        .font(.system(size: 11, weight: .medium))
                    Text("·").foregroundColor(hudFg)
                    Text("\(engine.edges.count) links")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(hudFg)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .padding(.leading, 16).padding(.bottom, 20)

            // Hint pill — top trailing
            if !isPathMode {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("Long-press any node to trace a path", systemImage: "hand.tap.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(hudFg)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(.trailing, 16).padding(.bottom, 20)
                }
            }
            
            // MARK: Interactive Knowledge HUD
            if let hID = hoverNodeID, let node = engine.nodes.first(where: { $0.id == hID }), node.nodeType == .note {
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 10) {
                            if let bTitle = node.bookTitle {
                                HStack {
                                    Image(systemName: "book.closed.fill").foregroundColor(.blue)
                                    Text(bTitle).font(.caption).bold().foregroundStyle(.secondary)
                                }
                            }
                            if let text = node.fullText, !text.isEmpty {
                                Text("\"\(text)\"")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(6)
                            }
                            if let uNote = node.userNote, !uNote.isEmpty {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "text.bubble.fill").foregroundStyle(.orange).font(.caption)
                                    Text(uNote)
                                        .font(.callout)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .lineLimit(4)
                                }
                            }
                        }
                        .padding(16)
                        .frame(width: 320, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
                        .padding(.top, 24)
                        .padding(.trailing, 24)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    Spacer()
                }
                .zIndex(100)
            }
        }
        .onAppear { engine.buildGraph(from: annotations, pdfs: pdfs) }
        .onDisappear { engine.stopSimulation() }
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
