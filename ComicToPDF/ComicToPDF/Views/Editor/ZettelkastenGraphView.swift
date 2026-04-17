import SwiftUI
import SwiftData
import QuartzCore

// MARK: - Data Models

struct GraphNode: Identifiable, Equatable {
    let id: String
    var position: CGPoint
    var velocity: CGVector = .zero
    let title: String
    let isTag: Bool
    var mass: Double
    var color: Color

    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool { lhs.id == rhs.id }
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

    /// Path-finding state — the two nodes the user has long-pressed to trace a path between.
    @Published var pathAnchorA: String? = nil
    @Published var pathAnchorB: String? = nil
    /// The set of node IDs that form the shortest path between A and B.
    @Published var highlightedPathNodeIDs: Set<String> = []
    /// The set of edge IDs that form the shortest path between A and B.
    @Published var highlightedPathEdgeIDs: Set<String> = []

    private var displayLink: CADisplayLink?

    // Physics tuning
    let repulsionStrength: Double  = 4500.0
    let springStiffness: Double    = 0.022
    let springLength: Double       = 130.0
    let damping: Double            = 0.85
    let centerGravity: Double      = 0.015

    override init() { super.init() }

    // MARK: Build

    func buildGraph(from annotations: [SDAnnotation], pdfs: [SDConvertedPDF]) {
        var newNodes: [String: GraphNode] = [:]
        var newEdges: [GraphEdge] = []
        var connectionCounts: [String: Int] = [:]

        let screenCenter = CGPoint(x: UIScreen.main.bounds.width / 2,
                                   y: UIScreen.main.bounds.height / 2)

        for ann in annotations {
            let bookID = ann.pdfID.uuidString
            let title: String
            if let rwTitle = ann.readwiseBookTitle {
                title = rwTitle
            } else if let match = pdfs.first(where: { $0.id == ann.pdfID }) {
                title = match.name
            } else {
                title = "Book"
            }

            let spawnPos = CGPoint(
                x: screenCenter.x + CGFloat.random(in: -220...220),
                y: screenCenter.y + CGFloat.random(in: -220...220)
            )

            if newNodes[bookID] == nil {
                newNodes[bookID] = GraphNode(id: bookID, position: spawnPos,
                                             title: title, isTag: false, mass: 2.0, color: .blue)
            }
            connectionCounts[bookID, default: 0] += 1

            if let tags = ann.tags {
                for tag in tags {
                    let tagID = "tag_\(tag.lowercased())"
                    if newNodes[tagID] == nil {
                        newNodes[tagID] = GraphNode(id: tagID, position: spawnPos,
                                                    title: "#\(tag)", isTag: true, mass: 1.0, color: .orange)
                    }
                    connectionCounts[tagID, default: 0] += 1
                    let edgeID = "\(bookID)_\(tagID)"
                    if !newEdges.contains(where: { $0.id == edgeID }) {
                        newEdges.append(GraphEdge(id: edgeID, sourceID: bookID, targetID: tagID))
                    }
                }
            }
        }

        for (id, count) in connectionCounts {
            newNodes[id]?.mass = 1.0 + Double(count) * 0.2
        }

        self.nodes = Array(newNodes.values)
        self.edges = newEdges
        startSimulation()
    }

    // MARK: Simulation

    func startSimulation() {
        stopSimulation()
        displayLink = CADisplayLink(target: self, selector: #selector(physicsTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopSimulation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func physicsTick() {
        var forces: [String: CGVector] = [:]
        for node in nodes { forces[node.id] = .zero }

        let center = CGPoint(x: UIScreen.main.bounds.width / 2,
                             y: UIScreen.main.bounds.height / 2)

        // 1. Repulsion
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let n1 = nodes[i]; let n2 = nodes[j]
                let dx = n1.position.x - n2.position.x
                let dy = n1.position.y - n2.position.y
                let distSq = dx * dx + dy * dy
                guard distSq > 0, distSq < 100_000 else { continue }
                let dist = sqrt(distSq)
                let force = repulsionStrength / distSq
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[n1.id]?.dx += fx; forces[n1.id]?.dy += fy
                forces[n2.id]?.dx -= fx; forces[n2.id]?.dy -= fy
            }
        }

        // 2. Spring Attraction
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

        // 3. Center Gravity + Integration
        for i in 0..<nodes.count {
            guard nodes[i].id != draggedNodeID else { continue }
            let dx = center.x - nodes[i].position.x
            let dy = center.y - nodes[i].position.y
            forces[nodes[i].id]?.dx += dx * centerGravity
            forces[nodes[i].id]?.dy += dy * centerGravity

            let f = forces[nodes[i].id]!
            nodes[i].velocity.dx = (nodes[i].velocity.dx + f.dx / nodes[i].mass) * damping
            nodes[i].velocity.dy = (nodes[i].velocity.dy + f.dy / nodes[i].mass) * damping

            let speedSq = nodes[i].velocity.dx * nodes[i].velocity.dx
                        + nodes[i].velocity.dy * nodes[i].velocity.dy
            if speedSq > 2500 {
                let speed = sqrt(speedSq)
                nodes[i].velocity.dx = (nodes[i].velocity.dx / speed) * 50
                nodes[i].velocity.dy = (nodes[i].velocity.dy / speed) * 50
            }
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }

