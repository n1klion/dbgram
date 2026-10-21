import AppKit
import DBMLKit

struct Theme: Equatable {
    var isDark: Bool
    var background: NSColor
    var tableBody: NSColor
    var tableBorder: NSColor
    var text: NSColor
    var secondaryText: NSColor
    var divider: NSColor
    var edge: NSColor
    var accent: NSColor
    var pk: NSColor
    var fk: NSColor
    var shadowOpacity: Float

    static let light = Theme(
        isDark: false,
        background: NSColor(hex: "#F4F5F7")!,
        tableBody: .white,
        tableBorder: NSColor(hex: "#DDE1E6")!,
        text: NSColor(hex: "#1D2129")!,
        secondaryText: NSColor(hex: "#7A828E")!,
        divider: NSColor(hex: "#EEF0F3")!,
        edge: NSColor(hex: "#A3ABB7")!,
        accent: NSColor(hex: "#2F6FEB")!,
        pk: NSColor(hex: "#D99A0B")!,
        fk: NSColor(hex: "#5B8DEF")!,
        shadowOpacity: 0.10)

    static let dark = Theme(
        isDark: true,
        background: NSColor(hex: "#15171C")!,
        tableBody: NSColor(hex: "#1F2229")!,
        tableBorder: NSColor(hex: "#30343D")!,
        text: NSColor(hex: "#E7E9EE")!,
        secondaryText: NSColor(hex: "#8A92A0")!,
        divider: NSColor(hex: "#292D35")!,
        edge: NSColor(hex: "#58606E")!,
        accent: NSColor(hex: "#5B9BFF")!,
        pk: NSColor(hex: "#F2B84B")!,
        fk: NSColor(hex: "#7EA6F5")!,
        shadowOpacity: 0.45)

    static func current(_ appearance: NSAppearance) -> Theme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

enum Metrics {
    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 26
    static let padding: CGFloat = 12
    static let iconColumn: CGFloat = 20
    static let minWidth: CGFloat = 190
    static let maxWidth: CGFloat = 460
    static let cornerRadius: CGFloat = 10

    static let headerFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let schemaFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    static let columnFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    static let pkColumnFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let groupFont = NSFont.systemFont(ofSize: 15, weight: .bold)
}

/// Header colors when the schema doesn't specify one: pleasant, distinguishable, readable with white text.
enum Palette {
    static let colors = ["#3E63DD", "#0E9F8E", "#D6409F", "#E5484D", "#8E4EC6", "#F76B15", "#12A594", "#5B5BD6", "#AB4ABA", "#0090FF"]
        .compactMap { NSColor(hex: $0) }
    static let neutral = NSColor(hex: "#5E6B7D")!

    static func color(_ i: Int) -> NSColor { colors[i % colors.count] }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

/// Resolved, render-ready view of a schema: colors per table and group, sizes measured once.
struct SceneStyle {
    var headerColors: [String: NSColor] = [:]
    var groupColors: [String: NSColor] = [:]
    var groupOf: [String: String] = [:]

    init(schema: Schema) {
        for (i, g) in schema.groups.enumerated() {
            let color = g.color.flatMap(NSColor.init(hex:))
                ?? Self.dominantHeaderColor(g, schema)
                ?? Palette.color(i)
            groupColors[g.name] = color
            for t in g.tableIDs { groupOf[t] = g.name }
        }
        for t in schema.tables {
            headerColors[t.id] = t.headerColor.flatMap(NSColor.init(hex:))
                ?? groupOf[t.id].flatMap { groupColors[$0] }
                ?? (schema.groups.isEmpty ? Palette.color(0) : Palette.neutral)
        }
    }

    private static func dominantHeaderColor(_ g: TableGroup, _ schema: Schema) -> NSColor? {
        var counts: [String: Int] = [:]
        for id in g.tableIDs {
            if let c = schema.table(id: id)?.headerColor?.lowercased() { counts[c, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }.flatMap { NSColor(hex: $0.key) }
    }
}
