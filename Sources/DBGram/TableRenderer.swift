import AppKit
import DBMLKit

/// Measures and draws one table card. Drawing assumes a y-down context.
enum TableRenderer {
    static func size(of table: Table) -> CGSize {
        let header = attributedHeader(table, color: .black).size().width + Metrics.padding * 2 + (table.note != nil ? 22 : 0)
        var rowWidth: CGFloat = 0
        for c in table.columns {
            let name = (c.name as NSString).size(withAttributes: [.font: c.isPrimaryKey ? Metrics.pkColumnFont : Metrics.columnFont]).width
            let type = (c.type as NSString).size(withAttributes: [.font: Metrics.typeFont]).width
            rowWidth = max(rowWidth, Metrics.iconColumn + name + (c.note != nil ? 10 : 0) + 28 + type)
        }
        let width = min(Metrics.maxWidth, max(Metrics.minWidth, header, rowWidth + Metrics.padding * 2)).rounded(.up)
        let height = Metrics.headerHeight + CGFloat(max(table.columns.count, 1)) * Metrics.rowHeight + 4
        return CGSize(width: width, height: height)
    }

    static func rowCenterY(_ index: Int) -> CGFloat {
        Metrics.headerHeight + (CGFloat(index) + 0.5) * Metrics.rowHeight
    }

    /// Row under a point in table-local coordinates; -1 for the header.
    static func row(at y: CGFloat, in table: Table) -> Int? {
        if y < Metrics.headerHeight { return -1 }
        let i = Int((y - Metrics.headerHeight) / Metrics.rowHeight)
        return i < table.columns.count ? i : nil
    }

    static func headerTextColor(_ header: NSColor) -> NSColor {
        header.luminance > 0.62 ? NSColor(white: 0.1, alpha: 0.92) : .white
    }

    private static func attributedHeader(_ table: Table, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if let schema = table.schema {
            s.append(NSAttributedString(string: schema + ".", attributes: [.font: Metrics.schemaFont, .foregroundColor: color.withAlphaComponent(0.7)]))
        }
        s.append(NSAttributedString(string: table.name, attributes: [.font: Metrics.headerFont, .foregroundColor: color]))
        return s
    }

    static func draw(_ table: Table, size: CGSize, header: NSColor, theme: Theme, in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = CGRect(origin: .zero, size: size)
        let card = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Metrics.cornerRadius, cornerHeight: Metrics.cornerRadius, transform: nil)

        ctx.saveGState()
        ctx.addPath(card)
        ctx.setFillColor(theme.tableBody.cgColor)
        ctx.fillPath()

