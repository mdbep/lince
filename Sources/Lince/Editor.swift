import AppKit

// MARK: - Lienzo

/// Dibuja solo las anotaciones; la imagen va en una capa aparte para no repintarla al arrastrar.
final class AnnotationView: NSView, NSTextFieldDelegate {
    var baseImage: CGImage?
    var imageSize: CGSize = .zero
    var unit: CGFloat = 1
    var tool: EditorTool = .arrow
    var strokeWidth: CGFloat = 4
    var color: NSColor = .systemRed {
        didSet { activeField?.textColor = color }
    }
    var onToolKey: ((EditorTool) -> Void)?
    var onHistoryChange: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Se llama al cambiar la selección, para que la paleta refleje su color y grosor.
    var onSelectionChange: ((Annotation?) -> Void)?

    var annotations: [Annotation] = [] {
        didSet {
            needsDisplay = true
            onHistoryChange?()
        }
    }
    private(set) var selectedIndex: Int? {
        didSet {
            needsDisplay = true
            if oldValue != selectedIndex { onSelectionChange?(selected) }
        }
    }
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var current: Annotation?
    private var activeField: NSTextField?

    private enum Drag {
        case none
        case move(last: CGPoint)
        case handle(point: Int)
    }
    private var drag = Drag.none
    private var dragDidChange = false

    private var factor: CGFloat { imageSize.width > 0 ? bounds.width / imageSize.width : 1 }
    private func textFontSize(for width: CGFloat) -> CGFloat { (10 + width * 2.6) * unit }

