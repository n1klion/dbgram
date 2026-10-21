import AppKit
import DBMLKit

/// One cached bitmap per table. It is redrawn only when its content, theme or resolution changes,
/// never while panning, zooming or dragging.
final class TableLayer: CALayer {
    var table: Table!
    var header: NSColor = Palette.neutral
    var theme: Theme = .light

    override init() {
        super.init()
        needsDisplayOnBoundsChange = false
        anchorPoint = .zero
        drawsAsynchronously = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let table else { return }
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        TableRenderer.draw(table, size: bounds.size, header: header, theme: theme, in: ctx)
    }
}

final class DiagramCanvas: NSView {
    // Callbacks to the document model.
    var onSelect: ((String?) -> Void)?
    var onSelectRef: ((Int?) -> Void)?
    var onTablesMoved: (([String: CGPoint]) -> Void)?
    var onViewportChanged: ((CGFloat, CGPoint) -> Void)?

    private(set) var scene: DiagramScene?
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    private var theme: Theme = .light

    private let root = CALayer()
    private let world = CALayer()
    private let groupsLayer = CALayer()
    private let edgesLayer = CALayer()
    private let tablesLayer = CALayer()

    private var tableLayers: [String: TableLayer] = [:]
    private var edgeLayers: [CAShapeLayer] = []
    private var edgeBaseColors: [CGColor] = []
    /// World-space bounds of each edge path, for cheap hit-test rejection.
    private var edgeBoxes: [CGRect] = []
    private var edgesByTable: [String: [Int]] = [:]
    private var groupLayers: [String: (frame: CAShapeLayer, title: CATextLayer)] = [:]

    private(set) var selection: String?
    /// Index into `scene.schema.refs` of the selected relationship.
    private(set) var selectedRef: Int?
    private var hovered: String?
    private var hoveredEdge: Int?
    private var rowHighlights: [CALayer] = []

    /// What is highlighted: a hovered/selected table with its relationships, or one relationship.
    private enum Focus: Equatable {
        case table(String)
        case ref(Int)
    }
    private var currentFocus: Focus? {
        if let hovered { return .table(hovered) }
        if let selectedRef { return .ref(selectedRef) }
        return selection.map { .table($0) }
    }
    /// What the last highlight pass applied, so the next one only touches layers that change.
    private var highlightedFocus: Focus?
    private var highlightedTables: Set<String> = []
    private var highlightedEdges: Set<Int> = []
    private var settleWork: DispatchWorkItem?
    private var tooltip: TooltipView?
    private var tooltipWork: DispatchWorkItem?

    private enum Drag {
        case pan(start: CGPoint, offset: CGPoint, edge: Int?)
        case table(id: String, grab: CGPoint, moved: Bool)
    }
    private var drag: Drag?

    static let minZoom: CGFloat = 0.04
    static let maxZoom: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: we own the whole layer tree.
        layer = root
        wantsLayer = true
        root.isGeometryFlipped = true
        root.masksToBounds = true
        root.actions = ["sublayers": NSNull(), "contents": NSNull(), "bounds": NSNull()]
        world.anchorPoint = .zero
        world.bounds = .zero
        for l in [groupsLayer, edgesLayer, tablesLayer] {
            l.anchorPoint = .zero
            l.bounds = .zero
            world.addSublayer(l)
        }
        root.addSublayer(world)
        updateTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTheme()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleSettle(delay: 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: content

    /// Installs a new scene. Table layers whose table didn't change are reused as-is.
    func load(_ newScene: DiagramScene) {
        let oldTables = scene.map { Dictionary(uniqueKeysWithValues: $0.schema.tables.map { ($0.id, $0) }) } ?? [:]
        let oldStyle = scene?.style
        let oldRef = selectedRef.flatMap { i in scene.flatMap { i < $0.schema.refs.count ? $0.schema.refs[i] : nil } }
        scene = newScene

        withoutAnimation {
            var keep: [String: TableLayer] = [:]
            for t in newScene.schema.tables {
                let header = newScene.style.headerColors[t.id] ?? Palette.neutral
                let layer: TableLayer
                if let existing = tableLayers[t.id], oldTables[t.id] == t, oldStyle?.headerColors[t.id] == header {
                    layer = existing
                } else {
                    tableLayers[t.id]?.removeFromSuperlayer()
                    layer = TableLayer()
                    layer.table = t
                    layer.header = header
                    layer.theme = theme
                    layer.contentsScale = desiredContentsScale()
                    configureShadow(layer)
                    tablesLayer.addSublayer(layer)
                    layer.setNeedsDisplay()
                }
                let r = newScene.rect(t.id)
                if layer.bounds.size != r.size {
                    layer.bounds = CGRect(origin: .zero, size: r.size)
                    layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: Metrics.cornerRadius, cornerHeight: Metrics.cornerRadius, transform: nil)
                }
                layer.position = r.origin
                keep[t.id] = layer
            }
            for (id, l) in tableLayers where keep[id] == nil { l.removeFromSuperlayer() }
            tableLayers = keep

            rebuildEdges()
            rebuildGroups()
        }
        if let s = selection, newScene.schema.table(id: s) == nil { selection = nil }
        // The same relationship may have moved to another index (or another line) after an edit.
        let newRef = oldRef.flatMap { old in newScene.schema.refs.firstIndex { $0.from == old.from && $0.to == old.to } }
        if newRef != selectedRef {
            selectedRef = newRef
            onSelectRef?(newRef)
        }
        updateRowHighlights()
        applySelectionRing()
        applyHighlight(force: true)
        scheduleSettle(delay: 0)
    }

