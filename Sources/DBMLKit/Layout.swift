import CoreGraphics
import Foundation

/// Layered (Sugiyama-style) layout: referenced tables go left, referencing tables right.
/// Each connected component is laid out on its own and the components are shelf-packed.
public enum LayeredLayout {
    public struct Node {
        public var id: String
        public var size: CGSize
        public init(id: String, size: CGSize) { self.id = id; self.size = size }
    }

    public struct Edge: Hashable {
        public var parent: String
        public var child: String
        public init(parent: String, child: String) { self.parent = parent; self.child = child }
    }

    public struct Spacing {
        public var horizontal: CGFloat
        public var vertical: CGFloat
        public var component: CGFloat
        public init(horizontal: CGFloat = 110, vertical: CGFloat = 36, component: CGFloat = 90) {
            self.horizontal = horizontal; self.vertical = vertical; self.component = component
        }
    }

    /// Returns the top-left origin of every node.
    public static func layout(nodes: [Node], edges: [Edge], spacing: Spacing = Spacing()) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var edgeSet: Set<Edge> = []
        var pairs: [(Int, Int)] = []
        for e in edges where e.parent != e.child {
            guard let a = index[e.parent], let b = index[e.child], edgeSet.insert(e).inserted else { continue }
            pairs.append((a, b))
        }

        // Union-find for connected components.
        var root = Array(0..<nodes.count)
        func find(_ x: Int) -> Int {
            var x = x
            while root[x] != x { root[x] = root[root[x]]; x = root[x] }
            return x
        }
        for (a, b) in pairs { root[find(a)] = find(b) }
        var components: [Int: [Int]] = [:]
        for i in nodes.indices { components[find(i), default: []].append(i) }

        var placed: [(members: [Int], positions: [Int: CGPoint], size: CGSize)] = []
        for members in components.values {
            let memberSet = Set(members)
            let local = pairs.filter { memberSet.contains($0.0) }
            let positions = layoutComponent(members: members.sorted(), edges: local, nodes: nodes, spacing: spacing)
            var maxX: CGFloat = 0, maxY: CGFloat = 0
            for (i, p) in positions {
                maxX = max(maxX, p.x + nodes[i].size.width)
                maxY = max(maxY, p.y + nodes[i].size.height)
            }
            placed.append((members.sorted(), positions, CGSize(width: maxX, height: maxY)))
        }

        // Biggest components first, then by source order so the result is stable.
        placed.sort {
            let a = $0.members.count, b = $1.members.count
            return a != b ? a > b : $0.members[0] < $1.members[0]
        }
        let totalArea = placed.reduce(0) { $0 + ($1.size.width + spacing.component) * ($1.size.height + spacing.component) }
        let rowLimit = max(placed.map(\.size.width).max() ?? 0, (totalArea * 1.6).squareRoot())