    var selected: Annotation? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return nil }
        return annotations[selectedIndex]
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    func toolDidChange() {
        commitText()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Historial

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Guarda el estado actual antes de modificarlo, para poder deshacer.
    private func checkpoint() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    func undo() {
        if activeField != nil {
            cancelText()
            return
        }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        selectedIndex = nil
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        selectedIndex = nil
        annotations = next
    }

    private func add(_ annotation: Annotation, select: Bool) {
        checkpoint()
        annotations.append(annotation)
        selectedIndex = select ? annotations.count - 1 : nil
    }

    func reset() {
        current = nil
        selectedIndex = nil
        undoStack.removeAll()
        redoStack.removeAll()
        annotations.removeAll()
    }

    // MARK: Cambios sobre la selección

    func deselect() { selectedIndex = nil }

    func deleteSelected() {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        checkpoint()
        self.selectedIndex = nil
        annotations.remove(at: selectedIndex)
    }

    /// Fija el color actual y, si hay algo seleccionado, se lo aplica.
    func apply(color newColor: NSColor) {
        color = newColor
        guard let selectedIndex, annotations.indices.contains(selectedIndex),
              annotations[selectedIndex].color != newColor else { return }
        checkpoint()
        annotations[selectedIndex].color = newColor
    }

    /// Fija el grosor actual y, si hay algo seleccionado, se lo aplica.
    func apply(strokeWidth newWidth: CGFloat) {
        strokeWidth = newWidth
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        var annotation = annotations[selectedIndex]
        guard annotation.tool != .pixelate else { return }
        if annotation.tool == .text {
            guard annotation.fontSize != textFontSize(for: newWidth) else { return }
            annotation.fontSize = textFontSize(for: newWidth)
        } else {
            guard annotation.width != newWidth * unit else { return }
            annotation.width = newWidth * unit
        }
        checkpoint()
        annotations[selectedIndex] = annotation
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        checkpoint()
        annotations[selectedIndex].translate(dx: dx * unit, dy: dy * unit)
        refreshPixelCache(at: selectedIndex)
    }

    private func refreshPixelCache(at index: Int) {
        guard annotations[index].tool == .pixelate, let baseImage else { return }
        annotations[index].cache = Annotation.pixelated(baseImage, rect: annotations[index].frame, block: 9 * unit)
    }

    // MARK: Dibujo

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: factor, y: factor)
        for annotation in annotations { annotation.draw(in: context, base: baseImage) }
        current?.draw(in: context, base: baseImage)
        context.restoreGState()
        if let selected { drawSelection(of: selected, in: context) }
    }

    /// Tiradores de la anotación, en coordenadas de imagen.
    private func handles(of annotation: Annotation) -> [CGPoint] {
        guard annotation.tool.isTwoPoint, annotation.points.count >= 2 else { return [] }
        if annotation.tool == .arrow || annotation.tool == .line {
            return [annotation.points[0], annotation.points[1]]
        }
        let frame = annotation.frame
        return [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
    }

    private func drawSelection(of annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let accent = Theme.accent.cgColor
        if annotation.tool != .arrow && annotation.tool != .line {
            let box = annotation.bounds.applying(CGAffineTransform(scaleX: factor, y: factor)).insetBy(dx: -5, dy: -5)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1)
            context.stroke(box)
            context.setStrokeColor(accent)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.stroke(box)
            context.setLineDash(phase: 0, lengths: [])
        }
        for handle in handles(of: annotation) {
            let center = CGPoint(x: handle.x * factor, y: handle.y * factor)
            let circle = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                              color: NSColor.black.withAlphaComponent(0.45).cgColor)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(accent)
            context.setLineWidth(2)
            context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        }
    }

    /// Devuelve la imagen original con las anotaciones fundidas a resolución completa.
    func render(over image: CGImage) -> CGImage? {
        commitText()
        guard !annotations.isEmpty else { return image }
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for annotation in annotations { annotation.draw(in: context, base: image) }
        return context.makeImage()
    }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 36, 76: onReturn?()                                  // Intro
        case 51, 117: selected != nil ? deleteSelected() : undo() // Borrar
        case 53: deselect()                                       // Esc
        case 123 where selected != nil: nudge(dx: -step, dy: 0)
        case 124 where selected != nil: nudge(dx: step, dy: 0)
        case 125 where selected != nil: nudge(dx: 0, dy: -step)
        case 126 where selected != nil: nudge(dx: 0, dy: step)
        default:
            if let key = event.charactersIgnoringModifiers?.lowercased(),
               let match = EditorTool.allCases.first(where: { $0.key == key }) {
                onToolKey?(match)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Ratón

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / factor, y: point.y / factor)
    }

    /// La anotación más alta bajo el punto, si la hay.
    private func annotationIndex(at point: CGPoint) -> Int? {
        let tolerance = 6 / factor
        return annotations.indices.reversed().first { annotations[$0].hitTest(point, tolerance: tolerance) }
    }

    override func mouseDown(with event: NSEvent) {
        if activeField != nil {
            commitText()
            if tool == .text { return }
        }
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        drag = .none
        dragDidChange = false

        // 1. Un tirador de la anotación seleccionada.
        if let selectedIndex, let annotation = selected {
            let reach = 9 / factor
            let grips = handles(of: annotation)
            if let grip = grips.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= reach }) {
                if annotation.tool == .arrow || annotation.tool == .line {
                    drag = .handle(point: grip)
                } else {
                    // Se reordena para que el punto arrastrado sea el segundo y el opuesto quede fijo.
                    let opposite = grips[(grip + 2) % 4]
                    annotations[selectedIndex].points = [opposite, grips[grip]]
                    drag = .handle(point: 1)
                }
                return
            }
        }

        // 2. Seleccionar o mover: con la herramienta de selección, o sobre lo ya seleccionado.
        let hit = annotationIndex(at: point)
        if tool == .select {
            selectedIndex = hit
            if hit != nil { drag = .move(last: point) }
            return
        }
        if let hit, hit == selectedIndex {
            drag = .move(last: point)
            return
        }

        // 3. Dibujar algo nuevo.
        selectedIndex = nil
        switch tool {
        case .select:
            break
        case .text:
            beginText(at: convert(event.locationInWindow, from: nil))
        case .counter:
            let number = annotations.filter { $0.tool == .counter }.count + 1
            add(Annotation(tool: .counter, points: [point], color: color,
                           width: strokeWidth * unit, unit: unit, text: "\(number)"), select: true)
            drag = .move(last: point)
            dragDidChange = true
        default:
            current = Annotation(tool: tool, points: [point, point], color: color,
                                 width: strokeWidth * unit, unit: unit)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var point = imagePoint(event)

        switch drag {
        case .move(let last):
            guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
            if !dragDidChange {
                checkpoint()
                dragDidChange = true
            }
            annotations[selectedIndex].translate(dx: point.x - last.x, dy: point.y - last.y)
            drag = .move(last: point)
            return
        case .handle(let index):
            guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
            if !dragDidChange {
                checkpoint()
                dragDidChange = true
            }
            var annotation = annotations[selectedIndex]
            if event.modifierFlags.contains(.shift) {
                point = AnnotationView.constrain(point, from: annotation.points[1 - index], tool: annotation.tool)
            }
            annotation.points[index] = point
            annotation.cache = nil
            annotations[selectedIndex] = annotation
            return
        case .none:
            break
        }

        guard var annotation = current else { return }
        if annotation.tool.isFreehand {
            annotation.points.append(point)
        } else {
            if event.modifierFlags.contains(.shift) {
                point = AnnotationView.constrain(point, from: annotation.points[0], tool: annotation.tool)
            }
            annotation.points[1] = point
        }
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .none = drag {} else {
            if dragDidChange, let selectedIndex, annotations.indices.contains(selectedIndex) {
                refreshPixelCache(at: selectedIndex)
            }
            drag = .none
            return
        }
        guard var annotation = current else { return }
        current = nil
        let first = annotation.points[0], last = annotation.points[annotation.points.count - 1]
        if annotation.tool.isFreehand || hypot(last.x - first.x, last.y - first.y) > 2 * unit {
            if annotation.tool == .pixelate, let baseImage {
                annotation.cache = Annotation.pixelated(baseImage, rect: annotation.frame, block: 9 * unit)
            }
            // Lo recién dibujado queda seleccionado para poder retocarlo al momento.
            add(annotation, select: !annotation.tool.isFreehand)
        }
        needsDisplay = true
    }

    /// Con ⇧: cuadrados y círculos perfectos, y líneas en saltos de 45°.
    private static func constrain(_ point: CGPoint, from origin: CGPoint, tool: EditorTool) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        switch tool {
        case .rectangle, .ellipse, .pixelate:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
        default:
            let length = hypot(dx, dy)
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
        }
    }

    // MARK: Texto

    private func beginText(at point: CGPoint) {
        let fontSize = textFontSize(for: strokeWidth) * factor
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color
        field.placeholderString = "Texto"
        field.delegate = self
        let height = ceil(fontSize * 1.3) + 4
        field.frame = CGRect(x: point.x, y: point.y - height / 2,
                             width: max(80, bounds.maxX - point.x - 4), height: height)
        addSubview(field)
        activeField = field
        window?.makeFirstResponder(field)
    }

    func commitText() {
        guard let field = activeField else { return }
        activeField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // El campo deja 2 pt de margen interior antes del texto.
        let origin = CGPoint(x: (field.frame.minX + 2) / factor, y: (field.frame.minY + 2) / factor)
        let fontSize = (field.font?.pointSize ?? 18) / factor
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        add(Annotation(tool: .text, points: [origin], color: color, width: 0, unit: unit,
                       text: text, fontSize: fontSize), select: true)
    }

    private func cancelText() {
        guard let field = activeField else { return }
        activeField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    /// Para las capturas internas de revisión de diseño.
    func debugSelect(_ index: Int) { selectedIndex = index }
}

