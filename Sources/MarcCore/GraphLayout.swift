import CoreGraphics
import Foundation

/// Deterministic ring layout for the linked-file graph.
///
/// Nodes are placed on concentric rings around a center node. Each ring holds
/// only as many nodes as its circumference can fit at full card width, so the
/// layout never overlaps regardless of how many references a document has.
/// The result is computed once per size change rather than per node.
public struct ReferenceGraphLayout: Equatable {
    public struct Node: Equatable {
        public let id: String
        public let center: CGPoint
        public let ring: Int
    }

    public let center: CGPoint
    public let nodes: [Node]
    public let contentSize: CGSize
    public let nodeSize: CGSize
    public let centerNodeSize: CGSize

    public static let defaultNodeSize = CGSize(width: 116, height: 44)
    public static let defaultCenterNodeSize = CGSize(width: 132, height: 48)
    private static let gap: CGFloat = 18
    private static let margin: CGFloat = 24

    public init(
        ids: [String],
        nodeSize: CGSize = ReferenceGraphLayout.defaultNodeSize,
        centerNodeSize: CGSize = ReferenceGraphLayout.defaultCenterNodeSize
    ) {
        self.nodeSize = nodeSize
        self.centerNodeSize = centerNodeSize

        guard !ids.isEmpty else {
            let size = CGSize(
                width: centerNodeSize.width + Self.margin * 2,
                height: centerNodeSize.height + Self.margin * 2
            )
            self.contentSize = size
            self.center = CGPoint(x: size.width / 2, y: size.height / 2)
            self.nodes = []
            return
        }

        let slotWidth = nodeSize.width + Self.gap
        let ringStep = nodeSize.height + Self.gap
        let firstRadius = max(centerNodeSize.width, nodeSize.width) / 2
            + nodeSize.width / 2
            + Self.gap

        // Positions are built ring by ring in an unbounded space around the
        // origin, then translated once the full extent is known.
        var placed: [(center: CGPoint, size: CGSize)] = [(.zero, centerNodeSize)]
        var rings: [(radius: CGFloat, offset: Double, count: Int)] = []
        var remaining = ids.count
        var ringIndex = 0

        while remaining > 0 {
            var radius = firstRadius + CGFloat(ringIndex) * ringStep
            let count = min(max(1, Int((2 * .pi * radius) / slotWidth)), remaining)
            let step = (2 * .pi) / Double(count)
            // Stagger alternate rings so cards never line up radially.
            let offset = ringIndex.isMultiple(of: 2) ? 0 : step / 2

            // Grow the ring until nothing on it collides with an inner ring.
            // Capacity was measured at the starting radius, so growing only
            // ever increases the room available within the ring itself.
            var attempts = 0
            while attempts < 400 {
                let candidates = Self.ringPositions(
                    radius: radius,
                    count: count,
                    offset: offset
                )
                let clear = candidates.allSatisfy { candidate in
                    placed.allSatisfy { !Self.overlaps(candidate, nodeSize, $0.center, $0.size) }
                }
                if clear { break }
                radius += 4
                attempts += 1
            }

            for point in Self.ringPositions(radius: radius, count: count, offset: offset) {
                placed.append((point, nodeSize))
            }
            rings.append((radius, offset, count))
            remaining -= count
            ringIndex += 1
        }

        let outerRadius = rings.last?.radius ?? 0
        let size = CGSize(
            width: (outerRadius + nodeSize.width / 2 + Self.margin) * 2,
            height: (outerRadius + nodeSize.height / 2 + Self.margin) * 2
        )
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)

        var nodes: [Node] = []
        nodes.reserveCapacity(ids.count)
        var index = 0
        for (ringNumber, ring) in rings.enumerated() {
            for point in Self.ringPositions(radius: ring.radius, count: ring.count, offset: ring.offset) {
                nodes.append(
                    Node(
                        id: ids[index],
                        center: CGPoint(x: origin.x + point.x, y: origin.y + point.y),
                        ring: ringNumber
                    )
                )
                index += 1
            }
        }

        self.contentSize = size
        self.center = origin
        self.nodes = nodes
    }

    private static func ringPositions(radius: CGFloat, count: Int, offset: Double) -> [CGPoint] {
        let step = (2 * .pi) / Double(max(1, count))
        return (0..<count).map { slot in
            let angle = Double(slot) * step + offset - .pi / 2
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }

    private static func overlaps(
        _ a: CGPoint,
        _ aSize: CGSize,
        _ b: CGPoint,
        _ bSize: CGSize
    ) -> Bool {
        abs(a.x - b.x) < (aSize.width + bSize.width) / 2
            && abs(a.y - b.y) < (aSize.height + bSize.height) / 2
    }

    /// Scale that fits the whole graph inside `viewport` without cropping.
    ///
    /// Shrinking stops at `minimum` so node labels stay readable in a narrow
    /// panel; past that point the graph is panned rather than shrunk further.
    public func fitScale(in viewport: CGSize, minimum: CGFloat = 0.6) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return 1 }
        let fit = min(viewport.width / contentSize.width, viewport.height / contentSize.height)
        return min(1, max(minimum, fit))
    }

    /// Point where a straight line leaving `origin` toward `target` crosses the
    /// boundary of a card of `size` centered on `origin`. Keeps edges from
    /// running underneath the node cards they connect.
    public static func boundaryPoint(from origin: CGPoint, toward target: CGPoint, size: CGSize) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        guard dx != 0 || dy != 0 else { return origin }
        let scaleX = dx == 0 ? CGFloat.greatestFiniteMagnitude : (size.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.greatestFiniteMagnitude : (size.height / 2) / abs(dy)
        let t = min(scaleX, scaleY, 1)
        return CGPoint(x: origin.x + dx * t, y: origin.y + dy * t)
    }
}
