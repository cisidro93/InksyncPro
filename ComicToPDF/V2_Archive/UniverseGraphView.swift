import SwiftUI
import QuartzCore

// MARK: - Universe Graph Node Types

enum UniverseNodeType {
    case publisher   // Apex hub: Marvel, DC, etc.
    case author      // Creator node: Jack Kirby, Alan Moore
    case series      // Mid-level: "Amazing Spider-Man", "Saga"
    case issue       // Leaf: individual book
}

struct UniverseNode: Identifiable, Equatable {
    let id: String
    var position: CGPoint
    var velocity: CGVector = .zero
    let title: String
    let nodeType: UniverseNodeType
    var connectionCount: Int = 1
    var completionFraction: Double = 0   // 0.0–1.0 for issues/series
    var pageCount: Int = 0
    var pdfID: UUID? = nil               // non-nil for issue nodes

    static func == (lhs: UniverseNode, rhs: UniverseNode) -> Bool { lhs.id == rhs.id }

    var dotRadius: CGFloat {
        switch nodeType {
        case .publisher:  return 18 + CGFloat(connectionCount) * 0.5
        case .author:     return 10 + CGFloat(connectionCount) * 0.4
        case .series:     return 8 + CGFloat(connectionCount) * 0.3
        case .issue:      return max(5, 5 + CGFloat(pageCount) / 80)
        }
    }

    var hitRadius: CGFloat { max(dotRadius * 2.0, 16) }
}

struct UniverseEdge: Identifiable {
    let id: String
    let sourceID: String
    let targetID: String
    let weight: Double        // 1.0 = normal, >1 = stronger spring (series-issue)
}

// MARK: - Universe Graph Engine (repurposed force-directed)

@MainActor
final class UniverseGraphEngine: NSObject, ObservableObject {
    @Published var nodes: [UniverseNode] = []
    @Published var edges: [UniverseEdge] = []
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var draggedNodeID: String? = nil
    var pinchBaseScale: CGFloat = 1.0

    // Physics tuning — tuned for a highly fluid, floating organic feel
    let repulsionStrength: Double = 18_000.0   // Push further apart for less clutter
    let springStiffness: Double  = 0.012       // Softer springs for a breathing, organic pull
    let springLength: Double     = 240.0       // Wider baseline distance to show scale
    let damping: Double          = 0.86        // Less friction for smoother, longer settling
    let centerGravity: Double    = 0.008       // Lighter center pull to let the universe expand

    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var simulationTask: Task<Void, Never>?
    private var tickCount: Int = 0
    private var nodeIndex: [String: Int] = [:]

    // MARK: Build from library