        var result: [String: CGPoint] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for comp in placed {
            if x > 0, x + comp.size.width > rowLimit {
                x = 0
                y += rowHeight + spacing.component
                rowHeight = 0
            }
            for (i, p) in comp.positions {
                result[nodes[i].id] = CGPoint(x: x + p.x, y: y + p.y)
            }
            x += comp.size.width + spacing.component
            rowHeight = max(rowHeight, comp.size.height)
        }
        return result
    }

    private static func layoutComponent(members: [Int], edges: [(Int, Int)], nodes: [Node], spacing: Spacing) -> [Int: CGPoint] {
        if members.count == 1 { return [members[0]: .zero] }

        var children: [Int: [Int]] = [:]
        var parents: [Int: [Int]] = [:]
        var neighbors: [Int: [Int]] = [:]
        for (a, b) in edges {
            children[a, default: []].append(b)
            neighbors[a, default: []].append(b)
            neighbors[b, default: []].append(a)
        }

        // Break cycles: drop DFS back edges for layering purposes.
        var state: [Int: Int] = [:]  // 1 = on stack, 2 = done
        var dag: [Int: [Int]] = [:]
        func dfs(_ n: Int) {
            state[n] = 1
            for c in children[n] ?? [] {
                if state[c] == 1 { continue }
                dag[n, default: []].append(c)
                if state[c] == nil { dfs(c) }
            }
            state[n] = 2
        }
        // Start from nodes with the most children so hubs anchor the left side.
        for n in members.sorted(by: { (children[$0]?.count ?? 0) > (children[$1]?.count ?? 0) }) where state[n] == nil {
            dfs(n)
        }
        for (a, cs) in dag { for c in cs { parents[c, default: []].append(a) } }

        // Longest-path layering in topological order.
        var indegree: [Int: Int] = [:]
        for n in members { indegree[n] = parents[n]?.count ?? 0 }
        var queue = members.filter { indegree[$0] == 0 }
        var topo: [Int] = []
        var layer: [Int: Int] = [:]
        while !queue.isEmpty {
            let n = queue.removeFirst()
            topo.append(n)
            for c in dag[n] ?? [] {
                layer[c] = max(layer[c] ?? 0, (layer[n] ?? 0) + 1)
                indegree[c]! -= 1
                if indegree[c] == 0 { queue.append(c) }
            }
        }
        for n in members where layer[n] == nil { layer[n] = 0 }
        // Pull pure parents (no parents themselves) right, next to their nearest child.
        for n in topo.reversed() where (parents[n] ?? []).isEmpty {
            if let minChild = (dag[n] ?? []).compactMap({ layer[$0] }).min(), minChild - 1 > layer[n]! {
                layer[n] = minChild - 1
            }
        }

        let layerCount = (layer.values.max() ?? 0) + 1
        var layers: [[Int]] = Array(repeating: [], count: layerCount)
        for n in members { layers[layer[n]!].append(n) }

        // Crossing reduction: barycenter sweeps using normalized positions of all neighbors.
        var order: [Int: Double] = [:]
        func renumber() {
            for l in layers {
                for (k, n) in l.enumerated() { order[n] = Double(k) / Double(max(1, l.count - 1)) }
            }
        }
        renumber()
        for sweep in 0..<8 {
            let range: [Int] = sweep % 2 == 0 ? Array(0..<layerCount) : Array((0..<layerCount).reversed())
            for li in range {
                let current = layers[li]
                let keys = current.map { n -> Double in
                    let ns = (neighbors[n] ?? []).filter { sweep % 2 == 0 ? layer[$0]! < li : layer[$0]! > li }
                    let use = ns.isEmpty ? (neighbors[n] ?? []).filter { layer[$0]! != li } : ns
                    guard !use.isEmpty else { return order[n]! }
                    return use.reduce(0) { $0 + order[$1]! } / Double(use.count)
                }
                layers[li] = zip(current, keys).enumerated()
                    .sorted { $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset }
                    .map { $0.element.0 }
                for (k, n) in layers[li].enumerated() { order[n] = Double(k) / Double(max(1, layers[li].count - 1)) }
            }
        }

        // Split very tall layers into several columns so the diagram stays roughly 16:10.
        let area = members.reduce(CGFloat(0)) { $0 + (nodes[$1].size.width + spacing.horizontal) * (nodes[$1].size.height + spacing.vertical) }
        let tallest = members.map { nodes[$0].size.height }.max() ?? 0
        // Never split a column that is only a few tables tall: its edges would cross the extra column.
        let targetHeight = max(tallest * 2.5, (area * 10 / 16).squareRoot())
        var columns: [[Int]] = []
        for l in layers {
            let height = l.reduce(CGFloat(0)) { $0 + nodes[$1].size.height + spacing.vertical }
            let parts = max(1, Int((height / targetHeight).rounded(.up)))
            if parts == 1 { columns.append(l); continue }
            let per = height / CGFloat(parts)
            var col: [Int] = [], acc: CGFloat = 0
            for n in l {
                let h = nodes[n].size.height + spacing.vertical
                if !col.isEmpty, acc + h / 2 > per, columns.count < Int.max {
                    columns.append(col); col = []; acc = 0
                }
                col.append(n); acc += h
            }
            if !col.isEmpty { columns.append(col) }
        }

        // X: one column after another.
        var x: [Int: CGFloat] = [:]
        var cursor: CGFloat = 0
        for col in columns {
            let width = col.map { nodes[$0].size.width }.max() ?? 0
            for n in col { x[n] = cursor }
            cursor += width + spacing.horizontal
        }

        // Y: start stacked, then repeatedly move nodes toward the mean of their neighbors
        // while keeping column order and spacing (exact least-squares via block merging).
        var y: [Int: CGFloat] = [:]
        for col in columns {
            var acc: CGFloat = 0
            for n in col { y[n] = acc; acc += nodes[n].size.height + spacing.vertical }
        }
        let columnOf = Dictionary(uniqueKeysWithValues: columns.enumerated().flatMap { ci, col in col.map { ($0, ci) } })
        for iteration in 0..<12 {
            let range: [Int] = iteration % 2 == 0 ? Array(columns.indices) : Array(columns.indices.reversed())
            for ci in range {
                let col = columns[ci]
                let desired = col.map { n -> CGFloat in
                    let ns = (neighbors[n] ?? []).filter { columnOf[$0] != ci }
                    guard !ns.isEmpty else { return y[n]! }
                    let center = ns.reduce(CGFloat(0)) { $0 + y[$1]! + nodes[$1].size.height / 2 } / CGFloat(ns.count)
                    return center - nodes[n].size.height / 2
                }
                let placed = resolveOverlaps(desired: desired, heights: col.map { nodes[$0].size.height }, gap: spacing.vertical)
                for (k, n) in col.enumerated() { y[n] = placed[k] }
            }
        }

        // Wrap a long chain of columns into stacked bands so the result isn't a thin strip.
        let colWidths = columns.map { col in col.map { nodes[$0].size.width }.max() ?? 0 }
        let totalWidth = colWidths.reduce(0) { $0 + $1 + spacing.horizontal }
        let targetWidth = (area * 16 / 10).squareRoot() * 1.3
        var bands: [[Int]] = [Array(columns.indices)]
        if totalWidth > targetWidth * 1.5 {
            bands = []
            var band: [Int] = [], w: CGFloat = 0
            for ci in columns.indices {
                if !band.isEmpty, w + colWidths[ci] > targetWidth { bands.append(band); band = []; w = 0 }
                band.append(ci); w += colWidths[ci] + spacing.horizontal
            }
            if !band.isEmpty { bands.append(band) }
        }

        var result: [Int: CGPoint] = [:]
        var bandTop: CGFloat = 0
        for band in bands {
            let bandNodes = band.flatMap { columns[$0] }
            let minY = bandNodes.map { y[$0]! }.min() ?? 0
            let minX = bandNodes.map { x[$0]! }.min() ?? 0
            var bottom: CGFloat = 0
            for n in bandNodes {
                let p = CGPoint(x: x[n]! - minX, y: (bandTop + y[n]! - minY).rounded())
                result[n] = p
                bottom = max(bottom, p.y + nodes[n].size.height)
            }
            bandTop = bottom + spacing.horizontal
        }
        return result
    }

    /// Places items in order with `gap` between them, minimizing squared distance to `desired`.
    static func resolveOverlaps(desired: [CGFloat], heights: [CGFloat], gap: CGFloat) -> [CGFloat] {
        struct Block { var first: Int; var count: Int; var sum: CGFloat; var height: CGFloat; var top: CGFloat { sum / CGFloat(count) } }
        var blocks: [Block] = []
        for i in desired.indices {
            var b = Block(first: i, count: 1, sum: desired[i], height: heights[i])
            while let prev = blocks.last, prev.top + prev.height + gap > b.top {
                blocks.removeLast()
                let shift = prev.height + gap
                b = Block(first: prev.first, count: prev.count + b.count,
                          sum: prev.sum + b.sum - shift * CGFloat(b.count), height: prev.height + gap + b.height)
            }
            blocks.append(b)
        }
        var out = Array(repeating: CGFloat(0), count: desired.count)
        for b in blocks {
            var top = b.top
            for i in b.first..<(b.first + b.count) {
                out[i] = top
                top += heights[i] + gap
            }
        }
        return out
    }
}

