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
    /// The primary table (inspector, sidebar) and every selected table.
    var onSelect: ((String?, Set<String>) -> Void)?
    var onSelectRef: ((Int?) -> Void)?
    /// Tables were dragged or nudged: positions before and after, for the tables that moved.
    var onTablesMoved: ((_ old: [String: CGPoint], _ new: [String: CGPoint], _ isNudge: Bool) -> Void)?
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

    /// The primary selected table; always in `selectedTables` when set.
    private(set) var selection: String?
    private(set) var selectedTables: Set<String> = []
    /// Index into `scene.schema.refs` of the selected relationship.
    private(set) var selectedRef: Int?
    private var hovered: String?
    private var hoveredEdge: Int?
    private var rowHighlights: [CALayer] = []

    /// What is highlighted: a hovered/selected table with its relationships, or one relationship.
    private enum Focus: Equatable {
        case tables(Set<String>)
        case ref(Int)
    }
    private var currentFocus: Focus? {
        if let hovered { return .tables([hovered]) }
        if let selectedRef { return .ref(selectedRef) }
        return selectedTables.isEmpty ? nil : .tables(selectedTables)
    }
    /// What the last highlight pass applied, so the next one only touches layers that change.
    private var highlightedFocus: Focus?
    private var highlightedTables: Set<String> = []
    private var highlightedEdges: Set<Int> = []
    private var settleWork: DispatchWorkItem?
    private var tooltip: TooltipView?
    private var tooltipWork: DispatchWorkItem?
    /// Tables sliding to new positions (auto-arrange, undo, redo).
    private var slide: (from: [String: CGPoint], to: [String: CGPoint], start: CFTimeInterval, link: CADisplayLink)?

    private enum Drag {
        case pan(start: CGPoint, offset: CGPoint, edge: Int?)
        /// Moving every selected table. `collapse`: a plain click on a table that is part of a
        /// multi-selection selects only that table if the mouse goes up without moving.
        case tables(grab: CGPoint, origins: [String: CGPoint], collapse: String?, moved: Bool)
        /// Drag on the background: select the tables touching the rectangle (added to `base` with ⇧/⌘).
        /// Starts after a few points of movement; a plain click selects the line under it, or clears.
        case marquee(start: CGPoint, base: Set<String>, edge: Int?, active: Bool)
    }
    /// Space held: the next drag pans instead of selecting.
    private var spaceHeld = false
    private let marqueeLayer = CAShapeLayer()

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
        marqueeLayer.lineWidth = 1
        marqueeLayer.isHidden = true
        marqueeLayer.actions = ["path": NSNull(), "hidden": NSNull()]
        root.addSublayer(marqueeLayer)
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
        stopSlide()
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
        selectedTables = selectedTables.filter { newScene.schema.table(id: $0) != nil }
        if let s = selection, !selectedTables.contains(s) { selection = nil }
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
            marqueeLayer.strokeColor = theme.accent.cgColor
            marqueeLayer.fillColor = theme.accent.withAlphaComponent(0.1).cgColor
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
                let selected = selectedTables.contains(id)
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
        case .tables(let ids):
            related = ids
            for id in ids {
                for i in edgesByTable[id] ?? [] {
                    edges.insert(i)
                    related.insert(scene.schema.refs[i].from.tableID)
                    related.insert(scene.schema.refs[i].to.tableID)
                }
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
        center(on: id)
    }

    /// Scrolls (and zooms in if tiny) to a table without changing the selection.
    func center(on id: String) {
        guard let scene, scene.schema.table(id: id) != nil else { return }
        let r = scene.rect(id)
        let z = max(zoom, min(1, (bounds.height - 80) / r.height))
        setViewport(zoom: z, offset: CGPoint(x: bounds.midX - r.midX * z, y: bounds.midY - r.midY * z), animated: true)
    }

    func select(_ id: String?) {
        setSelection(id.map { [$0] } ?? [], primary: id)
    }

    /// Adds a table to the selection, or removes it if it's already selected.
    func toggle(_ id: String) {
        var tables = selectedTables
        if tables.remove(id) == nil {
            tables.insert(id)
            setSelection(tables, primary: id)
        } else {
            setSelection(tables, primary: selection == id ? nil : selection)
        }
    }

    /// Selects tables; `primary` falls back to one of them (first in the schema) when it isn't in the set.
    func setSelection(_ tables: Set<String>, primary: String?) {
        guard let scene else { return }
        let tables = tables.filter { scene.schema.table(id: $0) != nil }
        let primary = primary.flatMap { tables.contains($0) ? $0 : nil }
            ?? (tables.isEmpty ? nil : scene.schema.tables.first { tables.contains($0.id) }?.id)
        if selectedRef != nil {
            selectedRef = nil
            updateRowHighlights()
            onSelectRef?(nil)
        }
        guard tables != selectedTables || primary != selection else { applyHighlight(); return }
        selectedTables = tables
        selection = primary
        applySelectionRing()
        applyHighlight()
        onSelect?(primary, tables)
    }

    /// Edit → Select All (⌘A) while the diagram has focus.
    override func selectAll(_ sender: Any?) {
        guard let scene else { return }
        setSelection(Set(scene.schema.tables.map(\.id)), primary: selection)
    }

    /// Selects a relationship; `reveal` zooms so both of its tables are in view.
    func selectRef(_ i: Int?, reveal: Bool = false) {
        guard let scene else { return }
        let i = i.flatMap { $0 < scene.schema.refs.count ? $0 : nil }
        if i != nil, !selectedTables.isEmpty {
            selection = nil
            selectedTables = []
            applySelectionRing()
            onSelect?(nil, [])
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
        let extend = !e.modifierFlags.intersection([.shift, .command]).isEmpty
        if let id = hitTable(p) {
            if e.clickCount == 2, !extend { focus(table: id); return }
            var collapse: String?
            if extend {
                toggle(id)
                // Toggled off: nothing to drag.
                guard selectedTables.contains(id) else { return }
            } else if selectedTables.contains(id), selectedTables.count > 1 {
                // Keep the group so it can be dragged; a click without a drag selects just this one.
                setSelection(selectedTables, primary: id)
                collapse = id
            } else {
                select(id)
            }
            finishSlide()
            guard let scene else { return }
            let origins = Dictionary(uniqueKeysWithValues: selectedTables.compactMap { t in scene.positions[t].map { (t, $0) } })
            drag = .tables(grab: toWorld(p), origins: origins, collapse: collapse, moved: false)
            // Bring to front, keeping the grabbed table on top.
            withoutAnimation {
                for t in selectedTables where t != id { if let l = tableLayers[t] { tablesLayer.addSublayer(l) } }
                if let l = tableLayers[id] { tablesLayer.addSublayer(l) }
            }
        } else if spaceHeld {
            startPan(at: p)
        } else {
            let edge = hitEdge(p)
            if let edge, e.clickCount == 2, !extend { selectRef(edge, reveal: true); return }
            drag = .marquee(start: p, base: extend ? selectedTables : [], edge: edge, active: false)
        }
    }

    private func startPan(at p: CGPoint) {
        drag = .pan(start: p, offset: offset, edge: nil)
        NSCursor.closedHand.push()
    }

    // Right- or middle-button drag pans too.
    override func rightMouseDown(with e: NSEvent) { hideTooltip(); startPan(at: convert(e.locationInWindow, from: nil)) }
    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func rightMouseUp(with e: NSEvent) { mouseUp(with: e) }
    override func otherMouseDown(with e: NSEvent) { rightMouseDown(with: e) }
    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .pan(let start, let o, _):
            setViewport(zoom: zoom, offset: CGPoint(x: o.x + p.x - start.x, y: o.y + p.y - start.y))
        case .tables(let grab, let origins, let collapse, _):
            let w = toWorld(p)
            let dx = (w.x - grab.x).rounded(), dy = (w.y - grab.y).rounded()
            setPositions(origins.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            drag = .tables(grab: grab, origins: origins, collapse: collapse, moved: true)
        case .marquee(let start, let base, let edge, let active):
            guard active || hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
            if !active { drag = .marquee(start: start, base: base, edge: edge, active: true) }
            updateMarquee(from: start, to: p, base: base)
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
        case .tables(_, let origins, let collapse, let moved):
            let new = Dictionary(uniqueKeysWithValues: origins.keys.compactMap { t in scene?.positions[t].map { (t, $0) } })
            if moved, new != origins {
                onTablesMoved?(origins, new, false)
            } else if let collapse {
                select(collapse)
            }
        case .marquee(_, _, let edge, let active):
            marqueeLayer.isHidden = true
            // A click (not a drag): select the line under it, or clear the selection.
            if !active {
                let extend = !e.modifierFlags.intersection([.shift, .command]).isEmpty
                if let edge, !extend { selectRef(edge) } else if !extend { clearSelection() }
            }
        case nil: break
        }
        drag = nil
    }

    private func updateMarquee(from start: CGPoint, to p: CGPoint, base: Set<String>) {
        guard let scene else { return }
        let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        marqueeLayer.path = CGPath(rect: r, transform: nil)
        marqueeLayer.isHidden = false
        let a = toWorld(r.origin), b = toWorld(CGPoint(x: r.maxX, y: r.maxY))
        let world = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        var hits = base
        for t in scene.schema.tables where scene.rect(t.id).intersects(world) { hits.insert(t.id) }
        if hits != selectedTables { setSelection(hits, primary: selection) }
    }

    private func nudge(by dir: CGPoint, step: CGFloat) {
        finishSlide()
        guard let scene else { return }
        let old = Dictionary(uniqueKeysWithValues: selectedTables.compactMap { t in scene.positions[t].map { (t, $0) } })
        let new = old.mapValues { CGPoint(x: $0.x + dir.x * step, y: $0.y + dir.y * step) }
        setPositions(new)
        hideTooltip()
        onTablesMoved?(old, new, true)
    }

    /// Moves tables and re-paths their edges and group frames, each edge and group once.
    private func setPositions(_ moved: [String: CGPoint]) {
        guard scene != nil else { return }
        var edges = Set<Int>()
        var groups = Set<String>()
        withoutAnimation {
            for (id, origin) in moved where scene!.positions[id] != nil {
                scene!.positions[id] = origin
                tableLayers[id]?.position = origin
                edges.formUnion(edgesByTable[id] ?? [])
                if let g = scene!.style.groupOf[id] { groups.insert(g) }
            }
            for i in edges {
                edgeLayers[i].path = scene!.edgePath(scene!.schema.refs[i])
                edgeBoxes[i] = edgeLayers[i].path?.boundingBoxOfPath ?? .null
            }
            for g in groups { updateGroupFrames(only: g) }
        }
    }

    /// Moves tables to new positions, sliding them there when `animated`.
    /// Positions of tables that aren't in the scene are ignored.
    func movePositions(_ target: [String: CGPoint], animated: Bool) {
        finishSlide()
        guard let scene else { return }
        let target = target.filter { scene.positions[$0.key] != nil && scene.positions[$0.key] != $0.value }
        guard !target.isEmpty else { return }
        // Re-pathing hundreds of edges per frame isn't smooth; big moves jump.
        guard animated, target.count <= 400, window != nil else { setPositions(target); return }
        let from = Dictionary(uniqueKeysWithValues: target.keys.map { ($0, scene.positions[$0]!) })
        let link = displayLink(target: self, selector: #selector(slideStep))
        slide = (from, target, CACurrentMediaTime(), link)
        link.add(to: .main, forMode: .common)
    }

    @objc private func slideStep(_ link: CADisplayLink) {
        guard let s = slide else { link.invalidate(); return }
        let t = min(1, (CACurrentMediaTime() - s.start) / 0.25)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2  // ease in-out
        var frame: [String: CGPoint] = [:]
        for (id, end) in s.to {
            let a = s.from[id] ?? end
            frame[id] = CGPoint(x: (a.x + (end.x - a.x) * e).rounded(), y: (a.y + (end.y - a.y) * e).rounded())
        }
        setPositions(frame)
        if t >= 1 { stopSlide() }
    }

    /// Jumps a running slide to its end.
    private func finishSlide() {
        guard let s = slide else { return }
        stopSlide()
        setPositions(s.to)
    }

    private func stopSlide() {
        slide?.link.invalidate()
        slide = nil
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
            if !spaceHeld { (edge == nil ? NSCursor.arrow : NSCursor.pointingHand).set() }
        }
        if let edge { updateEdgeTooltip(at: p, ref: edge) } else { updateTooltip(at: p, table: id) }
    }

    override func mouseExited(with e: NSEvent) {
        if hovered != nil { hovered = nil; applyHighlight() }
        if hoveredEdge != nil { hoveredEdge = nil; NSCursor.arrow.set() }
        hideTooltip()
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 {  // space: hold to pan with a drag
            if !spaceHeld { spaceHeld = true; NSCursor.openHand.push() }
            return
        }
        let arrows: [UInt16: CGPoint] = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0), 125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)]
        if let dir = arrows[e.keyCode], !selectedTables.isEmpty {
            nudge(by: dir, step: e.modifierFlags.contains(.shift) ? 10 : 1)
            return
        }
        switch e.charactersIgnoringModifiers {
        case "\u{1B}": clearSelection()  // Esc
        case "f" where e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: zoomToFit()
        default: super.keyDown(with: e)
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49, spaceHeld { spaceHeld = false; NSCursor.pop(); return }
        super.keyUp(with: e)
    }

    override func resignFirstResponder() -> Bool {
        if spaceHeld { spaceHeld = false; NSCursor.pop() }
        return super.resignFirstResponder()
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