final class CanvasView: NSView {
    private let backdropHost = NSView()
    private let gradient = CAGradientLayer()
    private let shadowHost = NSView()
    let imageHost = NSView()
    let annotationView = AnnotationView()
    /// Espacio reservado para la barra superior y la paleta flotante.
    var insets = NSEdgeInsets(top: 76, left: 28, bottom: 92, right: 28)
    var unit: CGFloat = 1
    /// La imagen ya trae sus propias esquinas y sombra (una ventana): no se le añaden otras.
    var hasTransparency = false { didSet { needsLayout = true } }
    /// Fondo degradado alrededor de la captura; `nil` la deja tal cual.
    var backdrop: BackdropChoice? { didSet { needsLayout = true } }
    private var imageSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.canvas.cgColor
        backdropHost.wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        backdropHost.layer?.addSublayer(gradient)
        backdropHost.isHidden = true
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.masksToBounds = false
        imageHost.wantsLayer = true
        imageHost.layer?.contentsGravity = .resize
        imageHost.layer?.minificationFilter = .trilinear
        imageHost.layer?.masksToBounds = true
        imageHost.layer?.cornerCurve = .continuous
        annotationView.wantsLayer = true
        annotationView.layer?.masksToBounds = true
        annotationView.layer?.cornerCurve = .continuous
        for view in [backdropHost, shadowHost, imageHost, annotationView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    func setImage(_ image: CGImage) {
        imageSize = CGSize(width: image.width, height: image.height)
        imageHost.layer?.contents = image
        annotationView.baseImage = image
        annotationView.imageSize = imageSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let available = CGRect(x: insets.left, y: insets.bottom,
                               width: max(bounds.width - insets.left - insets.right, 10),
                               height: max(bounds.height - insets.top - insets.bottom, 10))
        let pad = backdrop.map { Backdrop.padding(for: imageSize, level: $0.padding) } ?? 0
        let total = CGSize(width: imageSize.width + pad * 2, height: imageSize.height + pad * 2)
        let ratio = min(available.width / total.width, available.height / total.height)
        let size = CGSize(width: floor(imageSize.width * ratio), height: floor(imageSize.height * ratio))
        let inset = floor(pad * ratio)
        let outer = CGSize(width: size.width + inset * 2, height: size.height + inset * 2)
        let outerFrame = CGRect(x: floor(available.midX - outer.width / 2), y: floor(available.midY - outer.height / 2),
                                width: outer.width, height: outer.height)
        let frame = outerFrame.insetBy(dx: inset, dy: inset)

        withoutActions {
            backdropHost.isHidden = backdrop == nil
            backdropHost.frame = outerFrame
            gradient.frame = backdropHost.bounds
            if let backdrop { gradient.colors = Backdrop.styles[backdrop.style].cgColors }

            // Lo que se ve aquí debe coincidir con la imagen final que compone `Backdrop.compose`.
            let framed = backdrop != nil && !hasTransparency
            let radius = framed ? Backdrop.cornerRadius(unit: unit) * ratio : 0
            imageHost.frame = frame
            imageHost.layer?.cornerRadius = radius
            annotationView.frame = frame
            annotationView.layer?.cornerRadius = radius

            shadowHost.frame = frame
            shadowHost.isHidden = hasTransparency
            shadowHost.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                                                  cornerWidth: radius, cornerHeight: radius, transform: nil)
            if framed {
                shadowHost.layer?.shadowOpacity = Float(Backdrop.shadowOpacity)
                shadowHost.layer?.shadowRadius = Backdrop.shadowBlur(unit: unit) * ratio / 2
                shadowHost.layer?.shadowOffset = CGSize(width: 0, height: Backdrop.shadowOffset(unit: unit) * ratio)
            } else {
                shadowHost.layer?.shadowOpacity = 0.55
                shadowHost.layer?.shadowRadius = 26
                shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -10)
            }
        }
        annotationView.needsDisplay = true
    }
}