/// Lays out a whole schema: each TableGroup is laid out as its own cluster, ungrouped tables
/// form clusters by connectivity, and the clusters are then arranged with the same algorithm.
public enum SchemaLayout {
    public static let groupPadding: CGFloat = 28
    public static let groupTitleHeight: CGFloat = 30

    public static func compute(schema: Schema, sizes: [String: CGSize]) -> [String: CGPoint] {
        let edges = schema.refs.map { LayeredLayout.Edge(parent: $0.parent.tableID, child: $0.child.tableID) }
        let nodes = schema.tables.map { LayeredLayout.Node(id: $0.id, size: sizes[$0.id] ?? CGSize(width: 200, height: 100)) }
        let groups = schema.groups.filter { !$0.tableIDs.isEmpty }
        if groups.isEmpty { return LayeredLayout.layout(nodes: nodes, edges: edges) }

        var clusterOf: [String: String] = [:]
        var clusters: [(id: String, members: [String], isGroup: Bool)] = []
        for g in groups {
            let id = "group:\(g.name)"
            clusters.append((id, g.tableIDs, true))
            for t in g.tableIDs { clusterOf[t] = id }
        }
        // Ungrouped tables: connected components over ungrouped-only edges.
        let ungrouped = schema.tables.map(\.id).filter { clusterOf[$0] == nil }
        if !ungrouped.isEmpty {
            let set = Set(ungrouped)
            var root: [String: String] = Dictionary(uniqueKeysWithValues: ungrouped.map { ($0, $0) })
            func find(_ x: String) -> String {
                var x = x
                while root[x]! != x { x = root[x]! }
                return x
            }
            for e in edges where set.contains(e.parent) && set.contains(e.child) { root[find(e.parent)] = find(e.child) }
            var comps: [String: [String]] = [:]
            var orderKeys: [String] = []
            for t in ungrouped {
                let r = find(t)
                if comps[r] == nil { orderKeys.append(r) }
                comps[r, default: []].append(t)
            }
            for r in orderKeys {
                let id = "free:\(r)"
                clusters.append((id, comps[r]!, false))
                for t in comps[r]! { clusterOf[t] = id }
            }
        }

        var local: [String: [String: CGPoint]] = [:]
        var clusterSizes: [String: CGSize] = [:]
        for c in clusters {
            let members = Set(c.members)
            let positions = LayeredLayout.layout(
                nodes: nodes.filter { members.contains($0.id) },
                edges: edges.filter { members.contains($0.parent) && members.contains($0.child) })
            var w: CGFloat = 0, h: CGFloat = 0
            for (id, p) in positions {
                let s = sizes[id] ?? .zero
                w = max(w, p.x + s.width); h = max(h, p.y + s.height)
            }
            if c.isGroup {
                local[c.id] = positions.mapValues { CGPoint(x: $0.x + groupPadding, y: $0.y + groupPadding + groupTitleHeight) }
                clusterSizes[c.id] = CGSize(width: w + groupPadding * 2, height: h + groupPadding * 2 + groupTitleHeight)
            } else {
                local[c.id] = positions
                clusterSizes[c.id] = CGSize(width: w, height: h)
            }
        }

        let clusterEdges = edges.compactMap { e -> LayeredLayout.Edge? in
            guard let a = clusterOf[e.parent], let b = clusterOf[e.child], a != b else { return nil }
            return LayeredLayout.Edge(parent: a, child: b)
        }
        let origins = LayeredLayout.layout(
            nodes: clusters.map { LayeredLayout.Node(id: $0.id, size: clusterSizes[$0.id]!) },
            edges: clusterEdges,
            spacing: .init(horizontal: 160, vertical: 60, component: 120))

        var result: [String: CGPoint] = [:]
        for c in clusters {
            let o = origins[c.id] ?? .zero
            for (id, p) in local[c.id] ?? [:] { result[id] = CGPoint(x: o.x + p.x, y: o.y + p.y) }
        }
        return result
    }

