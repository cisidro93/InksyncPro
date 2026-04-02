import SwiftUI
import SwiftData
import QuartzCore

struct GraphNode: Identifiable, Equatable {
    let id: String
    var position: CGPoint
    var velocity: CGVector = .zero
    let title: String
    let isTag: Bool
    var mass: Double
    var color: Color
    
    static func ==(lhs: GraphNode, rhs: GraphNode) -> Bool {
        lhs.id == rhs.id
    }
}

struct GraphEdge: Identifiable {
    let id: String
    let sourceID: String
    let targetID: String
}

@MainActor
class ZettelkastenGraphEngine: NSObject, ObservableObject {
    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    @Published var draggedNodeID: String? = nil
    
    private var displayLink: CADisplayLink?
    
    // Physics Config
    let repulsionStrength: Double = 4000.0
    let springStiffness: Double = 0.02
    let springLength: Double = 120.0
    let damping: Double = 0.85
    let centerGravity: Double = 0.015
    
    override init() {
        super.init()
    }
    
    func buildGraph(from annotations: [SDAnnotation], pdfs: [SDConvertedPDF]) {
        var newNodes: [String: GraphNode] = [:]
        var newEdges: [GraphEdge] = []
        var connectionCounts: [String: Int] = [:]
        
        let screenCenter = CGPoint(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2)
        
        // Group by Book First
        for ann in annotations {
            let bookID = ann.pdfID.uuidString
            let title: String
            if let readwise = ann.readwiseBookTitle {
                title = readwise
            } else if let matching = pdfs.first(where: { $0.id == ann.pdfID }) {
                title = matching.name
            } else {
                title = "Book"
            }
            
            // Generate Random Spawn Position around center
            let spawnPos = CGPoint(
                x: screenCenter.x + CGFloat.random(in: -200...200),
                y: screenCenter.y + CGFloat.random(in: -200...200)
            )
            
            if newNodes[bookID] == nil {
                newNodes[bookID] = GraphNode(id: bookID, position: spawnPos, title: title, isTag: false, mass: 2.0, color: .blue)
            }
            connectionCounts[bookID, default: 0] += 1
            
            // Map Tags
            if let tags = ann.tags {
                for tag in tags {
                    let tagID = "tag_\(tag.lowercased())"
                    if newNodes[tagID] == nil {
                        newNodes[tagID] = GraphNode(id: tagID, position: spawnPos, title: "#\(tag)", isTag: true, mass: 1.0, color: .orange)
                    }
                    connectionCounts[tagID, default: 0] += 1
                    
                    let edgeID = "\(bookID)_\(tagID)"
                    if !newEdges.contains(where: { $0.id == edgeID }) {
                        newEdges.append(GraphEdge(id: edgeID, sourceID: bookID, targetID: tagID))
                    }
                }
            }
        }
        
        // Scale mass by connections to make central nodes larger
        for (id, count) in connectionCounts {
            if newNodes[id] != nil {
                newNodes[id]?.mass = 1.0 + (Double(count) * 0.2)
            }
        }
        
        self.nodes = Array(newNodes.values)
        self.edges = newEdges
        startSimulation()
    }
    
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
        
        let center = CGPoint(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2)
        
        // 1. Repulsion (Barnes-Hut simplified O(N^2) for small graphs)
        for i in 0..<nodes.count {
            for j in (i+1)..<nodes.count {
                let n1 = nodes[i]
                let n2 = nodes[j]
                let dx = n1.position.x - n2.position.x
                let dy = n1.position.y - n2.position.y
                let distSq = dx * dx + dy * dy
                
                if distSq > 0 && distSq < 100000 {
                    let dist = sqrt(distSq)
                    let force = repulsionStrength / distSq
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    
                    forces[n1.id]?.dx += fx
                    forces[n1.id]?.dy += fy
                    forces[n2.id]?.dx -= fx
                    forces[n2.id]?.dy -= fy
                }
            }
        }
        
        // 2. Spring Attraction (Edges)
        for edge in edges {
            guard let n1Idx = nodes.firstIndex(where: { $0.id == edge.sourceID }),
                  let n2Idx = nodes.firstIndex(where: { $0.id == edge.targetID }) else { continue }
            
            let n1 = nodes[n1Idx]
            let n2 = nodes[n2Idx]
            
            let dx = n2.position.x - n1.position.x
            let dy = n2.position.y - n1.position.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist > 0 {
                let displacement = dist - springLength
                let force = springStiffness * displacement
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                
                forces[n1.id]?.dx += fx
                forces[n1.id]?.dy += fy
                forces[n2.id]?.dx -= fx
                forces[n2.id]?.dy -= fy
            }
        }
        