// MARK: - Controles de la paleta

final class SwatchView: NSView {
    let color: NSColor
    var onClick: (() -> Void)?
    var isSelected = false { didSet { refresh(animated: true) } }
    private let dot = CALayer()
    private let ring = CALayer()

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        ring.borderColor = color.cgColor
        ring.borderWidth = 2
        dot.backgroundColor = color.cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        dot.borderWidth = 0.5
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    override func layout() {
        super.layout()
        refresh(animated: false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { springScale(to: 0.85) }
    override func mouseUp(with event: NSEvent) {
        springScale(to: 1, stiffness: 380, damping: 14)
        onClick?()
    }

    private func refresh(animated: Bool) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dotSize: CGFloat = isSelected ? 12 : 16
        let ringSize: CGFloat = isSelected ? 22 : 14
        let apply = {
            self.dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            self.dot.cornerRadius = dotSize / 2
            self.dot.position = center
            self.ring.bounds = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
            self.ring.cornerRadius = ringSize / 2
            self.ring.position = center
            self.ring.opacity = self.isSelected ? 1 : 0
        }
        if animated { withLayerAnimation(0.18, apply) } else { withoutActions(apply) }
    }
}

/// Botón de grosor: un punto cuyo tamaño representa el trazo.
final class WidthButton: HoverButton {
    private let dot = CALayer()
    private let diameter: CGFloat

