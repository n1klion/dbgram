import AppKit

/// Development aids driven by environment variables; inert in normal use.
/// `scripts/screenshots.sh` uses them to regenerate the README images.
enum DebugHooks {
    /// DBGRAM_SCREENSHOT=out.png renders the whole window to a PNG a few seconds after opening, then quits.
    /// Optional: DBGRAM_APPEARANCE=light|dark, DBGRAM_SELECT_TABLE=name,
    /// DBGRAM_SELECT_REF=table.column (a relationship by its source column).
    static func screenshotIfRequested(_ model: DocumentModel) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DBGRAM_SCREENSHOT"] else { return }
        if env["DBGRAM_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["DBGRAM_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            model.canvas?.window?.setContentSize(NSSize(width: 1440, height: 860))
            if let t = env["DBGRAM_SELECT_TABLE"] { model.select(t, focus: false) }
            if let r = env["DBGRAM_SELECT_REF"] {
                let parts = r.split(separator: ".", maxSplits: 1).map(String.init)
                if parts.count == 2, let i = model.schema.refs.firstIndex(where: { $0.from.tableID == parts[0] && $0.from.columns == [parts[1]] }) {
                    model.selectRef(i, reveal: false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { model.canvas?.zoomToFit(animated: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let window = model.canvas?.window, let image = render(window) {
                try? ImageExporter.writePNG(image, to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }

    /// Renders the window's own layer tree (no screen-recording permission needed).
    /// Blur materials come out flat, which is fine for documentation.
    private static func render(_ window: NSWindow) -> CGImage? {
        guard let frameView = window.contentView?.superview, let layer = frameView.layer else { return nil }
        let scale = window.backingScaleFactor, size = frameView.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