    func buildGraph(pdfs: [ConvertedPDF], tracker: ReaderProgressTracker) {
        var newNodes: [String: UniverseNode] = [:]
        var newEdges: [UniverseEdge] = []
        var connectionCounts: [String: Int] = [:]
        var edgeSet = Set<String>()

        let screenCenter = CGPoint(
            x: UIScreen.main.bounds.width / 2,
            y: UIScreen.main.bounds.height / 2
        )

        func addEdge(_ src: String, _ tgt: String, weight: Double = 1.0) {
            let key = src < tgt ? "\(src)|\(tgt)" : "\(tgt)|\(src)"
            guard !edgeSet.contains(key) else { return }
            edgeSet.insert(key)
            newEdges.append(UniverseEdge(id: key, sourceID: src, targetID: tgt, weight: weight))
            connectionCounts[src, default: 0] += 1
            connectionCounts[tgt, default: 0] += 1
        }

        func randomPoint(radius: ClosedRange<Double>) -> CGPoint {
            let angle = Double.random(in: 0..<2 * .pi)
            let r = Double.random(in: radius)
            return CGPoint(x: screenCenter.x + r * cos(angle), y: screenCenter.y + r * sin(angle))
        }

        for pdf in pdfs {
            let progress = tracker.progress(for: pdf.id)
            let fraction = progress?.completionFraction ?? 0

            // ── Determine grouping keys ──────────────────────────────────
            // Priority 1: ComicVine series metadata
            // Priority 2: metadata.series / metadata.publisher / metadata.author
            // Fallback: derive publisher from filename heuristics

            let seriesName = pdf.metadata.series?.trimmingCharacters(in: .whitespaces) ?? deriveSeries(from: pdf.name)
            let publisherName = pdf.metadata.publisher?.trimmingCharacters(in: .whitespaces) ?? derivePublisher(from: pdf.name)
            let authorName = pdf.metadata.author?.trimmingCharacters(in: .whitespaces)

            // ── Publisher node ───────────────────────────────────────────
            let publisherID = "pub_\(publisherName.lowercased().replacingOccurrences(of: " ", with: "_"))"
            if newNodes[publisherID] == nil {
                newNodes[publisherID] = UniverseNode(
                    id: publisherID,
                    position: randomPoint(radius: 50...120),
                    title: publisherName,
                    nodeType: .publisher
                )
            }

            // ── Author node (optional) ────────────────────────────────────
            var authorID: String? = nil
            if let author = authorName, !author.isEmpty {
                authorID = "author_\(author.lowercased().replacingOccurrences(of: " ", with: "_"))"
                if newNodes[authorID!] == nil {
                    newNodes[authorID!] = UniverseNode(
                        id: authorID!,
                        position: randomPoint(radius: 120...220),
                        title: author,
                        nodeType: .author
                    )
                }
                addEdge(publisherID, authorID!)
            }

            // ── Series node ───────────────────────────────────────────────
            let seriesKey = seriesName.lowercased().replacingOccurrences(of: " ", with: "_")
            let seriesID = "series_\(publisherName.prefix(4).lowercased())_\(seriesKey)"
            if newNodes[seriesID] == nil {
                newNodes[seriesID] = UniverseNode(
                    id: seriesID,
                    position: randomPoint(radius: 180...300),
                    title: seriesName,
                    nodeType: .series
                )
            }
            if var seriesNode = newNodes[seriesID] {
                seriesNode.completionFraction = max(seriesNode.completionFraction, fraction)
                newNodes[seriesID] = seriesNode
            }

            // Link series → publisher (or author if available)
            if let aID = authorID {
                addEdge(seriesID, aID)
            } else {
                addEdge(seriesID, publisherID)
            }

            // ── Issue node ────────────────────────────────────────────────
            let issueID = "issue_\(pdf.id.uuidString)"
            newNodes[issueID] = UniverseNode(
                id: issueID,
                position: randomPoint(radius: 260...420),
                title: pdf.name,
                nodeType: .issue,
                completionFraction: fraction,
                pageCount: pdf.pageCount,
                pdfID: pdf.id
            )
            addEdge(issueID, seriesID, weight: 2.0)
        }

        // Apply connection counts
        for key in newNodes.keys {
            newNodes[key]?.connectionCount = max(1, connectionCounts[key] ?? 1)
        }

        self.nodes = Array(newNodes.values)
        self.edges = newEdges
        nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        startSimulation()
    }

    // MARK: - Fallback Derivation

    private func deriveSeries(from name: String) -> String {
        // Strip issue numbers: "Amazing Spider-Man #42" → "Amazing Spider-Man"
        // Strip file extensions
        let stem = name.components(separatedBy: ".").first ?? name
        // Remove trailing #NNN, Vol NNN, v2, Ch. NN
        let cleaned = stem
            .replacingOccurrences(of: #"\s*#?\d+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[Vv]ol\.?\s*\d+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[Cc]h\.?\s*\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Uncategorized" : cleaned
    }

    private func derivePublisher(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("marvel") { return "Marvel" }
        if lower.contains("dc ") || lower.contains("batman") || lower.contains("superman") || lower.contains("wonder woman") { return "DC Comics" }
        if lower.contains("image") { return "Image Comics" }
        if lower.contains("dark horse") { return "Dark Horse" }
        if lower.contains("idw") { return "IDW" }
        if lower.contains("boom") { return "BOOM! Studios" }
        if lower.contains("manga") || lower.contains("chapter") || lower.contains("ch.") { return "Manga" }
        return "Independent"
    }

    // MARK: - Simulation
    func startSimulation() {
        stopSimulation()
        tickCount = 0
        simulationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.runPhysicsLoop()
        }
    }

