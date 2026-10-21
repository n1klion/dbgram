import AppKit
import DBMLKit
import UniformTypeIdentifiers

/// Renders a whole diagram into a bitmap, using the same drawing code as the canvas.
enum ImageExporter {
    static func render(_ scene: DiagramScene, theme: Theme, scale: CGFloat = 2) -> CGImage? {
        let margin: CGFloat = 48
        let bounds = scene.contentBounds.insetBy(dx: -margin, dy: -margin)
        // Keep huge diagrams under a sane bitmap size.
        let maxPixels: CGFloat = 16384
        let s = min(scale, maxPixels / max(bounds.width, 1), maxPixels / max(bounds.height, 1))
        let w = Int((bounds.width * s).rounded(.up)), h = Int((bounds.height * s).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }

        // Flip to a y-down coordinate system matching the canvas.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(bounds)

        for g in scene.schema.groups {
            guard let frame = scene.groupFrame(g), let color = scene.style.groupColors[g.name] else { continue }
            GroupRenderer.draw(name: g.name, frame: frame, color: color, theme: theme, in: ctx)
        }

        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for ref in scene.schema.refs {
            guard let path = scene.edgePath(ref) else { continue }
            ctx.addPath(path)
            ctx.setStrokeColor((ref.color.flatMap(NSColor.init(hex:)) ?? theme.edge).cgColor)
            ctx.strokePath()
        }

        for t in scene.schema.tables {
            let r = scene.rect(t.id)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(CGFloat(theme.shadowOpacity)).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: Metrics.cornerRadius, cornerHeight: Metrics.cornerRadius, transform: nil))
            ctx.setFillColor(theme.tableBody.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY)
            TableRenderer.draw(t, size: r.size, header: scene.style.headerColors[t.id] ?? Palette.neutral, theme: theme, in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// `DBGram --render input.dbml output.png [--dark] [--scale N]`
    static func runCommandLine(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--render"), args.count > i + 2 else {
            FileHandle.standardError.write("usage: DBGram --render input.dbml output.png [--dark] [--scale N]\n".data(using: .utf8)!)
            return 2
        }
        let input = URL(fileURLWithPath: args[i + 1]), output = URL(fileURLWithPath: args[i + 2])
        let scale = args.firstIndex(of: "--scale").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 2
        do {
            let t0 = Date()
            let source = try String(contentsOf: input, encoding: .utf8)
            let schema = DBML.parse(source)
            let t1 = Date()
            var scene = DiagramScene(schema: schema, positions: [:])
            scene.positions = SchemaLayout.compute(schema: schema, sizes: scene.sizes)
            let t2 = Date()
            guard let image = render(scene, theme: args.contains("--dark") ? .dark : .light, scale: CGFloat(scale)) else { return 1 }
            try writePNG(image, to: output)
            let t3 = Date()
            for d in schema.diagnostics { print("warning: \(d)") }
            print(String(format: "%d tables, %d refs | parse %.1fms, measure+layout %.1fms, render %.1fms",
                         schema.tables.count, schema.refs.count,
                         t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, t3.timeIntervalSince(t2) * 1000))
            return 0
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }
}

enum GroupRenderer {
    static func draw(name: String, frame: CGRect, color: NSColor, theme: Theme, in ctx: CGContext) {
        let path = CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color.withAlphaComponent(theme.isDark ? 0.08 : 0.06).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(color.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 5])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: name, attributes: [.font: Metrics.groupFont, .foregroundColor: titleColor(color, theme)])
            .draw(at: CGPoint(x: frame.minX + 18, y: frame.minY + 14))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func titleColor(_ color: NSColor, _ theme: Theme) -> NSColor {
        theme.isDark ? color.blended(withFraction: 0.35, of: .white) ?? color : color.blended(withFraction: 0.2, of: .black) ?? color
    }
}