        var isAsleep = true
        for node in nodes where abs(node.velocity.dx) > 0.1 || abs(node.velocity.dy) > 0.1 {
            isAsleep = false; break
        }
        if isAsleep && draggedNodeID == nil { stopSimulation() }
    }

    // MARK: Path Finding (BFS shortest path)

    /// Sets the first or second path anchor, then finds the path between them.
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
            // Third tap resets
            pathAnchorA = nodeID
            pathAnchorB = nil
            highlightedPathNodeIDs = [nodeID]
            highlightedPathEdgeIDs = []
        }
    }

    func clearPath() {
        pathAnchorA = nil
        pathAnchorB = nil
        highlightedPathNodeIDs = []
        highlightedPathEdgeIDs = []
    }

    /// BFS over the undirected edge graph to find the shortest node/edge path.
    private func computeShortestPath() {
        guard let src = pathAnchorA, let dst = pathAnchorB else { return }

        // Build adjacency list (undirected)
        var adj: [String: [(nodeID: String, edgeID: String)]] = [:]
        for edge in edges {
            adj[edge.sourceID, default: []].append((edge.targetID, edge.id))
            adj[edge.targetID, default: []].append((edge.sourceID, edge.id))
        }

        // BFS
        var visited: Set<String> = [src]
        var queue: [(nodeID: String, path: [String], edgePath: [String])] = [(src, [src], [])]
        var foundNodePath: [String] = []
        var foundEdgePath: [String] = []

        while !queue.isEmpty {
            let (current, nodePath, edgePath) = queue.removeFirst()
            if current == dst {
                foundNodePath = nodePath
                foundEdgePath = edgePath
                break
            }
            for neighbor in adj[current] ?? [] {
                if !visited.contains(neighbor.nodeID) {
                    visited.insert(neighbor.nodeID)
                    queue.append((neighbor.nodeID,
                                  nodePath + [neighbor.nodeID],
                                  edgePath + [neighbor.edgeID]))
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

    // Hover highlight (single-tap)
    @State private var hoverNodeID: String? = nil
    // Long-press state
    @State private var longPressNodeID: String? = nil
    // Canvas size captured for inverse-camera math
    @State private var canvasSize: CGSize = UIScreen.main.bounds.size

    // MARK: Computed helpers

    private var isPathMode: Bool {
        engine.pathAnchorA != nil
    }

    private var bgColor: Color {
        colorScheme == .dark
            ? Color(UIColor.systemBackground)          // near-black in dark mode
            : Color(UIColor.secondarySystemBackground) // off-white in light mode
    }

    private var gridColor: Color {
        colorScheme == .dark ? .white.opacity(0.05) : .black.opacity(0.04)
    }

    private var defaultEdgeColor: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.18)
    }

    private var nodeStrokeColor: Color {
        colorScheme == .dark ? .white.opacity(0.75) : .black.opacity(0.25)
    }

    private var labelColor: Color {
        colorScheme == .dark ? .white : .black
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Theme-reactive background
            bgColor.ignoresSafeArea()

            // Subtle grid dots (like Recall)
            Canvas { ctx, size in
                let spacing: CGFloat = 30
                for x in stride(from: 0, through: size.width, by: spacing) {
                    for y in stride(from: 0, through: size.height, by: spacing) {
                        let dot = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                        ctx.fill(Path(ellipseIn: dot), with: .color(gridColor))
                    }
                }
            }
            .ignoresSafeArea()

            // Main graph canvas
            Canvas { context, size in
                canvasSize = size

                // Camera transform
                context.translateBy(x: engine.offset.width + size.width / 2,
                                    y: engine.offset.height + size.height / 2)
                context.scaleBy(x: engine.scale, y: engine.scale)
                context.translateBy(x: -size.width / 2, y: -size.height / 2)

                // MARK: Draw Edges
                let pathActive = !engine.highlightedPathEdgeIDs.isEmpty

                for edge in engine.edges {
                    guard let src = engine.nodes.first(where: { $0.id == edge.sourceID }),
                          let tgt = engine.nodes.first(where: { $0.id == edge.targetID }) else { continue }

                    var path = Path()
                    path.move(to: src.position)
                    path.addLine(to: tgt.position)

                    let isOnPath = engine.highlightedPathEdgeIDs.contains(edge.id)
                    let isHovered = hoverNodeID == src.id || hoverNodeID == tgt.id

                    if pathActive {
                        if isOnPath {
                            // Glowing path edge
                            context.stroke(path, with: .color(.cyan.opacity(0.35)), lineWidth: 6)
                            context.stroke(path, with: .color(.cyan), lineWidth: 2)
                        } else {
                            // Fade non-path edges
                            context.stroke(path, with: .color(defaultEdgeColor.opacity(0.08)), lineWidth: 0.5)
                        }
                    } else if isHovered {
                        context.stroke(path, with: .color(colorScheme == .dark ? .white.opacity(0.85) : .black.opacity(0.6)), lineWidth: 2.0)
                    } else {
                        context.stroke(path, with: .color(defaultEdgeColor), lineWidth: 1.0)
                    }
                }

                // MARK: Draw Nodes
                for node in engine.nodes {
                    let radius = CGFloat(node.mass * 8.0)
                    let rect = CGRect(x: node.position.x - radius,
                                      y: node.position.y - radius,
                                      width: radius * 2, height: radius * 2)

                    let isOnPath    = engine.highlightedPathNodeIDs.contains(node.id)
                    let isAnchor    = node.id == engine.pathAnchorA || node.id == engine.pathAnchorB
                    let isHovered   = hoverNodeID == node.id

                    if pathActive {
                        if isAnchor {
                            // Pulsing glow for anchor nodes
                            context.fill(Path(ellipseIn: rect.insetBy(dx: -8, dy: -8)), with: .color(.cyan.opacity(0.25)))
                            context.fill(Path(ellipseIn: rect), with: .color(.cyan))
                            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2.5)
                        } else if isOnPath {
                            context.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(.cyan.opacity(0.2)))
                            context.fill(Path(ellipseIn: rect), with: .color(node.color))
                            context.stroke(Path(ellipseIn: rect), with: .color(.cyan), lineWidth: 2.0)
                        } else {
                            // Dim out off-path nodes
                            context.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(0.15)))
                        }
                    } else {
                        let highlighted = isHovered || hoverNodeID == nil
                        if highlighted {
                            context.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)),
                                         with: .color(node.color.opacity(0.3)))
                        }
                        context.fill(Path(ellipseIn: rect),
                                     with: .color(highlighted ? node.color : node.color.opacity(0.4)))
                        context.stroke(Path(ellipseIn: rect),
                                       with: .color(nodeStrokeColor), lineWidth: 1.5)
                    }

                    // Label
                    let showLabel = pathActive
                        ? (isOnPath || isAnchor)
                        : ((hoverNodeID == nil || isHovered) && node.mass > 1.2)

                    if showLabel {
                        let labelPt = CGPoint(x: node.position.x, y: node.position.y + radius + 10)
                        context.draw(
                            Text(node.title)
                                .font(.system(size: 10, weight: node.isTag ? .regular : .semibold))
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
                                distance(from: $0.position, to: touchPos) < CGFloat($0.mass * 18.0)
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
                                distance(from: $0.position, to: touchPos) < CGFloat($0.mass * 15.0)
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

            // MARK: HUD Overlays
            VStack(alignment: .trailing, spacing: 8) {
                // Path mode controls
                if isPathMode {
                    HStack(spacing: 8) {
                        if engine.pathAnchorA != nil && engine.pathAnchorB == nil {
                            Label("Long-press a second node to trace path", systemImage: "hand.tap")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        Button {
                            withAnimation { engine.clearPath() }
                        } label: {
                            Label("Clear Path", systemImage: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                }

                // Node / edge counter
                HStack(spacing: 6) {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                    Text("\(engine.nodes.filter { !$0.isTag }.count) books")
                        .font(.system(size: 11, weight: .semibold))
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text("\(engine.nodes.filter { $0.isTag }.count) tags")
                        .font(.system(size: 11, weight: .semibold))
                    Text("·")
                    Text("\(engine.edges.count) links")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 20)
                .padding(.trailing, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // Long-press hint (shown only when not in path mode)
            if !isPathMode {
                VStack {
                    Spacer()
                    HStack {
                        Label("Long-press any node to start path tracing", systemImage: "hand.tap.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.4))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear { engine.buildGraph(from: annotations, pdfs: pdfs) }
        .onDisappear { engine.stopSimulation() }
    }

    // MARK: - Helpers

    private func applyInverseCamera(_ point: CGPoint) -> CGPoint {
        let size = canvasSize.width > 0 ? canvasSize : UIScreen.main.bounds.size
        var p = point
        p.x -= size.width / 2
        p.y -= size.height / 2
        p.x /= engine.scale
        p.y /= engine.scale
        p.x -= engine.offset.width
        p.y -= engine.offset.height
        p.x += size.width / 2
        p.y += size.height / 2
        return p
    }

    private func distance(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return sqrt(dx * dx + dy * dy)
    }
}