    /// Places tables that have no position yet next to an already placed neighbor,
    /// or to the right of everything, without moving existing tables.
    public static func placeNew(schema: Schema, sizes: [String: CGSize], existing: [String: CGPoint]) -> [String: CGPoint] {
        var result = existing.filter { id, _ in schema.tables.contains { $0.id == id } }
        let missing = schema.tables.map(\.id).filter { result[$0] == nil }
        guard !missing.isEmpty else { return result }
        if result.isEmpty { return compute(schema: schema, sizes: sizes) }

        func rect(_ id: String) -> CGRect { CGRect(origin: result[id]!, size: sizes[id] ?? .zero) }
        func free(_ r: CGRect) -> Bool { !result.keys.contains { rect($0).insetBy(dx: -20, dy: -20).intersects(r) } }
        let bounds = result.keys.map(rect).reduce(CGRect.null) { $0.union($1) }
        var fallbackX = bounds.maxX + 160
        for id in missing {
            let size = sizes[id] ?? CGSize(width: 200, height: 100)
            let neighbor = schema.refs.lazy.compactMap { r -> String? in
                if r.from.tableID == id, result[r.to.tableID] != nil { return r.to.tableID }
                if r.to.tableID == id, result[r.from.tableID] != nil { return r.from.tableID }
                return nil
            }.first
            if let n = neighbor {
                let nr = rect(n)
                var candidate = CGRect(origin: CGPoint(x: nr.maxX + 110, y: nr.minY), size: size)
                for _ in 0..<200 where !free(candidate) { candidate.origin.y += 40 }
                result[id] = candidate.origin
            } else {
                result[id] = CGPoint(x: fallbackX, y: bounds.minY)
                fallbackX += size.width + 60
            }
        }
        return result
    }
}