    init(diameter: CGFloat, tooltip: String) {
        self.diameter = diameter
        super.init(size: CGSize(width: 28, height: 30), tooltip: tooltip)
        dot.backgroundColor = NSColor.white.cgColor
        dot.cornerRadius = diameter / 2
        layer?.addSublayer(dot)
        selectedColor = NSColor.white.withAlphaComponent(0.16)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    override func layout() {
        super.layout()
        withoutActions {
            dot.frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                               width: diameter, height: diameter)
        }
    }

    override func refresh(animated: Bool) {
        super.refresh(animated: animated)
        dot.opacity = isSelected || isHovering ? 1 : 0.6
    }
}

// MARK: - Ventana

final class EditorWindow: NSWindow {
    weak var editor: EditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // Mientras se escribe texto, los atajos de edición van al campo.
        if firstResponder is NSText {
            let action: Selector?
            switch key {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default: action = nil
            }
            if let action {
                return NSApp.sendAction(action, to: nil, from: self)
            }
        }
        switch key {
        case "z": flags.contains(.shift) ? editor?.redo() : editor?.undo()
        case "c": editor?.copyImage()
        case "s": editor?.save()
        case "w": performClose(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class EditorController: NSObject, NSWindowDelegate {
    let capture: Capture
    var onUpdate: (() -> Void)?
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?

    let window: EditorWindow
    let canvas = CanvasView()
    private var toolButtons: [HoverButton] = []
    private var swatches: [SwatchView] = []
    private var widthButtons: [WidthButton] = []
    private var undoButton: HoverButton!
    private var redoButton: HoverButton!
    private var copyButton: HoverButton!
    private var backdropButton: HoverButton!
    private var backdropPopover: NSPopover?
    private var backdropSwatches: [BackdropSwatch] = []
    private var paddingButtons: [HoverButton] = []
    private var paddingLevel = 1

    private let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        Theme.accent,
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .black,
        .white,
    ]
    private let widths: [CGFloat] = [2.5, 4, 7]

    init(capture: Capture) {
        self.capture = capture
        let screen = NSScreen.underMouse.visibleFrame
        let chrome = CGSize(width: 56, height: 168)
        canvas.unit = capture.scale
        canvas.hasTransparency = capture.hasTransparency
        let maxSize = CGSize(width: screen.width * 0.82 - chrome.width, height: screen.height * 0.86 - chrome.height)
        let ratio = min(maxSize.width / capture.pointSize.width, maxSize.height / capture.pointSize.height, 1)
        let content = CGSize(width: max(800, capture.pointSize.width * ratio + chrome.width),
                             height: max(500, capture.pointSize.height * ratio + chrome.height))
        window = EditorWindow(contentRect: CGRect(origin: .zero, size: content),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        window.editor = self
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = "Editar captura"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.canvas
        window.isMovableByWindowBackground = true
        window.minSize = CGSize(width: 800, height: 460)
        buildContent()
        canvas.setImage(capture.image)
        canvas.annotationView.unit = capture.scale
        canvas.annotationView.onToolKey = { [weak self] tool in self?.select(tool: tool) }
        canvas.annotationView.onReturn = { [weak self] in self?.done() }
        canvas.annotationView.onHistoryChange = { [weak self] in self?.refreshHistoryButtons() }
        canvas.annotationView.onSelectionChange = { [weak self] annotation in self?.syncPalette(with: annotation) }
        select(tool: Settings.editorTool == 0 ? .arrow : (EditorTool(rawValue: Settings.editorTool) ?? .arrow))
        select(colorIndex: min(Settings.editorColor, colors.count - 1))
        select(widthIndex: min(Settings.editorWidth, widths.count - 1))
        refreshHistoryButtons()
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas.annotationView)
    }

    // MARK: Construcción

    private func buildContent() {
        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)

        let topBar = buildTopBar()
        root.addSubview(topBar)
        let palette = buildPalette()
        root.addSubview(palette)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            palette.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            palette.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            palette.heightAnchor.constraint(equalToConstant: 48),
        ])
        window.contentView = root
    }