        // 3. Center Gravity & Integration
        for i in 0..<nodes.count {
            if nodes[i].id == draggedNodeID { continue } // Do not apply physics to dragged node
            
            let dx = center.x - nodes[i].position.x
            let dy = center.y - nodes[i].position.y
            
            forces[nodes[i].id]?.dx += dx * centerGravity
            forces[nodes[i].id]?.dy += dy * centerGravity
            
            let f = forces[nodes[i].id]!
            nodes[i].velocity.dx = (nodes[i].velocity.dx + f.dx / nodes[i].mass) * damping
            nodes[i].velocity.dy = (nodes[i].velocity.dy + f.dy / nodes[i].mass) * damping
            
            // Limit max speed to prevent explosive physics jitter
            let speedSq = nodes[i].velocity.dx * nodes[i].velocity.dx + nodes[i].velocity.dy * nodes[i].velocity.dy
            if speedSq > 2500 {
                let speed = sqrt(speedSq)
                nodes[i].velocity.dx = (nodes[i].velocity.dx / speed) * 50
                nodes[i].velocity.dy = (nodes[i].velocity.dy / speed) * 50
            }
            
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }
        
        // Auto-stop if graph is completely asleep
        var isAsleep = true
        for node in nodes {
            if abs(node.velocity.dx) > 0.1 || abs(node.velocity.dy) > 0.1 {
                isAsleep = false
                break
            }
        }
        if isAsleep && draggedNodeID == nil { stopSimulation() }
    }
    
    deinit {
        displayLink?.invalidate()
    }
}

struct ZettelkastenGraphView: View {
    let annotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]
    
    @StateObject private var engine = ZettelkastenGraphEngine()
    @State private var hoverNodeID: String? = nil
    
    var body: some View {
        Canvas { context, size in
            // Apply Camera Transform
            context.translateBy(x: engine.offset.width + size.width / 2, y: engine.offset.height + size.height / 2)
            context.scaleBy(x: engine.scale, y: engine.scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2)
            
            // Draw Edges
            for edge in engine.edges {
                if let src = engine.nodes.first(where: { $0.id == edge.sourceID }),
                   let tgt = engine.nodes.first(where: { $0.id == edge.targetID }) {
                    var path = Path()
                    path.move(to: src.position)
                    path.addLine(to: tgt.position)
                    
                    let isHighlighted = hoverNodeID == src.id || hoverNodeID == tgt.id
                    context.stroke(path, with: .color(isHighlighted ? .white.opacity(0.8) : .gray.opacity(0.3)), lineWidth: isHighlighted ? 2.0 : 1.0)
                }
            }
            
            // Draw Nodes
            for node in engine.nodes {
                let radius = CGFloat(node.mass * 8.0)
                let rect = CGRect(x: node.position.x - radius, y: node.position.y - radius, width: radius * 2, height: radius * 2)
                let isHighlighted = hoverNodeID == node.id || hoverNodeID == nil
                
                // Glow
                if isHighlighted {
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(node.color.opacity(0.3)))
                }
                
                context.fill(Path(ellipseIn: rect), with: .color(isHighlighted ? node.color : node.color.opacity(0.4)))
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.8)), lineWidth: 1.5)
                
                // Draw Label
                if isHighlighted && node.mass > 1.2 {
                    context.draw(Text(node.title).font(.caption).foregroundColor(isHighlighted ? .primary : .secondary), at: CGPoint(x: node.position.x, y: node.position.y + radius + 10))
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in
                    let touchPos = applyInverseCamera(val.location)
                    if engine.draggedNodeID == nil {
                        // Find node clicked
                        if let tapped = engine.nodes.first(where: { distance(from: $0.position, to: touchPos) < CGFloat($0.mass * 15.0) }) {
                            engine.draggedNodeID = tapped.id
                            engine.startSimulation() // wake physics
                        } else {
                            // Pan Camera
                            engine.offset.width += val.translation.width / engine.scale
                            engine.offset.height += val.translation.height / engine.scale
                        }
                    }
                    
                    if let dragged = engine.draggedNodeID {
                        if let idx = engine.nodes.firstIndex(where: { $0.id == dragged }) {
                            engine.nodes[idx].position = touchPos
                            engine.nodes[idx].velocity = .zero
                        }
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
        .onAppear {
            engine.buildGraph(from: annotations, pdfs: pdfs)
        }
        .onDisappear {
            engine.stopSimulation()
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }
    
    private func applyInverseCamera(_ point: CGPoint) -> CGPoint {
        let size = UIScreen.main.bounds.size
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
        return sqrt(dx*dx + dy*dy)
    }
}