        ctx.addPath(card)
        ctx.clip()
        ctx.setFillColor(header.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: Metrics.headerHeight))
        // Soft highlight at the top of the header gives it some depth.
        ctx.setFillColor(NSColor.white.withAlphaComponent(theme.isDark ? 0.06 : 0.10).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: Metrics.headerHeight / 2))

        // Rows.
        let textColor = theme.text
        for (i, c) in table.columns.enumerated() {
            let top = Metrics.headerHeight + CGFloat(i) * Metrics.rowHeight
            if i > 0 {
                ctx.setFillColor(theme.divider.cgColor)
                ctx.fill(CGRect(x: Metrics.padding, y: top, width: size.width - Metrics.padding * 2, height: 1))
            }
            let mid = top + Metrics.rowHeight / 2

            if c.isPrimaryKey {
                drawSymbol("key.fill", color: theme.pk, center: CGPoint(x: Metrics.padding + 6, y: mid), pointSize: 9.5)
            } else if c.isForeignKey {
                drawSymbol("link", color: theme.fk, center: CGPoint(x: Metrics.padding + 6, y: mid), pointSize: 9.5)
            }

            let type = NSAttributedString(string: c.type, attributes: [.font: Metrics.typeFont, .foregroundColor: theme.secondaryText])
            let typeWidth = min(type.size().width, (size.width - Metrics.padding * 2 - Metrics.iconColumn) * 0.55)
            let typeRect = CGRect(x: size.width - Metrics.padding - typeWidth, y: mid - 7.5, width: typeWidth, height: 15)
            type.draw(with: typeRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            var nameAttrs: [NSAttributedString.Key: Any] = [.font: c.isPrimaryKey ? Metrics.pkColumnFont : Metrics.columnFont, .foregroundColor: textColor]
            if !c.isNotNull && !c.isPrimaryKey { nameAttrs[.foregroundColor] = textColor.withAlphaComponent(0.82) }
            let name = NSAttributedString(string: c.name, attributes: nameAttrs)
            let nameX = Metrics.padding + Metrics.iconColumn
            let maxName = typeRect.minX - nameX - 12 - (c.note != nil ? 10 : 0)
            let nameWidth = min(name.size().width, maxName)
            name.draw(with: CGRect(x: nameX, y: mid - 8, width: nameWidth, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            if c.note != nil {
                ctx.setFillColor(theme.accent.withAlphaComponent(0.7).cgColor)
                ctx.fillEllipse(in: CGRect(x: nameX + nameWidth + 5, y: mid - 2, width: 4, height: 4))
            }
        }
        if table.columns.isEmpty {
            let empty = NSAttributedString(string: "no columns", attributes: [.font: Metrics.columnFont, .foregroundColor: theme.secondaryText])
            empty.draw(at: CGPoint(x: Metrics.padding + Metrics.iconColumn, y: Metrics.headerHeight + 5))
        }
        ctx.restoreGState()

        // Header text.
        let headerText = attributedHeader(table, color: headerTextColor(header))
        let noteSpace: CGFloat = table.note != nil ? 22 : 0
        headerText.draw(with: CGRect(x: Metrics.padding, y: Metrics.headerHeight / 2 - 9, width: size.width - Metrics.padding * 2 - noteSpace, height: 18),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if table.note != nil {
            drawSymbol("text.bubble.fill", color: headerTextColor(header).withAlphaComponent(0.75),
                        center: CGPoint(x: size.width - Metrics.padding - 6, y: Metrics.headerHeight / 2), pointSize: 11)
        }

        ctx.addPath(card)
        ctx.setStrokeColor(theme.tableBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private static var symbolCache: [String: NSImage] = [:]

    private static func drawSymbol(_ name: String, color: NSColor, center: CGPoint, pointSize: CGFloat) {
        let key = "\(name)|\(color.description)|\(pointSize)"
        let image: NSImage
        if let cached = symbolCache[key] {
            image = cached
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            symbolCache[key] = img
            image = img
        }
        let s = image.size
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Geometry of a relationship line between two column rows, including cardinality markers.
enum EdgeGeometry {
    struct Anchor {
        var rect: CGRect
        var rowY: CGFloat
        var cardinality: Cardinality
    }

    static func path(from a: Anchor, to b: Anchor, sameTable: Bool) -> CGPath {
        let path = CGMutablePath()
        let stub: CGFloat = 16

        if sameTable {
            let x = a.rect.maxX
            let p1 = CGPoint(x: x, y: a.rowY), p2 = CGPoint(x: x, y: b.rowY)
            let reach: CGFloat = 46 + abs(p2.y - p1.y) * 0.15
            path.move(to: p1)
            path.addLine(to: CGPoint(x: x + stub, y: p1.y))
            path.addCurve(to: CGPoint(x: x + stub, y: p2.y),
                          control1: CGPoint(x: x + reach, y: p1.y), control2: CGPoint(x: x + reach, y: p2.y))
            path.addLine(to: p2)
            addMarker(path, at: p1, direction: 1, a.cardinality)
            addMarker(path, at: p2, direction: 1, b.cardinality)
            return path
        }

        // Pick sides: face each other when horizontally separated, otherwise loop around the right.
        let da: CGFloat, db: CGFloat
        if a.rect.maxX + 24 < b.rect.minX { (da, db) = (1, -1) }
        else if b.rect.maxX + 24 < a.rect.minX { (da, db) = (-1, 1) }
        else if a.rect.midX <= b.rect.midX { (da, db) = (-1, -1) }
        else { (da, db) = (1, 1) }

        let p1 = CGPoint(x: da > 0 ? a.rect.maxX : a.rect.minX, y: a.rowY)
        let p2 = CGPoint(x: db > 0 ? b.rect.maxX : b.rect.minX, y: b.rowY)
        let s1 = CGPoint(x: p1.x + da * stub, y: p1.y)
        let s2 = CGPoint(x: p2.x + db * stub, y: p2.y)
        let reach: CGFloat = da == db
            ? max(50, abs(s2.x - s1.x) + 50)
            : max(40, min(abs(s2.x - s1.x) * 0.5, 260))
        path.move(to: p1)
        path.addLine(to: s1)
        path.addCurve(to: s2,
                      control1: CGPoint(x: s1.x + da * reach, y: s1.y),
                      control2: CGPoint(x: s2.x + db * reach, y: s2.y))
        path.addLine(to: p2)
        addMarker(path, at: p1, direction: da, a.cardinality)
        addMarker(path, at: p2, direction: db, b.cardinality)
        return path
    }

    /// "One" is a bar across the line; "many" is a crow's foot opening toward the table.
    private static func addMarker(_ path: CGMutablePath, at p: CGPoint, direction d: CGFloat, _ c: Cardinality) {
        switch c {
        case .one:
            path.move(to: CGPoint(x: p.x + d * 9, y: p.y - 5))
            path.addLine(to: CGPoint(x: p.x + d * 9, y: p.y + 5))
        case .many:
            let tip = CGPoint(x: p.x + d * 12, y: p.y)
            path.move(to: tip); path.addLine(to: CGPoint(x: p.x, y: p.y - 6))
            path.move(to: tip); path.addLine(to: CGPoint(x: p.x, y: p.y + 6))
        }
    }
}

/// Everything needed to draw a diagram, shared by the live canvas and the PNG exporter.
struct DiagramScene {
    var schema: Schema
    var style: SceneStyle
    var sizes: [String: CGSize]
    var positions: [String: CGPoint]

    init(schema: Schema, positions: [String: CGPoint]) {
        self.schema = schema
        style = SceneStyle(schema: schema)
        sizes = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0.id, TableRenderer.size(of: $0)) })
        self.positions = positions
    }

    func rect(_ id: String) -> CGRect {
        CGRect(origin: positions[id] ?? .zero, size: sizes[id] ?? .zero)
    }

    func anchors(_ ref: Ref) -> (EdgeGeometry.Anchor, EdgeGeometry.Anchor)? {
        guard let ta = schema.table(id: ref.from.tableID), let tb = schema.table(id: ref.to.tableID) else { return nil }
        func anchor(_ t: Table, _ e: RefEndpoint) -> EdgeGeometry.Anchor {
            let r = rect(t.id)
            let row = e.columns.first.flatMap { t.columnIndex(named: $0) }
            let y = row.map { r.minY + TableRenderer.rowCenterY($0) } ?? (r.minY + Metrics.headerHeight / 2)
            return .init(rect: r, rowY: y, cardinality: e.cardinality)
        }
        return (anchor(ta, ref.from), anchor(tb, ref.to))
    }

    func edgePath(_ ref: Ref) -> CGPath? {
        guard let (a, b) = anchors(ref) else { return nil }
        return EdgeGeometry.path(from: a, to: b, sameTable: ref.from.tableID == ref.to.tableID)
    }

    func groupFrame(_ g: TableGroup) -> CGRect? {
        let rects = g.tableIDs.filter { positions[$0] != nil }.map(rect)
        guard !rects.isEmpty else { return nil }
        let u = rects.reduce(CGRect.null) { $0.union($1) }
        let pad = SchemaLayout.groupPadding
        return CGRect(x: u.minX - pad, y: u.minY - pad - SchemaLayout.groupTitleHeight,
                      width: u.width + pad * 2, height: u.height + pad * 2 + SchemaLayout.groupTitleHeight)
    }

    var contentBounds: CGRect {
        var r = schema.tables.map { rect($0.id) }.reduce(CGRect.null) { $0.union($1) }
        for g in schema.groups { if let f = groupFrame(g) { r = r.union(f) } }
        return r.isNull ? .zero : r
    }
}