    private func configureShadow(_ layer: TableLayer) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = theme.shadowOpacity
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.cornerRadius = Metrics.cornerRadius
    }

    private func rebuildEdges() {
        edgeLayers.forEach { $0.removeFromSuperlayer() }
        edgeLayers = []
        edgeBoxes = []
        edgesByTable = [:]
        guard let scene else { return }
        for (i, ref) in scene.schema.refs.enumerated() {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.path = scene.edgePath(ref)
            edgesLayer.addSublayer(l)
            edgeLayers.append(l)
            edgeBoxes.append(l.path?.boundingBoxOfPath ?? .null)
            edgesByTable[ref.from.tableID, default: []].append(i)
            if ref.to.tableID != ref.from.tableID { edgesByTable[ref.to.tableID, default: []].append(i) }
        }
        cacheEdgeColors()
        styleEdges()
    }

    private func cacheEdgeColors() {
        edgeBaseColors = (scene?.schema.refs ?? []).map { ($0.color.flatMap(NSColor.init(hex:)) ?? theme.edge).cgColor }
    }

    private func rebuildGroups() {
        groupLayers.values.forEach { $0.frame.removeFromSuperlayer(); $0.title.removeFromSuperlayer() }
        groupLayers = [:]
        guard let scene else { return }
        for g in scene.schema.groups {
            let frame = CAShapeLayer()
            frame.lineWidth = 1.5
            frame.lineDashPattern = [6, 5]
            let title = CATextLayer()
            title.string = g.name
            title.font = Metrics.groupFont
            title.fontSize = Metrics.groupFont.pointSize
            title.anchorPoint = .zero
            title.contentsScale = backingScale
            groupsLayer.addSublayer(frame)
            groupsLayer.addSublayer(title)
            groupLayers[g.name] = (frame, title)
        }
        styleGroups()
        updateGroupFrames()
    }

    private func updateGroupFrames(only groupName: String? = nil) {
        guard let scene else { return }
        for g in scene.schema.groups where groupName == nil || g.name == groupName {
            guard let layers = groupLayers[g.name] else { continue }
            if let f = scene.groupFrame(g) {
                layers.frame.path = CGPath(roundedRect: f, cornerWidth: 16, cornerHeight: 16, transform: nil)
                let size = (g.name as NSString).size(withAttributes: [.font: Metrics.groupFont])
                layers.title.bounds = CGRect(origin: .zero, size: CGSize(width: size.width + 4, height: size.height + 2))
                layers.title.position = CGPoint(x: f.minX + 18, y: f.minY + 12)
                layers.frame.isHidden = false
                layers.title.isHidden = false
            } else {
                layers.frame.isHidden = true
                layers.title.isHidden = true
            }
        }
    }

    // MARK: theme & styling

    private func updateTheme() {
        let newTheme = Theme.current(effectiveAppearance)
        let changed = newTheme != theme
        theme = newTheme
        withoutAnimation {
            root.backgroundColor = theme.background.cgColor
            guard changed else { return }
            for l in tableLayers.values {
                l.theme = theme
                l.shadowOpacity = theme.shadowOpacity
                l.setNeedsDisplay()
            }
            cacheEdgeColors()
            styleEdges()
            styleGroups()
            applySelectionRing()
            updateRowHighlights()
        }
    }

    private func styleGroups() {
        guard let scene else { return }
        for (name, layers) in groupLayers {
            let color = scene.style.groupColors[name] ?? Palette.neutral
            layers.frame.fillColor = color.withAlphaComponent(theme.isDark ? 0.08 : 0.06).cgColor
            layers.frame.strokeColor = color.withAlphaComponent(0.35).cgColor
            layers.title.foregroundColor = GroupRenderer.titleColor(color, theme).cgColor
        }
    }

    private var edgeLineWidth: CGFloat { 1.5 * max(1, 0.5 / zoom) }

    private func styleEdges() {
        for i in edgeLayers.indices { styleEdge(i) }
    }

    private func edgeWidth(_ i: Int) -> CGFloat {
        if i == selectedRef && highlightedFocus == .ref(i) { return edgeLineWidth * 2.2 }
        return highlightedEdges.contains(i) ? edgeLineWidth * 1.4 : edgeLineWidth
    }

    /// Reads `highlightedFocus`/`highlightedEdges`, so set those before calling.
    private func styleEdge(_ i: Int) {
        guard i < edgeBaseColors.count else { return }
        let l = edgeLayers[i]
        let related = highlightedEdges.contains(i)
        l.strokeColor = related ? theme.accent.cgColor : edgeBaseColors[i]
        l.lineWidth = edgeWidth(i)
        l.opacity = highlightedFocus == nil || related ? 1 : 0.18
        l.zPosition = related ? 1 : 0
    }

    /// Tints the rows of the selected relationship's columns in both tables.
    private func updateRowHighlights() {
        withoutAnimation {
            rowHighlights.forEach { $0.removeFromSuperlayer() }
            rowHighlights = []
            guard let i = selectedRef, let scene, i < scene.schema.refs.count else { return }
            let ref = scene.schema.refs[i]
            for end in [ref.from, ref.to] {
                guard let table = scene.schema.table(id: end.tableID), let layer = tableLayers[end.tableID] else { continue }
                for name in end.columns {
                    guard let row = table.columnIndex(named: name) else { continue }
                    let h = CALayer()
                    h.frame = CGRect(x: 3, y: Metrics.headerHeight + CGFloat(row) * Metrics.rowHeight + 1,
                                     width: layer.bounds.width - 6, height: Metrics.rowHeight - 2)
                    h.backgroundColor = theme.accent.withAlphaComponent(theme.isDark ? 0.28 : 0.16).cgColor
                    h.borderColor = theme.accent.withAlphaComponent(0.6).cgColor
                    h.borderWidth = 1
                    h.cornerRadius = 5
                    layer.addSublayer(h)
                    rowHighlights.append(h)
                }
            }
        }
    }

    private func applySelectionRing() {
        withoutAnimation {
            for (id, l) in tableLayers {
                let selected = id == selection
                l.borderWidth = selected ? 2 : 0
                l.borderColor = theme.accent.cgColor
                l.zPosition = selected ? 1 : 0
            }
        }
    }

    /// Hovering or selecting a table highlights it, its neighbors and its relationships.
    /// Only layers whose state changes are touched: moving between tables updates a handful of
    /// layers; entering or leaving the "something is focused" state updates all of them once.
    private func applyHighlight(force: Bool = false) {
        guard let scene else { return }
        let focus = currentFocus
        if !force, focus == highlightedFocus { return }
        var related: Set<String> = []
        var edges: Set<Int> = []
        switch focus {
        case .table(let id):
            related.insert(id)
            for i in edgesByTable[id] ?? [] {
                edges.insert(i)
                related.insert(scene.schema.refs[i].from.tableID)
                related.insert(scene.schema.refs[i].to.tableID)
            }
        case .ref(let i) where i < scene.schema.refs.count:
            edges.insert(i)
            related = [scene.schema.refs[i].from.tableID, scene.schema.refs[i].to.tableID]
        default:
            break
        }
        let everything = force || (focus == nil) != (highlightedFocus == nil)
        let tableIDs: [String] = everything ? Array(tableLayers.keys) : Array(related.union(highlightedTables))
        let edgeIDs: Set<Int> = everything ? Set(edgeLayers.indices) : edges.union(highlightedEdges)
        highlightedFocus = focus
        highlightedTables = related
        highlightedEdges = edges

        CATransaction.begin()
        // Fading thousands of layers at once costs more than it's worth.
        if tableIDs.count + edgeIDs.count > 400 { CATransaction.setDisableActions(true) }
        else { CATransaction.setAnimationDuration(0.12) }
        for id in tableIDs { tableLayers[id]?.opacity = focus == nil || related.contains(id) ? 1 : 0.35 }
        for i in edgeIDs { styleEdge(i) }
        CATransaction.commit()
    }

    /// Debug: time hover changes across `count` tables.
    func benchmarkHover(count: Int) -> Double {
        let ids = Array(tableLayers.keys.prefix(count))
        let t0 = CACurrentMediaTime()
        for id in ids { hovered = id; applyHighlight(); CATransaction.flush() }
        hovered = nil; applyHighlight(); CATransaction.flush()
        return (CACurrentMediaTime() - t0) * 1000 / Double(max(1, ids.count))
    }

    // MARK: viewport

    func setViewport(zoom z: CGFloat, offset o: CGPoint, animated: Bool = false) {
        zoom = min(Self.maxZoom, max(Self.minZoom, z))
        offset = o
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        world.setAffineTransform(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: offset.x, ty: offset.y))
        CATransaction.commit()
        hideTooltip()
        scheduleSettle(delay: animated ? 0.3 : 0.12)
    }

    func zoom(by factor: CGFloat, at p: CGPoint? = nil, animated: Bool = false) {
        let anchor = p ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let newZoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        let worldPoint = toWorld(anchor)
        setViewport(zoom: newZoom, offset: CGPoint(x: anchor.x - worldPoint.x * newZoom, y: anchor.y - worldPoint.y * newZoom), animated: animated)
    }

    func zoomToFit(animated: Bool = true) {
        guard let scene, bounds.width > 0 else { return }
        fit(scene.contentBounds, maxZoom: 1.2, animated: animated)
    }

    func fit(_ rect: CGRect, maxZoom: CGFloat, animated: Bool) {
        guard rect.width > 0, rect.height > 0 else { return }
        let margin: CGFloat = 40
        let z = min(maxZoom, (bounds.width - margin * 2) / rect.width, (bounds.height - margin * 2) / rect.height)
        let zz = min(Self.maxZoom, max(Self.minZoom, z))
        setViewport(zoom: zz, offset: CGPoint(x: bounds.midX - rect.midX * zz, y: bounds.midY - rect.midY * zz), animated: animated)
    }

    func focus(table id: String) {
        guard let scene, scene.schema.table(id: id) != nil else { return }
        select(id)
        let r = scene.rect(id)
        let z = max(zoom, min(1, (bounds.height - 80) / r.height))
        setViewport(zoom: z, offset: CGPoint(x: bounds.midX - r.midX * z, y: bounds.midY - r.midY * z), animated: true)
    }

    func select(_ id: String?) {
        if selectedRef != nil {
            selectedRef = nil
            updateRowHighlights()
            onSelectRef?(nil)
        }
        guard selection != id else { applyHighlight(); return }
        selection = id
        applySelectionRing()
        applyHighlight()
        onSelect?(id)
    }

    /// Selects a relationship; `reveal` zooms so both of its tables are in view.
    func selectRef(_ i: Int?, reveal: Bool = false) {
        guard let scene else { return }
        let i = i.flatMap { $0 < scene.schema.refs.count ? $0 : nil }
        if i != nil, selection != nil {
            selection = nil
            applySelectionRing()
            onSelect?(nil)
        }
        if i != selectedRef {
            selectedRef = i
            updateRowHighlights()
            applyHighlight()
            onSelectRef?(i)
        }
        if reveal, let i {
            let ref = scene.schema.refs[i]
            fit(scene.rect(ref.from.tableID).union(scene.rect(ref.to.tableID)), maxZoom: max(zoom, 1), animated: true)
        }
    }

    func clearSelection() {
        select(nil)
    }

    private func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }

    private var visibleWorldRect: CGRect {
        CGRect(x: -offset.x / zoom, y: -offset.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    /// Bitmap resolution steps; quantized so small zoom changes don't trigger redraws.
    private func desiredContentsScale() -> CGFloat {
        let steps: [CGFloat] = [0.25, 0.5, 1, 2, 3]
        let needed = steps.first { $0 >= zoom } ?? 3
        return needed * backingScale
    }

    private func scheduleSettle(delay: TimeInterval) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// After the viewport stops changing: re-rasterize visible tables at the right resolution
    /// and shrink the bitmaps of off-screen tables that are larger than needed.
    private func settle() {
        guard scene != nil else { return }
        let desired = desiredContentsScale()
        let visible = visibleWorldRect.insetBy(dx: -visibleWorldRect.width * 0.25, dy: -visibleWorldRect.height * 0.25)
        withoutAnimation {
            for l in tableLayers.values {
                let onScreen = l.frame.intersects(visible)
                let target = onScreen ? desired : min(desired, backingScale)
                if l.contentsScale != target && (onScreen || l.contentsScale > target) {
                    l.contentsScale = target
                    l.setNeedsDisplay()
                }
            }
            for i in edgeLayers.indices { edgeLayers[i].lineWidth = edgeWidth(i) }
            for g in groupLayers.values { g.title.contentsScale = min(desired, backingScale * 3) }
        }
        onViewportChanged?(zoom, offset)
    }

    // MARK: input

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) || !e.hasPreciseScrollingDeltas {
            let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            zoom(by: exp(delta), at: p)
        } else {
            setViewport(zoom: zoom, offset: CGPoint(x: offset.x + e.scrollingDeltaX, y: offset.y + e.scrollingDeltaY))
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, at: convert(e.locationInWindow, from: nil))
    }

    override func smartMagnify(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if zoom < 0.9 { zoom(by: 1 / zoom, at: p, animated: true) } else { zoomToFit() }
    }

    private func hitTable(_ viewPoint: CGPoint) -> String? {
        guard let scene else { return nil }
        let p = toWorld(viewPoint)
        if let s = selection, scene.rect(s).contains(p) { return s }
        // Topmost first: later sublayers draw on top.
        for l in (tablesLayer.sublayers ?? []).reversed() {
            if let t = l as? TableLayer, l.frame.contains(p) { return t.table.id }
        }
        return nil
    }

    /// The relationship line under a point, if any. Bounding boxes reject almost all edges cheaply;
    /// only the few left are tested against their stroked outline.
    private func hitEdge(_ viewPoint: CGPoint) -> Int? {
        let p = toWorld(viewPoint)
        let tolerance = 6 / zoom
        var best: Int?
        for i in edgeBoxes.indices where edgeBoxes[i].insetBy(dx: -tolerance, dy: -tolerance).contains(p) {
            guard let path = edgeLayers[i].path,
                  path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p) else { continue }
            // Prefer highlighted lines: they are drawn on top.
            if best == nil || edgeLayers[i].zPosition > edgeLayers[best!].zPosition { best = i }
        }
        return best
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        hideTooltip()
        let p = convert(e.locationInWindow, from: nil)
        if let id = hitTable(p) {
            if e.clickCount == 2 { focus(table: id); return }
            select(id)
            let origin = scene?.positions[id] ?? .zero
            let w = toWorld(p)
            drag = .table(id: id, grab: CGPoint(x: w.x - origin.x, y: w.y - origin.y), moved: false)
            // Bring to front.
            if let l = tableLayers[id] { withoutAnimation { tablesLayer.addSublayer(l) } }
        } else {
            let edge = hitEdge(p)
            if let edge, e.clickCount == 2 { selectRef(edge, reveal: true); return }
            drag = .pan(start: p, offset: offset, edge: edge)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .pan(let start, let o, _):
            setViewport(zoom: zoom, offset: CGPoint(x: o.x + p.x - start.x, y: o.y + p.y - start.y))
        case .table(let id, let grab, _):
            let w = toWorld(p)
            moveTable(id, to: CGPoint(x: (w.x - grab.x).rounded(), y: (w.y - grab.y).rounded()))
            drag = .table(id: id, grab: grab, moved: true)
        case nil: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .pan(let start, _, let edge):
            NSCursor.pop()
            let p = convert(e.locationInWindow, from: nil)
            // A click (not a drag): select the line under it, or clear the selection.
            if hypot(p.x - start.x, p.y - start.y) < 3 {
                if let edge { selectRef(edge) } else { clearSelection() }
            }
        case .table(let id, _, let moved):
            if moved, let pos = scene?.positions[id] { onTablesMoved?([id: pos]) }
        case nil: break
        }
        drag = nil
    }

    private func moveTable(_ id: String, to origin: CGPoint) {
        guard scene != nil else { return }
        scene!.positions[id] = origin
        withoutAnimation {
            tableLayers[id]?.position = origin
            for i in edgesByTable[id] ?? [] {
                edgeLayers[i].path = scene!.edgePath(scene!.schema.refs[i])
                edgeBoxes[i] = edgeLayers[i].path?.boundingBoxOfPath ?? .null
            }
            if let g = scene!.style.groupOf[id] { updateGroupFrames(only: g) }
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let id = hitTable(p)
        if id != hovered {
            hovered = id
            applyHighlight()
        }
        let edge = id == nil ? hitEdge(p) : nil
        if edge != hoveredEdge {
            hoveredEdge = edge
            (edge == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        }
        if let edge { updateEdgeTooltip(at: p, ref: edge) } else { updateTooltip(at: p, table: id) }
    }

    override func mouseExited(with e: NSEvent) {
        if hovered != nil { hovered = nil; applyHighlight() }
        if hoveredEdge != nil { hoveredEdge = nil; NSCursor.arrow.set() }
        hideTooltip()
    }

    override func keyDown(with e: NSEvent) {
        switch e.charactersIgnoringModifiers {
        case "\u{1B}": clearSelection()  // Esc
        case "f" where e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: zoomToFit()
        default: super.keyDown(with: e)
        }
    }

    // MARK: tooltips (table and column notes)

    private func updateTooltip(at p: CGPoint, table id: String?) {
        guard let id, let scene, let table = scene.schema.table(id: id), drag == nil else { hideTooltip(); return }
        let local = toWorld(p).applying(CGAffineTransform(translationX: -scene.rect(id).minX, y: -scene.rect(id).minY))
        guard let row = TableRenderer.row(at: local.y, in: table) else { hideTooltip(); return }
        let text: NSAttributedString?
        if row == -1 {
            text = table.note.map { Self.tooltipText(title: table.displayName, detail: nil, body: $0) }
        } else {
            let c = table.columns[row]
            var details: [String] = [c.type]
            if c.isPrimaryKey { details.append("PK") }
            if c.isNotNull { details.append("not null") }
            if c.isUnique { details.append("unique") }
            if let d = c.defaultValue { details.append("default \(d)") }
            text = c.note.map { Self.tooltipText(title: c.name, detail: details.joined(separator: " · "), body: $0) }
        }
        showTooltip(text, key: "\(id)#\(row)", at: p)
    }

    private func updateEdgeTooltip(at p: CGPoint, ref i: Int) {
        guard let scene, drag == nil, i < scene.schema.refs.count else { hideTooltip(); return }
        let r = RelationText(scene.schema.refs[i])
        showTooltip(Self.tooltipText(title: "\(r.from) → \(r.to)", detail: r.kind, body: "Click to inspect, double-click to show both tables"),
                    key: "ref#\(i)", at: p)
    }

    private func showTooltip(_ text: NSAttributedString?, key: String, at p: CGPoint) {
        if tooltip?.key == key { return }
        hideTooltip()
        guard let text else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let tip = TooltipView(text: text, key: key)
            var origin = CGPoint(x: p.x + 14, y: p.y + 18)
            origin.x = min(origin.x, self.bounds.width - tip.frame.width - 8)
            if origin.y + tip.frame.height > self.bounds.height - 8 { origin.y = p.y - tip.frame.height - 10 }
            tip.setFrameOrigin(origin)
            tip.alphaValue = 0
            self.addSubview(tip)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; tip.animator().alphaValue = 1 }
            self.tooltip = tip
        }
        tooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func hideTooltip() {
        tooltipWork?.cancel()
        tooltipWork = nil
        tooltip?.removeFromSuperview()
        tooltip = nil
    }

    private static func tooltipText(title: String, detail: String?, body: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        if let detail {
            s.append(NSAttributedString(string: "  " + detail, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        s.append(NSAttributedString(string: "\n" + body, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        return s
    }

    /// Debug aid: renders the live layer tree (what's on screen) to a PNG.
    func snapshot(to url: URL) {
        let scale = backingScale
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        // render(in:) ignores the root's geometry flip, so apply it here.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        root.render(in: ctx)
        if let image = ctx.makeImage() { try? ImageExporter.writePNG(image, to: url) }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

final class TooltipView: NSVisualEffectView {
    let key: String

    init(text: NSAttributedString, key: String) {
        self.key = key
        super.init(frame: .zero)
        material = .toolTip
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 340
        label.lineBreakMode = .byWordWrapping
        let size = label.sizeThatFits(NSSize(width: 340, height: 10_000))
        label.frame = NSRect(x: 10, y: 8, width: min(340, size.width), height: size.height)
        addSubview(label)
        frame = NSRect(x: 0, y: 0, width: label.frame.width + 20, height: label.frame.height + 16)
    }

    required init?(coder: NSCoder) { fatalError() }
}
