import Foundation
import Testing
@testable import DBMLKit

private let samplesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../samples")

private func sample(_ name: String) throws -> Schema {
    DBML.parse(try String(contentsOf: samplesDir.appendingPathComponent(name), encoding: .utf8))
}

private func sizes(_ s: Schema) -> [String: CGSize] {
    Dictionary(uniqueKeysWithValues: s.tables.map { ($0.id, CGSize(width: 220 + CGFloat($0.name.count * 3), height: 40 + 26 * CGFloat($0.columns.count))) })
}

/// A schema with groups, ungrouped tables, cycles and isolated tables (deterministic).
private func synthetic() -> Schema {
    var seed: UInt64 = 42
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
    var text = ""
    for i in 0..<160 {
        text += "Table t\(i) {\n  id int [pk]\n"
        for c in 0..<(1 + next(8)) { text += "  c\(c) int\n" }
        text += "}\n"
    }
    for _ in 0..<220 { text += "Ref: t\(next(160)).c0 > t\(next(160)).id\n" }
    for g in 0..<6 {
        text += "TableGroup g\(g) {\n"
        for i in stride(from: g, to: 120, by: 6) { text += "  t\(i)\n" }
        text += "}\n"
    }
    return DBML.parse(text)
}

private func groupFrame(_ g: TableGroup, _ rect: (String) -> CGRect) -> CGRect {
    let u = g.tableIDs.map(rect).reduce(CGRect.null) { $0.union($1) }
    let pad = SchemaLayout.groupPadding
    return CGRect(x: u.minX - pad, y: u.minY - pad - SchemaLayout.groupTitleHeight,
                  width: u.width + pad * 2, height: u.height + pad * 2 + SchemaLayout.groupTitleHeight)
}

/// Every table placed; no two tables overlap; group boxes overlap neither each other nor outside tables.
private func expectClean(_ s: Schema, _ style: LayoutStyle, _ label: String) {
    let sz = sizes(s)
    let pos = SchemaLayout.compute(schema: s, sizes: sz, style: style)
    #expect(pos.count == s.tables.count, "\(label) \(style): \(pos.count) of \(s.tables.count) placed")
    func rect(_ id: String) -> CGRect { CGRect(origin: pos[id] ?? .zero, size: sz[id]!) }
    let ids = s.tables.map(\.id)
    var overlaps = 0
    for i in ids.indices { for j in ids.indices where j > i && rect(ids[i]).intersects(rect(ids[j])) { overlaps += 1 } }
    #expect(overlaps == 0, "\(label) \(style): \(overlaps) overlapping tables")
    let groups = s.groups.filter { !$0.tableIDs.isEmpty }
    let frames = groups.map { groupFrame($0, rect) }
    for (a, g) in groups.enumerated() {
        let inside = Set(g.tableIDs)
        for id in ids where !inside.contains(id) {
            #expect(!frames[a].intersects(rect(id)), "\(label) \(style): group \(g.name) covers \(id)")
        }
        for b in frames.indices where b > a {
            #expect(!frames[a].intersects(frames[b]), "\(label) \(style): groups \(g.name) and \(groups[b].name) overlap")
        }
    }
}

@Test(arguments: LayoutStyle.allCases)
func stylesProduceCleanLayouts(_ style: LayoutStyle) throws {
    expectClean(try sample("shop.dbml"), style, "shop")
    expectClean(try sample("social.dbml"), style, "social")
    expectClean(synthetic(), style, "synthetic")
}

@Test func pipelineFollowsLineage() throws {
    for s in [try sample("shop.dbml"), try sample("social.dbml"), synthetic()] {
        let sz = sizes(s)
        let pos = SchemaLayout.compute(schema: s, sizes: sz, style: .pipeline)
        // Stages: a group, or a single ungrouped table.
        var unit: [String: String] = [:]
        for g in s.groups { for t in g.tableIDs where unit[t] == nil { unit[t] = "g:\(g.name)" } }
        for t in s.tables where unit[t.id] == nil { unit[t.id] = t.id }
        var next: [String: Set<String>] = [:]
        for r in s.refs { let a = unit[r.parent.tableID]!, b = unit[r.child.tableID]!; if a != b { next[a, default: []].insert(b) } }
        func reaches(_ from: String, _ to: String) -> Bool {
            var stack = [from], seen: Set<String> = [from]
            while let n = stack.popLast() {
                if n == to { return true }
                for m in next[n] ?? [] where seen.insert(m).inserted { stack.append(m) }
            }
            return false
        }
        for r in s.refs {
            let a = unit[r.parent.tableID]!, b = unit[r.child.tableID]!
            guard a != b, !reaches(b, a) else { continue }  // same stage, or part of a cycle
            #expect(pos[r.parent.tableID]!.x < pos[r.child.tableID]!.x, "\(r.parent.tableID) should be left of \(r.child.tableID)")
        }
        // Tables of a group form one column.
        for g in s.groups where !g.tableIDs.isEmpty {
            #expect(Set(g.tableIDs.map { pos[$0]!.x }).count == 1, "group \(g.name) is not one column")
        }
    }
}

@Test func compactIsSmallerThanLeftRight() throws {
    for s in [try sample("shop.dbml"), synthetic()] {
        let sz = sizes(s)
        func area(_ style: LayoutStyle) -> CGFloat {
            let pos = SchemaLayout.compute(schema: s, sizes: sz, style: style)
            let r = s.tables.map { CGRect(origin: pos[$0.id]!, size: sz[$0.id]!) }.reduce(CGRect.null) { $0.union($1) }
            return r.width * r.height
        }
        #expect(area(.compact) < area(.leftRight))
    }
}

@Test func leftRightIsTheDefault() throws {
    let s = try sample("shop.dbml")
    #expect(SchemaLayout.compute(schema: s, sizes: sizes(s)) == SchemaLayout.compute(schema: s, sizes: sizes(s), style: .leftRight))
}