    func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
    }

    private func runPhysicsLoop() async {
        let center = await MainActor.run { CGPoint(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2) }
        
        while !Task.isCancelled {
            let start = Date()
            
            // 1. Snapshot state
            let currentNodes = await MainActor.run { return self.nodes }
            let currentEdges = await MainActor.run { return self.edges }
            let draggedID = await MainActor.run { return self.draggedNodeID }
            let currentTick = await MainActor.run { self.tickCount += 1; return self.tickCount }
            
            var newNodes = currentNodes
            var forces: [String: CGVector] = [:]
            for n in newNodes { forces[n.id] = .zero }
            
            // 2. Repulsion
            for i in 0..<newNodes.count {
                for j in (i+1)...<newNodes.count {
                    let dx = newNodes[i].position.x - newNodes[j].position.x
                    let dy = newNodes[i].position.y - newNodes[j].position.y
                    let dSq = dx*dx + dy*dy
                    guard dSq > 1, dSq < 200_000 else { continue }
                    let dist = sqrt(dSq)
                    let f = self.repulsionStrength / dSq
                    forces[newNodes[i].id]?.dx += (dx/dist)*f
                    forces[newNodes[i].id]?.dy += (dy/dist)*f
                    forces[newNodes[j].id]?.dx -= (dx/dist)*f
                    forces[newNodes[j].id]?.dy -= (dy/dist)*f
                }
            }
            
            // 3. Springs
            let idxMap = Dictionary(uniqueKeysWithValues: newNodes.enumerated().map { ($0.element.id, $0.offset) })
            for edge in currentEdges {
                guard let i1 = idxMap[edge.sourceID], let i2 = idxMap[edge.targetID] else { continue }
                let dx = newNodes[i2].position.x - newNodes[i1].position.x
                let dy = newNodes[i2].position.y - newNodes[i1].position.y
                let dist = sqrt(dx*dx + dy*dy)
                guard dist > 0 else { continue }
                let displacement = dist - self.springLength * (2.0 / (edge.weight + 1))
                let force = self.springStiffness * displacement * edge.weight
                let fx = (dx/dist)*force; let fy = (dy/dist)*force
                forces[newNodes[i1].id]?.dx += fx; forces[newNodes[i1].id]?.dy += fy
                forces[newNodes[i2].id]?.dx -= fx; forces[newNodes[i2].id]?.dy -= fy
            }
            
            // 4. Integrate
            var stillCount = 0
            for i in 0..<newNodes.count {
                guard newNodes[i].id != draggedID else { continue }
                let dx = center.x - newNodes[i].position.x
                let dy = center.y - newNodes[i].position.y
                forces[newNodes[i].id]?.dx += dx * self.centerGravity
                forces[newNodes[i].id]?.dy += dy * self.centerGravity
                guard let f = forces[newNodes[i].id] else { continue }
                
                let mass = Double(newNodes[i].connectionCount) * 0.5 + 1.0
                newNodes[i].velocity.dx = (newNodes[i].velocity.dx + f.dx/mass) * self.damping
                newNodes[i].velocity.dy = (newNodes[i].velocity.dy + f.dy/mass) * self.damping
                
                let spd = newNodes[i].velocity.dx*newNodes[i].velocity.dx + newNodes[i].velocity.dy*newNodes[i].velocity.dy
                if spd > 1600 {
                    let s = sqrt(spd)
                    newNodes[i].velocity.dx = newNodes[i].velocity.dx/s*40
                    newNodes[i].velocity.dy = newNodes[i].velocity.dy/s*40
                }
                
                newNodes[i].position.x += newNodes[i].velocity.dx
                newNodes[i].position.y += newNodes[i].velocity.dy
                
                if abs(newNodes[i].velocity.dx) < 0.3 && abs(newNodes[i].velocity.dy) < 0.3 {
                    stillCount += 1
                }
            }
            
            // 5. Commit state back to Main thread
            await MainActor.run { self.nodes = newNodes }
            
            if (stillCount == newNodes.count || currentTick > 300) && draggedID == nil {
                await MainActor.run { self.stopSimulation() }
                break
            }
            
            // 6. Pace to ~60Hz
            let elapsed = Date().timeIntervalSince(start)
            let remaining = (1.0 / 60.0) - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    deinit {
        simulationTask?.cancel()
    }
}

// MARK: - Universe Graph View

struct UniverseGraphView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var tracker = ReaderProgressTracker.shared
    @StateObject private var engine = UniverseGraphEngine()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var selectedNodeID: String? = nil
    @State private var isPanning = false
    @State private var filterPublisher = true
    @State private var filterSeries = true
    @State private var filterAuthors = true
    @State private var filterIssues = true
    @State private var searchText = ""

    // iPad: present detail as sidebar inspector
    @State private var inspectorWidth: CGFloat = 320

    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var bgColor: Color {
        colorScheme == .dark ? Theme.background : Color(hex: "#F0F0F5")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            bgColor.ignoresSafeArea()

            // Dot grid
            Canvas { ctx, size in
                let spacing: CGFloat = 24
                for x in stride(from: 0, through: size.width, by: spacing) {
                    for y in stride(from: 0, through: size.height, by: spacing) {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x-0.8, y: y-0.8, width: 1.5, height: 1.5)),
                            with: .color(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.05))
                        )
                    }
                }
            }.ignoresSafeArea()

            // Graph canvas
            graphCanvas

            // Controls overlay
            controlsOverlay

            // Sidebar inspector (iPad: inline, iPhone: slide-up)
            if isIPad {
                iPadInspector
            } else {
                iPhoneInspector
            }
        }
        .onAppear { rebuildGraph() }
        .onDisappear { engine.stopSimulation() }
        .onChange(of: conversionManager.convertedPDFs.count) { _, _ in rebuildGraph() }
        .onChange(of: searchText) { _, _ in rebuildGraph() }
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        Canvas { context, size in
            context.translateBy(x: engine.offset.width + size.width / 2,
                                y: engine.offset.height + size.height / 2)
            context.scaleBy(x: engine.scale, y: engine.scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2)

            // Edges
            for edge in engine.edges {
                guard let src = engine.nodes.first(where: { $0.id == edge.sourceID }),
                      let tgt = engine.nodes.first(where: { $0.id == edge.targetID }) else { continue }
                guard shouldShowNode(src) && shouldShowNode(tgt) else { continue }

                var path = Path()
                path.move(to: src.position)
                path.addLine(to: tgt.position)
                let isSelected = selectedNodeID == src.id || selectedNodeID == tgt.id
                let opacity = isSelected ? 0.6 : 0.12
                let width: CGFloat = isSelected ? 1.4 : (CGFloat(edge.weight) * 0.5)
                context.stroke(path, with: .color(Color.white.opacity(opacity)), lineWidth: width)
            }

            // Nodes
            for node in engine.nodes {
                guard shouldShowNode(node) else { continue }
                let r = node.dotRadius
                let rect = CGRect(x: node.position.x - r, y: node.position.y - r, width: r*2, height: r*2)
                let isSelected = selectedNodeID == node.id
                let fill = nodeFillColor(for: node)

                if isSelected {
                    // Glow
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -r*0.7, dy: -r*0.7)), with: .color(fill.opacity(0.2)))
                    context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.8)), lineWidth: 2)
                }
                context.fill(Path(ellipseIn: rect), with: .color(fill))

                // Completion arc overlay on issue/series nodes
                if node.nodeType == .issue || node.nodeType == .series, node.completionFraction > 0.02 {
                    var arc = Path()
                    arc.addArc(center: node.position, radius: r + 2,
                               startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * node.completionFraction),
                               clockwise: false)
                    context.stroke(arc, with: .color(Color.green.opacity(0.8)), lineWidth: 2)
                }

                // Labels at zoom > 0.5
                if engine.scale > 0.5 {
                    let show = isSelected || (selectedNodeID == nil && (node.nodeType == .publisher || node.nodeType == .series || (node.nodeType == .author && node.connectionCount > 2)))
                    if show {
                        let truncated = node.title.count > 22 ? String(node.title.prefix(20)) + "…" : node.title
                        let labelPt = CGPoint(x: node.position.x, y: node.position.y + r + 9)
                        context.draw(
                            Text(truncated)
                                .font(.system(size: node.nodeType == .publisher ? 11 : 9, weight: node.nodeType == .publisher ? .bold : .regular))
                                .foregroundColor(isSelected ? .white : Color.primary.opacity(0.7)),
                            at: labelPt
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    let touchPos = applyInverseCamera(val.location)
                    if engine.draggedNodeID == nil {
                        if let hit = engine.nodes.first(where: { shouldShowNode($0) && distance(from: $0.position, to: touchPos) < $0.hitRadius }) {
                            if !isPanning {
                                engine.draggedNodeID = hit.id
                                selectedNodeID = hit.id
                                engine.startSimulation()
                            }
                        } else {
                            if val.translation.width * val.translation.width + val.translation.height * val.translation.height > 64 {
                                isPanning = true
                            }
                            engine.offset.width  += val.translation.width / engine.scale
                            engine.offset.height += val.translation.height / engine.scale
                        }
                    }
                    if let dragged = engine.draggedNodeID, let idx = engine.nodes.firstIndex(where: { $0.id == dragged }) {
                        engine.nodes[idx].position = touchPos
                        engine.nodes[idx].velocity = .zero
                    }
                }
                .onEnded { val in
                    if !isPanning && engine.draggedNodeID == nil {
                        let touchPos = applyInverseCamera(val.location)
                        if engine.nodes.first(where: { shouldShowNode($0) && distance(from: $0.position, to: touchPos) < $0.hitRadius }) == nil {
                            selectedNodeID = nil
                        }
                    }
                    engine.draggedNodeID = nil
                    isPanning = false
                }
        )
        .gesture(
            MagnificationGesture()
                .onChanged { val in engine.scale = min(max(engine.pinchBaseScale * val.magnitude, 0.12), 5.0) }
                .onEnded { _ in engine.pinchBaseScale = engine.scale }
        )
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top: search + zoom reset
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("Search universe…", text: $searchText)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 200)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        engine.scale = 1.0; engine.offset = .zero
                    }
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.top, 14)
            .padding(.leading, 14)

            // Filter badges
            HStack(spacing: 8) {
                universeFilterBadge("Publishers", icon: "building.2.fill", isOn: $filterPublisher, color: publisherColor)
                universeFilterBadge("Series", icon: "rectangle.stack.fill", isOn: $filterSeries, color: seriesColor)
                universeFilterBadge("Authors", icon: "person.fill", isOn: $filterAuthors, color: authorColor)
                universeFilterBadge("Issues", icon: "book.closed.fill", isOn: $filterIssues, color: issueColor)
            }
            .padding(.leading, 14)

            Spacer()

            // Zoom controls
            VStack(spacing: 0) {
                ForEach([("plus", 0.3), ("minus", -0.3)], id: \.0) { item in
                    Button {
                        withAnimation { engine.scale = min(max(engine.scale + item.1, 0.12), 5.0) }
                    } label: {
                        Image(systemName: item.0)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 38, height: 36)
                            .foregroundColor(.primary)
                    }
                    if item.0 == "plus" { Divider().frame(width: 38) }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding(.leading, 14)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Inspectors

    @ViewBuilder
    private var iPadInspector: some View {
        if let id = selectedNodeID, let node = engine.nodes.first(where: { $0.id == id }) {
            HStack(spacing: 0) {
                Spacer()
                universeInspectorPanel(node: node)
                    .frame(width: inspectorWidth)
                    .background(.ultraThinMaterial)
                    .overlay(
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5),
                        alignment: .leading
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .zIndex(100)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedNodeID)
        }
    }

    @ViewBuilder
    private var iPhoneInspector: some View {
        if let id = selectedNodeID, let node = engine.nodes.first(where: { $0.id == id }) {
            VStack {
                Spacer()
                universeInspectorPanel(node: node)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .zIndex(100)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedNodeID)
        }
    }

    @ViewBuilder
    private func universeInspectorPanel(node: UniverseNode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: nodeIcon(for: node.nodeType))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(nodeFillColor(for: node))
                Text(nodeTypeLabel(for: node.nodeType))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    withAnimation { selectedNodeID = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
            }

            Text(node.title)
                .font(.system(size: node.nodeType == .issue ? 15 : 17, weight: .bold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if node.completionFraction > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Progress")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(node.completionFraction * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1)).frame(height: 4)
                            Capsule().fill(Color.green).frame(width: g.size.width * node.completionFraction, height: 4)
                        }
                    }.frame(height: 4)
                }
            }

            if node.pageCount > 0 {
                Label("\(node.pageCount) pages", systemImage: "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Label("\(node.connectionCount) connections", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func rebuildGraph() {
        var filtered = conversionManager.convertedPDFs
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.metadata.series?.localizedCaseInsensitiveContains(searchText) == true) ||
                ($0.metadata.publisher?.localizedCaseInsensitiveContains(searchText) == true)
            }
        }
        engine.buildGraph(pdfs: filtered, tracker: tracker)
    }

    private func shouldShowNode(_ node: UniverseNode) -> Bool {
        switch node.nodeType {
        case .publisher: return filterPublisher
        case .series:    return filterSeries
        case .author:    return filterAuthors
        case .issue:     return filterIssues
        }
    }

    private func applyInverseCamera(_ point: CGPoint) -> CGPoint {
        let canvasW = UIScreen.main.bounds.width
        let canvasH = UIScreen.main.bounds.height
        let cx = (point.x - engine.offset.width - canvasW / 2) / engine.scale + canvasW / 2
        let cy = (point.y - engine.offset.height - canvasH / 2) / engine.scale + canvasH / 2
        return CGPoint(x: cx, y: cy)
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x; let dy = a.y - b.y
        return sqrt(dx*dx + dy*dy)
    }

    // MARK: - Colors

    private var publisherColor: Color { Color(hex: "#FF6B35") }  // vibrant orange
    private var seriesColor: Color    { Color(hex: "#7C3AED") }  // violet
    private var authorColor: Color    { Color(hex: "#0EA5E9") }  // sky blue
    private var issueColor: Color     { Color(hex: "#10B981") }  // emerald

    private func nodeFillColor(for node: UniverseNode) -> Color {
        switch node.nodeType {
        case .publisher: return publisherColor
        case .series:    return seriesColor
        case .author:    return authorColor
        case .issue:
            // Color by completion: grey → emerald
            if node.completionFraction >= 0.99 { return Color.green }
            if node.completionFraction > 0.02  { return issueColor.opacity(0.6 + 0.4 * node.completionFraction) }
            return Color.gray.opacity(0.5)
        }
    }

    private func nodeIcon(for type: UniverseNodeType) -> String {
        switch type {
        case .publisher: return "building.2.fill"
        case .author:    return "person.fill"
        case .series:    return "rectangle.stack.fill"
        case .issue:     return "book.closed.fill"
        }
    }

    private func nodeTypeLabel(for type: UniverseNodeType) -> String {
        switch type {
        case .publisher: return "Publisher"
        case .author:    return "Creator"
        case .series:    return "Series"
        case .issue:     return "Issue"
        }
    }

    @ViewBuilder
    private func universeFilterBadge(_ label: String, icon: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            HapticEngine.light()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isOn.wrappedValue ? color : .secondary)
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isOn.wrappedValue ? color.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(isOn.wrappedValue ? color.opacity(0.4) : Color.clear, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}
