import AppKit

/// Vista previa a pantalla completa: la captura crece desde la miniatura sobre un fondo atenuado.
final class PreviewController {
    static let shared = PreviewController()

    private var panel: PreviewPanel?
    private var view: PreviewView?
    private var captureID: String?
    private var sourceFrame: (() -> CGRect?)?
    private var clickMonitor: Any?

    /// Muestra la captura, o la cierra si ya era la que estaba a la vista.
    /// `sourceFrame` devuelve, en coordenadas de pantalla, de dónde sale y adónde vuelve.
    func toggle(_ capture: Capture, on screen: NSScreen, sourceFrame: @escaping () -> CGRect?) {
        if panel != nil {
            let same = captureID == capture.id
            close(animated: same)
            if same { return }
        }
        captureID = capture.id
        self.sourceFrame = sourceFrame

        let panel = PreviewPanel(contentRect: screen.frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // Justo por debajo de las miniaturas, que siguen a mano.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.onDismiss = { [weak self] in self?.close(animated: true) }

        let view = PreviewView(frame: CGRect(origin: .zero, size: screen.frame.size),
                               visible: screen.visibleFrame.size,
                               image: capture.image, pointSize: capture.pointSize)
        view.onDismiss = { [weak self] in self?.close(animated: true) }
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        self.panel = panel
        self.view = view

        let start = sourceFrame().map { panel.convertFromScreen($0) }
        panel.makeKeyAndOrderFront(nil)
        view.open(from: start)

        // Un clic en cualquier otra pantalla o ventana también la cierra.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close(animated: true)
        }
    }

    /// Cierra la vista previa si muestra esa captura (por ejemplo, al descartar su miniatura).
    func close(ifShowing id: String) {
        if captureID == id { close(animated: false) }
    }

    func close(animated: Bool) {
        guard let panel, let view else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        let target = sourceFrame?().map { panel.convertFromScreen($0) }
        self.panel = nil
        self.view = nil
        captureID = nil
        sourceFrame = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        view.close(to: target) { panel.orderOut(nil) }
    }
}

final class PreviewPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc, espacio o retorno cierran, igual que en Vista Rápida.
        switch event.keyCode {
        case 53, 49, 36, 76: onDismiss?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class PreviewView: NSView {
    var onDismiss: (() -> Void)?

    private let backdrop = CALayer()
    private let card = CALayer()
    private let picture = CALayer()
    private let pill = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let pointSize: CGSize
    /// Tamaño útil de la pantalla, sin la barra de menús ni el Dock.
    private let visible: CGSize
    private var targetFrame: CGRect = .zero
    private var closing = false

    private static let pillGap: CGFloat = 14
    private static let pillHeight: CGFloat = 26

    init(frame: CGRect, visible: CGSize, image: CGImage, pointSize: CGSize) {
        self.pointSize = pointSize
        self.visible = visible
        super.init(frame: frame)
        wantsLayer = true

        backdrop.backgroundColor = NSColor.black.cgColor
        backdrop.opacity = 0
        layer?.addSublayer(backdrop)

        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.55
        card.shadowRadius = 40
        card.shadowOffset = CGSize(width: 0, height: -18)
        layer?.addSublayer(card)

        picture.contents = image
        picture.contentsGravity = .resize
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .linear
        picture.cornerRadius = 10
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.borderWidth = 0.5
        picture.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        card.addSublayer(picture)

        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.appearance = NSAppearance(named: .vibrantDark)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Self.pillHeight / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = Theme.hairline.cgColor
        pill.alphaValue = 0
        addSubview(pill)

        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        pill.addSubview(label)

        layoutContent()
        let zoom = Int((targetFrame.width / max(pointSize.width, 1) * 100).rounded())
        var text = "\(image.width) × \(image.height) px"
        if zoom != 100 { text += "  ·  \(zoom) %" }
        label.stringValue = text
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }

    override func layout() {
        super.layout()
        if !closing { layoutContent() }
    }

    private func layoutContent() {
        let reserved = Self.pillGap + Self.pillHeight
        let size = EditorController.imageSize(for: pointSize, visible: visible)
        targetFrame = CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height + reserved) / 2).rounded(),
                             width: size.width, height: size.height)
        let labelSize = label.intrinsicContentSize
        let pillWidth = (labelSize.width + 26).rounded()
        pill.frame = CGRect(x: ((bounds.width - pillWidth) / 2).rounded(),
                            y: targetFrame.minY - reserved,
                            width: pillWidth, height: Self.pillHeight)
        label.frame = CGRect(x: 0, y: ((Self.pillHeight - labelSize.height) / 2).rounded(),
                             width: pillWidth, height: labelSize.height)
        withoutActions {
            backdrop.frame = bounds
            place(targetFrame)
        }
    }

    private func place(_ frame: CGRect) {
        card.frame = frame
        picture.frame = CGRect(origin: .zero, size: frame.size)
        card.shadowPath = CGPath(roundedRect: picture.frame, cornerWidth: picture.cornerRadius,
                                 cornerHeight: picture.cornerRadius, transform: nil)
    }

    // MARK: - Animación

    /// La tarjeta se anima con una transformación, sin recalcular su contenido en cada fotograma.
    private func transform(from frame: CGRect) -> CATransform3D {
        let sx = frame.width / max(targetFrame.width, 1), sy = frame.height / max(targetFrame.height, 1)
        var t = CATransform3DMakeTranslation(frame.midX - targetFrame.midX, frame.midY - targetFrame.midY, 0)
        t = CATransform3DScale(t, sx, sy, 1)
        return t
    }

    private func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: CFTimeInterval,
                         timing: CAMediaTimingFunction) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: keyPath)
    }

    func open(from start: CGRect?) {
        let reduce = Theme.reduceMotion
        let duration: CFTimeInterval = reduce ? 0.12 : 0.34
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        withoutActions { backdrop.opacity = 0.55 }
        animate(backdrop, "opacity", from: 0, to: 0.55, duration: duration, timing: timing)
        if let start, !reduce {
            animate(card, "transform", from: transform(from: start), to: CATransform3DIdentity,
                    duration: duration, timing: timing)
            animate(card, "shadowOpacity", from: 0, to: card.shadowOpacity, duration: duration, timing: timing)
        } else {
            animate(card, "opacity", from: 0, to: 1, duration: duration, timing: timing)
            if !reduce {
                animate(card, "transform", from: CATransform3DMakeScale(0.94, 0.94, 1), to: CATransform3DIdentity,
                        duration: duration, timing: timing)
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            pill.animator().alphaValue = 1
        }
    }

    func close(to target: CGRect?, completion: @escaping () -> Void) {
        closing = true
        let reduce = Theme.reduceMotion
        let duration: CFTimeInterval = reduce ? 0.1 : 0.24
        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        animate(backdrop, "opacity", from: backdrop.opacity, to: 0, duration: duration, timing: timing)
        withoutActions { backdrop.opacity = 0 }
        if let target, !reduce {
            let end = transform(from: target)
            animate(card, "transform", from: CATransform3DIdentity, to: end, duration: duration, timing: timing)
            animate(card, "shadowOpacity", from: card.shadowOpacity, to: 0, duration: duration, timing: timing)
            withoutActions {
                card.transform = end
                card.shadowOpacity = 0
            }
        } else {
            animate(card, "opacity", from: 1, to: 0, duration: duration, timing: timing)
            withoutActions { card.opacity = 0 }
        }
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration * 0.6
            pill.animator().alphaValue = 0
        }
    }

    func debugShow() {
        withoutActions { backdrop.opacity = 0.55 }
        pill.alphaValue = 1
    }
}