    private func buildTopBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.chrome.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)

        let title = NSTextField(labelWithString: "Editar captura")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.9)
        let detail = NSTextField(labelWithString: "\(capture.image.width) × \(capture.image.height) px")
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor.white.withAlphaComponent(0.45)
        let titles = NSStackView(views: [title, detail])
        titles.spacing = 8
        titles.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(titles)

        undoButton = HoverButton(symbol: "arrow.uturn.backward", symbolSize: 12,
                                 size: CGSize(width: 30, height: 28), tooltip: "Deshacer (⌘Z)")
        undoButton.onClick = { [weak self] in self?.undo() }
        redoButton = HoverButton(symbol: "arrow.uturn.forward", symbolSize: 12,
                                 size: CGSize(width: 30, height: 28), tooltip: "Rehacer (⇧⌘Z)")
        redoButton.onClick = { [weak self] in self?.redo() }

        backdropButton = HoverButton(symbol: "rectangle.inset.filled", title: "Fondo", symbolSize: 11,
                                     tooltip: "Poner la captura sobre un fondo")
        backdropButton.normalColor = NSColor.white.withAlphaComponent(0.08)
        backdropButton.hoverColor = NSColor.white.withAlphaComponent(0.15)
        backdropButton.onClick = { [weak self] in self?.showBackdropPicker() }

        copyButton = HoverButton(symbol: "doc.on.doc", title: "Copiar", symbolSize: 11, tooltip: "Copiar (⌘C)")
        copyButton.normalColor = NSColor.white.withAlphaComponent(0.08)
        copyButton.hoverColor = NSColor.white.withAlphaComponent(0.15)
        copyButton.onClick = { [weak self] in self?.copyImage() }

        let saveButton = HoverButton(symbol: "square.and.arrow.down", title: "Guardar", symbolSize: 11,
                                     tooltip: "Guardar (⌘S)")
        saveButton.normalColor = NSColor.white.withAlphaComponent(0.08)
        saveButton.hoverColor = NSColor.white.withAlphaComponent(0.15)
        saveButton.onClick = { [weak self] in self?.save() }

        let doneButton = HoverButton(title: "Listo", tooltip: "Aplicar y cerrar (↩)")
        doneButton.normalColor = Theme.accent
        doneButton.hoverColor = Theme.accent.blended(withFraction: 0.12, of: .white) ?? Theme.accent
        doneButton.normalTint = .white
        doneButton.onClick = { [weak self] in self?.done() }

        let actions = NSStackView(views: [undoButton, redoButton, backdropButton, copyButton, saveButton, doneButton])
        actions.spacing = 8
        actions.setCustomSpacing(2, after: undoButton)
        actions.setCustomSpacing(14, after: redoButton)
        actions.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(actions)

        let titleCenter = titles.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        titleCenter.priority = .defaultLow
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            titleCenter,
            titles.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 84),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16),
            titles.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func buildPalette() -> NSView {
        let palette = NSView()
        palette.wantsLayer = true
        palette.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 0.98).cgColor
        palette.layer?.cornerRadius = 15
        palette.layer?.cornerCurve = .continuous
        palette.layer?.borderWidth = 1
        palette.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        palette.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            return shadow
        }()
        palette.translatesAutoresizingMaskIntoConstraints = false

        toolButtons = EditorTool.allCases.map { tool in
            let button = HoverButton(symbol: tool.symbol, symbolSize: 13.5, size: CGSize(width: 32, height: 32),
                                     tooltip: "\(tool.label) (\(tool.key.uppercased()))")
            button.cornerRadius = 9
            button.onClick = { [weak self] in self?.select(tool: tool) }
            return button
        }
        let toolStack = NSStackView(views: toolButtons)
        toolStack.spacing = 2

        swatches = colors.enumerated().map { index, color in
            let swatch = SwatchView(color: color)
            swatch.onClick = { [weak self] in self?.select(colorIndex: index) }
            return swatch
        }
        let colorStack = NSStackView(views: swatches)
        colorStack.spacing = 0

        let labels = ["Fino", "Medio", "Grueso"]
        widthButtons = widths.enumerated().map { index, _ in
            let button = WidthButton(diameter: [4, 7, 11][index], tooltip: "Trazo \(labels[index].lowercased())")
            button.onClick = { [weak self] in self?.select(widthIndex: index) }
            return button
        }
        let widthStack = NSStackView(views: widthButtons)
        widthStack.spacing = 0

        let stack = NSStackView(views: [toolStack, divider(), colorStack, divider(), widthStack])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        palette.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: palette.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: palette.trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: palette.centerYAnchor),
        ])
        return palette
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 22),
        ])
        return view
    }

    // MARK: Estado

    func select(tool: EditorTool) {
        for (index, button) in toolButtons.enumerated() { button.isSelected = index == tool.rawValue }
        canvas.annotationView.tool = tool
        canvas.annotationView.toolDidChange()
        Settings.editorTool = tool.rawValue
    }

    private func select(colorIndex: Int) {
        for (index, swatch) in swatches.enumerated() { swatch.isSelected = index == colorIndex }
        canvas.annotationView.apply(color: colors[colorIndex])
        Settings.editorColor = colorIndex
    }

    private func select(widthIndex: Int) {
        for (index, button) in widthButtons.enumerated() { button.isSelected = index == widthIndex }
        canvas.annotationView.apply(strokeWidth: widths[widthIndex])
        Settings.editorWidth = widthIndex
    }

    /// Al seleccionar una anotación, la paleta pasa a mostrar su color y su grosor.
    private func syncPalette(with annotation: Annotation?) {
        guard let annotation else { return }
        if annotation.tool != .pixelate, let colorIndex = colors.firstIndex(of: annotation.color) {
            for (index, swatch) in swatches.enumerated() { swatch.isSelected = index == colorIndex }
            canvas.annotationView.color = colors[colorIndex]
        }
        guard annotation.tool != .text, annotation.tool != .pixelate else { return }
        let width = annotation.width / capture.scale
        if let widthIndex = widths.indices.min(by: { abs(widths[$0] - width) < abs(widths[$1] - width) }) {
            for (index, button) in widthButtons.enumerated() { button.isSelected = index == widthIndex }
            canvas.annotationView.strokeWidth = widths[widthIndex]
        }
    }

    private func refreshHistoryButtons() {
        undoButton.isEnabled = canvas.annotationView.canUndo
        redoButton.isEnabled = canvas.annotationView.canRedo
    }

    // MARK: Acciones

    func undo() { canvas.annotationView.undo() }
    func redo() { canvas.annotationView.redo() }

    // MARK: Fondo

    private func showBackdropPicker() {
        if let backdropPopover, backdropPopover.isShown {
            backdropPopover.close()
            return
        }
        backdropSwatches = [BackdropSwatch(style: nil)] + Backdrop.styles.map { BackdropSwatch(style: $0) }
        for (index, swatch) in backdropSwatches.enumerated() {
            swatch.onClick = { [weak self] in self?.selectBackdrop(index == 0 ? nil : index - 1) }
        }
        let swatchRow = NSStackView(views: backdropSwatches)
        swatchRow.spacing = 2

        let label = NSTextField(labelWithString: "Margen")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        paddingButtons = ["Pequeño", "Medio", "Grande"].enumerated().map { index, title in
            let button = HoverButton(title: title, fontSize: 11.5, padding: 10, height: 24)
            button.cornerRadius = nil
            button.normalColor = NSColor.white.withAlphaComponent(0.08)
            button.onClick = { [weak self] in self?.selectPadding(index) }
            return button
        }
        let paddingRow = NSStackView(views: [label] + paddingButtons)
        paddingRow.spacing = 6
        paddingRow.setCustomSpacing(12, after: label)

        let stack = NSStackView(views: [swatchRow, paddingRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        let controller = NSViewController()
        controller.view = stack

        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        backdropPopover = popover
        refreshBackdropPicker()
        popover.show(relativeTo: backdropButton.bounds, of: backdropButton, preferredEdge: .maxY)
    }

    private func selectBackdrop(_ style: Int?) {
        canvas.backdrop = style.map { BackdropChoice(style: $0, padding: paddingLevel) }
        backdropButton.isSelected = style != nil
        refreshBackdropPicker()
    }

    private func selectPadding(_ level: Int) {
        paddingLevel = level
        if let current = canvas.backdrop {
            canvas.backdrop = BackdropChoice(style: current.style, padding: level)
        }
        refreshBackdropPicker()
    }

    private func refreshBackdropPicker() {
        let selected = canvas.backdrop.map { $0.style + 1 } ?? 0
        for (index, swatch) in backdropSwatches.enumerated() { swatch.isSelected = index == selected }
        for (index, button) in paddingButtons.enumerated() { button.isSelected = index == paddingLevel }
    }

    /// La imagen final: anotaciones fundidas y, si se eligió, el fondo.
    private func output() -> CGImage? {
        guard let rendered = canvas.annotationView.render(over: capture.image) else { return nil }
        guard let backdrop = canvas.backdrop else { return rendered }
        return Backdrop.compose(rendered, choice: backdrop, unit: capture.scale,
                                hasTransparency: capture.hasTransparency) ?? rendered
    }

    /// Para las capturas internas de revisión de diseño.
    func debugSetBackdrop(_ choice: BackdropChoice?) -> CGImage? {
        canvas.backdrop = choice
        backdropButton.isSelected = choice != nil
        return output()
    }

    func copyImage() {
        guard let rendered = output() else { return }
        Capture.copy(image: rendered, png: Capture.encodePNG(rendered, scale: capture.scale))
        copyButton.setTitle("Copiado")
        copyButton.setSymbol("checkmark", size: 11)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setTitle("Copiar")
            self?.copyButton.setSymbol("doc.on.doc", size: 11)
        }
    }

    func save() {
        flatten()
        do {
            try capture.saveToDefaultFolder()
            onSaved?()
            window.close()
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    func done() {
        flatten()
        window.close()
    }

    /// Funde las anotaciones en la captura para que la miniatura y el archivo las incluyan.
    private func flatten() {
        guard let rendered = output(), rendered !== capture.image else { return }
        if canvas.backdrop != nil {
            // El fondo ya forma parte de la imagen: deja de ser transparente y no se aplica dos veces.
            capture.hasTransparency = false
            canvas.hasTransparency = false
            canvas.backdrop = nil
            backdropButton.isSelected = false
        }
        capture.update(image: rendered)
        canvas.annotationView.reset()
        canvas.setImage(rendered)
        onUpdate?()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
