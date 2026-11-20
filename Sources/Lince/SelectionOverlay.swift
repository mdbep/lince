import AppKit

/// Para qué se está seleccionando: cambia los textos de ayuda y lo que ocurre después.
enum SelectionPurpose {
    case image
    case text
    case timer(Int)

    var allowsWindows: Bool {
        if case .text = self { return false }
        return true
    }
}

enum SelectionResult {
    /// Un área recortada de la pantalla congelada, con su rectángulo en coordenadas globales.
    case area(shot: ScreenShot, rect: CGRect)
    case window(WindowInfo)
}

/// Muestra las pantallas "congeladas" y deja arrastrar un rectángulo o elegir una ventana.
final class SelectionController {
    private var windows: [SelectionWindow] = []
    private var completion: ((SelectionResult?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func begin(shots: [ScreenShot], windowList: [WindowInfo], purpose: SelectionPurpose,
               startInWindowMode: Bool, completion: @escaping (SelectionResult?) -> Void) {
        guard !isActive, !shots.isEmpty else {
            completion(nil)
            return
        }
        self.completion = completion
        let mouseScreen = NSScreen.underMouse

        for shot in shots {
            let view = SelectionView(shot: shot, windowList: windowList, purpose: purpose,
                                     showsHint: shot.screen == mouseScreen)
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onToggleWindowMode = { [weak self] in self?.toggleWindowMode() }
            windows.append(SelectionWindow(shot: shot, view: view))
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows where window.shot.screen != mouseScreen {
            window.orderFrontRegardless()
        }
        (windows.first { $0.shot.screen == mouseScreen } ?? windows[0]).makeKeyAndOrderFront(nil)
        if startInWindowMode, purpose.allowsWindows {
            toggleWindowMode()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func toggleWindowMode() {
        guard let first = windows.first else { return }
        let enabled = !first.selectionView.windowMode
        for window in windows { window.selectionView.setWindowMode(enabled) }
    }

    private func finish(_ result: SelectionResult?) {
        let done = completion
        completion = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        done?(result)
    }
}

final class SelectionWindow: NSWindow {
    let shot: ScreenShot
    let selectionView: SelectionView

    init(shot: ScreenShot, view: SelectionView) {
        self.shot = shot
        self.selectionView = view
        super.init(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        contentView = view
        setFrame(shot.screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Etiqueta redondeada sobre fondo oscuro (medidas, ayuda…).
final class PillLayer: CALayer {
    private let textLayer = CATextLayer()
    private let font: NSFont

    init(fontSize: CGFloat, scale: CGFloat, monospacedDigits: Bool = false) {
        font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
            : .systemFont(ofSize: fontSize, weight: .medium)
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        borderWidth = 0.5
        cornerCurve = .continuous
        textLayer.font = font
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale
        addSublayer(textLayer)
    }

    override init(layer: Any) {
        font = .systemFont(ofSize: 11)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    /// Ajusta el tamaño al texto y devuelve el tamaño resultante.
    @discardableResult
    func setText(_ text: String) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(measured.width) + 18, height: ceil(measured.height) + 8)
        textLayer.string = text
        bounds = CGRect(origin: .zero, size: size)
        cornerRadius = min(size.height / 2, 9)
        textLayer.frame = CGRect(x: 0, y: 4, width: size.width, height: ceil(measured.height))
        return size
    }
}

final class SelectionView: NSView {
    var onFinish: ((SelectionResult?) -> Void)?
    var onToggleWindowMode: (() -> Void)?
    private(set) var windowMode = false

    private let shot: ScreenShot
    private let windowList: [WindowInfo]
    private let purpose: SelectionPurpose

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let guideH = CALayer()
    private let guideV = CALayer()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let sizePill: PillLayer
    private let hintPill: PillLayer?

    private let loupeShadow = CALayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeReticle = CAShapeLayer()
    private let loupeSize: CGFloat = 112
    private let loupeZoom: CGFloat = 5

    private var anchor: CGPoint?
    private var lastDragPoint: CGPoint = .zero
    private var selection: CGRect = .zero
    private var cursor: CGPoint?
    private var hovered: WindowInfo?
    private var spaceDown = false
    private var didAppear = false

    /// Cursor de cámara para el modo ventana.
    private static let cameraCursor: NSCursor = {
        let size = NSSize(width: 30, height: 30)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor.black.withAlphaComponent(0.78).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
            if let symbol = Theme.symbol("camera.fill", size: 12, weight: .semibold) {
                let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
                    symbol.draw(in: symbolRect)
                    NSColor.white.set()
                    symbolRect.fill(using: .sourceAtop)
                    return true
                }
                let origin = NSPoint(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2)
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 15, y: 15))
    }()

    init(shot: ScreenShot, windowList: [WindowInfo], purpose: SelectionPurpose, showsHint: Bool) {
        self.shot = shot
        self.windowList = windowList
        self.purpose = purpose
        sizePill = PillLayer(fontSize: 11, scale: shot.scale, monospacedDigits: true)
        hintPill = showsHint ? PillLayer(fontSize: 12, scale: shot.scale) : nil
        super.init(frame: .zero)
        wantsLayer = true

        imageLayer.contents = shot.image
        imageLayer.contentsGravity = .resize

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor

        for guide in [guideH, guideV] {
            guide.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            guide.shadowColor = NSColor.black.cgColor
            guide.shadowOpacity = 0.5
            guide.shadowRadius = 0.5
            guide.shadowOffset = .zero
            guide.isHidden = true
        }

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        borderLayer.shadowColor = NSColor.black.cgColor
        borderLayer.shadowOpacity = 0.55
        borderLayer.shadowRadius = 3
        borderLayer.shadowOffset = .zero

        highlightLayer.fillColor = Theme.accent.withAlphaComponent(0.05).cgColor
        highlightLayer.strokeColor = Theme.accent.cgColor
        highlightLayer.lineWidth = 2.5
        highlightLayer.isHidden = true

        sizePill.isHidden = true

        // Lupa: la misma imagen ampliada, recortada en círculo.
        loupeShadow.backgroundColor = NSColor.black.cgColor
        loupeShadow.cornerRadius = loupeSize / 2
        loupeShadow.shadowColor = NSColor.black.cgColor
        loupeShadow.shadowOpacity = 0.45
        loupeShadow.shadowRadius = 10
        loupeShadow.shadowOffset = CGSize(width: 0, height: -3)
        loupe.cornerRadius = loupeSize / 2
        loupe.masksToBounds = true
        loupe.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        loupe.borderWidth = 2
        loupeImage.contents = shot.image
        loupeImage.contentsGravity = .resize
        loupeImage.magnificationFilter = .nearest
        loupe.addSublayer(loupeImage)
        let center = loupeSize / 2
        let reticle = CGMutablePath()
        reticle.addRect(CGRect(x: center - loupeZoom / 2, y: center - loupeZoom / 2,
                               width: loupeZoom, height: loupeZoom))
        loupeReticle.path = reticle
        loupeReticle.fillColor = nil
        loupeReticle.strokeColor = NSColor.white.cgColor
        loupeReticle.lineWidth = 1
        loupeReticle.shadowColor = NSColor.black.cgColor
        loupeReticle.shadowOpacity = 0.8
        loupeReticle.shadowRadius = 1
        loupeReticle.shadowOffset = .zero
        loupe.addSublayer(loupeReticle)
        loupeShadow.isHidden = true
        loupe.isHidden = true

        var layers: [CALayer] = [imageLayer, dimLayer, guideH, guideV, borderLayer, highlightLayer,
                                 sizePill, loupeShadow, loupe]
        if let hintPill {
            hintPill.setText(hintText)
            layers.append(hintPill)
        }
        for sublayer in layers { layer?.addSublayer(sublayer) }

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    private var hintText: String {
        let cancel = "Esc para cancelar"
        if windowMode {
            return "Haz clic en una ventana para capturarla   ·   Espacio para volver al área   ·   \(cancel)"
        }
        switch purpose {
        case .image:
            return "Arrastra para seleccionar   ·   Espacio para capturar una ventana   ·   \(cancel)"
        case .text:
            return "Selecciona la zona con el texto que quieres copiar   ·   \(cancel)"
        case .timer(let seconds):
            return "Temporizador de \(seconds) s: elige el área o pulsa Espacio para una ventana   ·   \(cancel)"
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        withoutActions {
            imageLayer.frame = bounds
            dimLayer.frame = bounds
            borderLayer.frame = bounds
            highlightLayer.frame = bounds
            if let hintPill {
                hintPill.position = CGPoint(x: bounds.midX, y: bounds.maxY - 64)
            }
        }
        updateLayers()
        if !didAppear, bounds.width > 0 {
            didAppear = true
            if !Theme.reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.16
                dimLayer.add(fade, forKey: "appear")
                hintPill?.add(fade, forKey: "appear")
            }
            if let window, NSMouseInRect(NSEvent.mouseLocation, window.frame, false) {
                cursor = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                updateHover()
                updateLayers()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: windowMode ? SelectionView.cameraCursor : .crosshair)
    }

    // MARK: - Modo ventana

    func setWindowMode(_ enabled: Bool) {
        windowMode = enabled
        anchor = nil
        selection = .zero
        hintPill?.setText(hintText)
        if let hintPill { withLayerAnimation(0.15) { hintPill.opacity = 1 } }
        window?.invalidateCursorRects(for: self)
        (enabled ? SelectionView.cameraCursor : NSCursor.crosshair).set()
        updateHover()
        updateLayers()
    }

    /// La ventana más alta que hay bajo el ratón.
    private func updateHover() {
        guard windowMode else {
            hovered = nil
            return
        }
        let location = NSEvent.mouseLocation
        hovered = cursor == nil ? nil : windowList.first { $0.frame.contains(location) }
    }

    private func localRect(of info: WindowInfo) -> CGRect {
        guard let window else { return .zero }
        return convert(window.convertFromScreen(info.frame), from: nil).intersection(bounds)
    }

    // MARK: - Eventos

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        updateHover()
        updateLayers()
    }

    override func mouseExited(with event: NSEvent) {
        guard anchor == nil else { return }
        cursor = nil
        hovered = nil
        updateLayers()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if let hintPill, hintPill.opacity > 0 {
            withLayerAnimation(0.2) { hintPill.opacity = 0 }
        }
        if windowMode {
            updateHover()
            if let hovered { onFinish?(.window(hovered)) }
            return
        }
        anchor = point
        lastDragPoint = point
        selection = .zero
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode, var start = anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if spaceDown {
            // Con Espacio pulsado se desplaza toda la selección en lugar de redimensionarla.
            start.x += point.x - lastDragPoint.x
            start.y += point.y - lastDragPoint.y
            anchor = start
        }
        lastDragPoint = point
        cursor = point

        var dx = point.x - start.x, dy = point.y - start.y
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect = CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy),
                          width: abs(dx), height: abs(dy))
        selection = rect.intersection(bounds)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil }
        guard !windowMode, anchor != nil else { return }
        guard selection.width >= 3, selection.height >= 3 else {
            // Un clic sin arrastrar no hace nada: se puede volver a intentar o cancelar con Esc.
            selection = .zero
            updateLayers()
            return
        }
        let factor = CGFloat(shot.image.width) / bounds.width
        let cropRect = CGRect(x: selection.minX * factor,
                              y: (bounds.height - selection.maxY) * factor,
                              width: selection.width * factor,
                              height: selection.height * factor).integral
        guard let cropped = shot.image.cropping(to: cropRect), let window else {
            onFinish?(nil)
            return
        }
        let screenRect = window.convertToScreen(convert(selection, to: nil))
        onFinish?(.area(shot: ScreenShot(image: cropped, screen: shot.screen, scale: shot.scale), rect: screenRect))
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onFinish?(nil)
        case 49: // Espacio: mueve la selección si se está arrastrando; si no, alterna el modo ventana.
            guard !event.isARepeat else { return }
            if anchor != nil {
                spaceDown = true
            } else if purpose.allowsWindows {
                onToggleWindowMode?()
            }
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false }
    }

    /// Para las capturas internas de revisión de diseño.
    func debugSet(selection: CGRect, cursor: CGPoint) {
        self.selection = selection
        self.cursor = cursor
        anchor = selection.isEmpty ? nil : selection.origin
        hintPill?.opacity = selection.isEmpty ? 1 : 0
        updateLayers()
    }

    /// Para las capturas internas de revisión de diseño.
    func debugSetWindowMode(hovering info: WindowInfo, cursor: CGPoint) {
        windowMode = true
        hintPill?.setText(hintText)
        self.cursor = cursor
        hovered = info
        updateLayers()
    }

    // MARK: - Dibujo

    private func updateLayers() {
        withoutActions {
            if windowMode {
                updateWindowHighlight()
                return
            }
            highlightLayer.isHidden = true

            let dim = CGMutablePath()
            dim.addRect(bounds)
            if !selection.isEmpty { dim.addRect(selection) }
            dimLayer.path = dim

            updateGuidesAndLoupe()

            if selection.isEmpty {
                borderLayer.path = nil
                sizePill.isHidden = true
                return
            }
            borderLayer.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)

            let factor = CGFloat(shot.image.width) / max(bounds.width, 1)
            let size = sizePill.setText(
                "\(Int((selection.width * factor).rounded())) × \(Int((selection.height * factor).rounded()))")
            var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.minY - size.height - 8)
            if origin.y < bounds.minY + 6 { origin.y = selection.minY + 8 }
            origin.x = min(max(bounds.minX + 6, origin.x), bounds.maxX - size.width - 6)
            sizePill.position = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            sizePill.isHidden = false
        }
    }

    private func updateWindowHighlight() {
        for layer in [guideH, guideV, loupe, loupeShadow] { layer.isHidden = true }
        borderLayer.path = nil

        let dim = CGMutablePath()
        dim.addRect(bounds)
        guard let hovered else {
            dimLayer.path = dim
            highlightLayer.isHidden = true
            sizePill.isHidden = true
            return
        }
        let rect = localRect(of: hovered)
        let shape = CGPath(roundedRect: rect, cornerWidth: min(10, rect.width / 2),
                           cornerHeight: min(10, rect.height / 2), transform: nil)
        dim.addPath(shape)
        dimLayer.path = dim
        highlightLayer.path = shape
        highlightLayer.isHidden = false

        let name = hovered.appName.isEmpty ? "" : "\(hovered.appName)   ·   "
        let size = sizePill.setText("\(name)\(Int(hovered.frame.width)) × \(Int(hovered.frame.height))")
        sizePill.position = CGPoint(x: min(max(rect.midX, size.width / 2 + 6), bounds.maxX - size.width / 2 - 6),
                                    y: min(rect.maxY - size.height / 2 - 12, bounds.maxY - size.height))
        sizePill.isHidden = false
    }

    private func updateGuidesAndLoupe() {
        guard let cursor else {
            for layer in [guideH, guideV, loupe, loupeShadow] { layer.isHidden = true }
            return
        }
        let px = 1 / shot.scale
        // Las guías solo acompañan al cursor antes de empezar a arrastrar.
        let showGuides = anchor == nil
        guideH.isHidden = !showGuides
        guideV.isHidden = !showGuides
        guideH.frame = CGRect(x: 0, y: cursor.y, width: bounds.width, height: px)
        guideV.frame = CGRect(x: cursor.x, y: 0, width: px, height: bounds.height)

        let showLoupe = Settings.showsLoupe
        loupe.isHidden = !showLoupe
        loupeShadow.isHidden = !showLoupe
        guard showLoupe else { return }
        let offset = loupeSize / 2 + 26
        var center = CGPoint(x: cursor.x + offset, y: cursor.y - offset)
        if center.x + loupeSize / 2 > bounds.maxX - 8 { center.x = cursor.x - offset }
        if center.y - loupeSize / 2 < bounds.minY + 8 { center.y = cursor.y + offset }
        let frame = CGRect(x: center.x - loupeSize / 2, y: center.y - loupeSize / 2,
                           width: loupeSize, height: loupeSize)
        loupe.frame = frame
        loupeShadow.frame = frame
        loupeImage.frame = CGRect(x: loupeSize / 2 - cursor.x * loupeZoom,
                                  y: loupeSize / 2 - cursor.y * loupeZoom,
                                  width: bounds.width * loupeZoom,
                                  height: bounds.height * loupeZoom)
        loupeReticle.frame = loupe.bounds
    }
}
