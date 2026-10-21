// Draws the app icon at 1024px: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.08, green: 0.10, blue: 0.17, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    func card(_ r: NSRect, _ header: NSColor, rows: Int) {
        let path = NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26)
        NSColor.white.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        header.setFill()
        NSRect(x: r.minX, y: r.maxY - 70, width: r.width, height: 70).fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        for i in 0..<rows {
            NSBezierPath(roundedRect: NSRect(x: r.minX + 28, y: r.maxY - 112 - CGFloat(i) * 46, width: r.width * (i % 2 == 0 ? 0.62 : 0.45), height: 14), xRadius: 7, yRadius: 7).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    let a = NSRect(x: 190, y: 430, width: 290, height: 340)
    let b = NSRect(x: 560, y: 250, width: 280, height: 290)
    let link = NSBezierPath()
    link.move(to: NSPoint(x: a.maxX, y: a.maxY - 150))
    link.curve(to: NSPoint(x: b.minX, y: b.maxY - 110), controlPoint1: NSPoint(x: a.maxX + 90, y: a.maxY - 150), controlPoint2: NSPoint(x: b.minX - 90, y: b.maxY - 110))
    link.lineWidth = 16
    link.lineCapStyle = .round
    NSColor(srgbRed: 0.45, green: 0.65, blue: 1, alpha: 1).setStroke()
    link.stroke()
    card(a, NSColor(srgbRed: 0.24, green: 0.39, blue: 0.87, alpha: 1), rows: 5)
    card(b, NSColor(srgbRed: 0.84, green: 0.38, blue: 0.10, alpha: 1), rows: 4)
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
