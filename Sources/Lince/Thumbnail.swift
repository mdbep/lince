import AppKit
import CoreImage

protocol ThumbnailActions: AnyObject {
    func thumbnailEdit(_ capture: Capture)
    func thumbnailPreview(_ capture: Capture)
    func thumbnailReport(error: Error)
}

/// Bandeja de miniaturas en la esquina inferior izquierda de cada pantalla.
/// En reposo forman una pila, con la más reciente delante; al pasar el ratón se despliegan.
final class ThumbnailManager {
    weak var actions: ThumbnailActions?
    private var items: [ThumbnailController] = []
    private let maxItems = 6
    private var isExpanded = false
    private var collapseTimer: Timer?

    private static let margin: CGFloat = 22
    private static let spacing: CGFloat = 12
    /// Cuánto asoma y cuánto se estrecha cada tarjeta de detrás en la pila.
    private static let peek: CGFloat = 8
    private static let shrink: CGFloat = 9
    private static let visibleDepth = 2

    /// `source` es el rectángulo (coordenadas globales) desde el que "vuela" la captura hasta su miniatura.
    func add(_ capture: Capture, on screen: NSScreen, from source: CGRect?) {
        let controller = ThumbnailController(capture: capture, screen: screen, manager: self)
        items.append(controller)
        while items.count > maxItems {
            items[0].dismiss()
        }
        layout(appearing: controller)

        let target = controller.targetFrame
        controller.panel.setFrame(target, display: false)
        let reveal = { [weak controller] in
            guard let controller, !controller.isDismissed else { return }
            controller.isRevealed = true
            controller.panel.alphaValue = 1
            controller.panel.orderFrontRegardless()
        }
        if let source, !Theme.reduceMotion {
            FlightAnimator.fly(image: capture.image, from: source, to: target, on: screen, completion: reveal)
        } else {
            controller.isRevealed = true
            controller.panel.alphaValue = 0
            controller.panel.setFrame(target.offsetBy(dx: -30, dy: 0), display: false)
            controller.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                controller.panel.animator().setFrame(target, display: true)
                controller.panel.animator().alphaValue = 1
            }
        }
    }

    func controller(for capture: Capture) -> ThumbnailController? {
        items.first { $0.capture === capture }
    }

    func controller(forID id: String) -> ThumbnailController? {
        items.first { $0.capture.id == id }
    }

    /// Las miniaturas de una pantalla, de la más reciente a la más antigua.
    func controllers(on screen: NSScreen) -> [ThumbnailController] {
        items.reversed().filter { $0.screen.displayID == screen.displayID }
    }

    func dismissAll() {
        for item in items { item.dismiss() }
    }

    fileprivate func remove(_ controller: ThumbnailController) {
        items.removeAll { $0 === controller }
        layout(appearing: nil)
    }

    // MARK: Pila y despliegue

    /// El ratón ha entrado o salido de una miniatura.
    fileprivate func hoverChanged(inside: Bool) {
        if inside {
            collapseTimer?.invalidate()
            collapseTimer = nil
            guard !isExpanded else { return }
            isExpanded = true
            layout(appearing: nil)
        } else if isExpanded, collapseTimer == nil {
            // Entre dos miniaturas hay un hueco: se espera a que el ratón salga de verdad de la bandeja.
            let timer = Timer(timeInterval: 0.28, repeats: true) { [weak self] _ in self?.collapseIfOutside() }
            timer.tolerance = 0.08
            RunLoop.main.add(timer, forMode: .common)
            collapseTimer = timer
        }
    }

    private func collapseIfOutside() {
        // Con un botón pulsado hay un arrastre en curso: la bandeja no se mueve.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let mouse = NSEvent.mouseLocation
        let reach = -(Self.spacing + 4)
        guard !items.contains(where: { $0.targetFrame.insetBy(dx: reach, dy: reach).contains(mouse) }) else { return }
        collapseTimer?.invalidate()
        collapseTimer = nil
        isExpanded = false
        layout(appearing: nil)
    }

    private func layout(appearing: ThumbnailController?) {
        var groups: [CGDirectDisplayID: [ThumbnailController]] = [:]
        var order: [CGDirectDisplayID] = []
        for controller in items.reversed() {
            let key = controller.screen.displayID ?? 0
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(controller)
        }
        if items.count < 2 { isExpanded = false }

        for key in order {
            guard let group = groups[key], let front = group.first else { continue }
            let visible = front.screen.visibleFrame
            let base = CGPoint(x: visible.minX + Self.margin, y: visible.minY + Self.margin)
            if isExpanded || group.count == 1 {
                // Desplegadas: la más reciente abajo, las anteriores suben.
                var y = base.y
                for controller in group {
                    let size = controller.naturalSize
                    controller.place(CGRect(x: base.x, y: y, width: size.width, height: size.height),
                                     depth: 0, badge: 0, hidden: false, animated: controller !== appearing)
                    y += size.height + Self.spacing
                }
            } else {
                // Apiladas: las de detrás asoman por arriba, cada vez más estrechas y apagadas.
                let size = front.naturalSize
                for (index, controller) in group.enumerated() {
                    let depth = min(index, Self.visibleDepth)
                    let inset = CGFloat(depth) * Self.shrink
                    let frame = CGRect(x: base.x + inset, y: base.y + CGFloat(depth) * Self.peek,
                                       width: size.width - inset * 2, height: size.height)
                    controller.place(frame, depth: depth, badge: index == 0 ? group.count : 0,
                                     hidden: index > Self.visibleDepth, animated: controller !== appearing)
                }
            }
        }
    }
}

/// Anima la captura encogiéndose desde donde se tomó hasta el sitio de su miniatura.
enum FlightAnimator {
    private static var windows: [NSWindow] = []

    static func fly(image: CGImage, from source: CGRect, to target: CGRect, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(screen.frame, display: false)

        let origin = screen.frame.origin
        let start = source.offsetBy(dx: -origin.x, dy: -origin.y)
        let end = target.offsetBy(dx: -origin.x, dy: -origin.y)

        let card = CALayer()
        card.contents = image
        card.contentsGravity = .resizeAspect
        card.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        card.masksToBounds = true
        card.cornerCurve = .continuous
        card.cornerRadius = ThumbnailView.cornerRadius
        card.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        card.borderWidth = 0.5
        card.frame = end

        let flash = CALayer()
        flash.backgroundColor = NSColor.white.cgColor
        flash.frame = start
        flash.opacity = 0

        // Un trazo naranja recorre el borde del área capturada, como una mirada que la repasa.
        let trace = CAShapeLayer()
        trace.path = CGPath(rect: start.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        trace.fillColor = nil
        trace.strokeColor = Theme.accent.cgColor
        trace.lineWidth = 3
        trace.lineCap = .round
        trace.shadowColor = Theme.accent.cgColor
        trace.shadowOpacity = 1
        trace.shadowRadius = 6
        trace.shadowOffset = .zero
        trace.strokeEnd = 0

        view.layer?.addSublayer(card)
        view.layer?.addSublayer(flash)
        view.layer?.addSublayer(trace)
        windows.append(window)
        window.orderFrontRegardless()

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            completion()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                window.orderOut(nil)
                windows.removeAll { $0 === window }
            }
        }
        let duration: CFTimeInterval = 0.5
        let hold: CFTimeInterval = 0.08
        let timing = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.1, 1)

        func animate(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = hold
            animation.duration = duration
            animation.timingFunction = timing
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = [
            animate("position", from: CGPoint(x: start.midX, y: start.midY), to: CGPoint(x: end.midX, y: end.midY)),
            animate("bounds", from: CGRect(origin: .zero, size: start.size), to: CGRect(origin: .zero, size: end.size)),
            animate("cornerRadius", from: 0, to: ThumbnailView.cornerRadius),
        ]
        group.duration = hold + duration
        group.fillMode = .backwards
        card.add(group, forKey: "flight")

        let flashFade = CABasicAnimation(keyPath: "opacity")
        flashFade.fromValue = 0.4
        flashFade.toValue = 0
        flashFade.duration = 0.32
        flashFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(flashFade, forKey: "flash")

        // La cabeza del trazo da la vuelta y la cola la sigue un instante después.
        let lap: CFTimeInterval = 0.4, lag: CFTimeInterval = 0.13
        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = 0
        head.toValue = 1
        head.duration = lap
        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = 0
        tail.toValue = 1
        tail.beginTime = lag
        tail.duration = lap
        let lapGroup = CAAnimationGroup()
        lapGroup.animations = [head, tail]
        lapGroup.duration = lap + lag
        lapGroup.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        lapGroup.fillMode = .both
        lapGroup.isRemovedOnCompletion = false
        trace.add(lapGroup, forKey: "lap")
        CATransaction.commit()
    }
}

final class ThumbnailController {
    let capture: Capture
    let screen: NSScreen
    let panel: NSPanel
    var targetFrame: CGRect = .zero
    /// Tamaño de la miniatura desplegada; en la pila, las de detrás se estrechan.
    let naturalSize: CGSize
    private(set) var isDismissed = false
    /// Ya ha terminado su animación de llegada y la bandeja puede moverla.
    fileprivate(set) var isRevealed = false
    private let view: ThumbnailView
    private weak var manager: ThumbnailManager?

    init(capture: Capture, screen: NSScreen, manager: ThumbnailManager) {
        self.capture = capture
        self.screen = screen
        self.manager = manager

        let size = ThumbnailController.thumbnailSize(for: capture.pointSize)
        naturalSize = size
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        view = ThumbnailView(frame: CGRect(origin: .zero, size: size))
        panel.contentView = view
        view.controller = self
        view.setImage(capture.image, pointSize: capture.pointSize)
    }

    static func thumbnailSize(for pointSize: CGSize) -> CGSize {
        let maxSize = CGSize(width: 250, height: 156)
        let ratio = min(maxSize.width / max(pointSize.width, 1), maxSize.height / max(pointSize.height, 1), 1)
        return CGSize(width: max(190, (pointSize.width * ratio).rounded()),
                      height: max(124, (pointSize.height * ratio).rounded()))
    }

    func refreshImage() {
        view.setImage(capture.image, pointSize: capture.pointSize)
    }

    /// Coloca la miniatura en la bandeja: `depth` es su posición en la pila y `badge` el total que hay debajo.
    fileprivate func place(_ frame: CGRect, depth: Int, badge: Int, hidden: Bool, animated: Bool) {
        targetFrame = frame
        view.setStack(depth: depth, badge: badge)
        guard animated, !isDismissed else { return }
        let alpha: CGFloat = hidden ? 0 : 1
        let revealed = isRevealed
        guard panel.frame != frame || (revealed && panel.alphaValue != alpha) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
            if revealed { panel.animator().alphaValue = alpha }
        }
    }

    fileprivate func hoverChanged(inside: Bool) { manager?.hoverChanged(inside: inside) }

    /// Todas las miniaturas de esta pantalla, para arrastrarlas juntas.
    fileprivate var siblings: [ThumbnailController] { manager?.controllers(on: screen) ?? [self] }

    /// Rectángulo que ocupa la imagen dentro de la miniatura, en coordenadas de pantalla.
    var imageFrameOnScreen: CGRect? {
        guard !isDismissed, panel.isVisible else { return nil }
        let frame = panel.frame, size = capture.pointSize
        guard size.width > 0, size.height > 0 else { return frame }
        let factor = min(frame.width / size.width, frame.height / size.height)
        let width = size.width * factor, height = size.height * factor
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        PreviewController.shared.close(ifShowing: capture.id)
        manager?.remove(self)
        let panel = self.panel
        let capture = self.capture
        let end = panel.frame.offsetBy(dx: -(panel.frame.width + 60), dy: 0)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.reduceMotion ? 0 : 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            capture.cleanUp()
        })
    }

    // MARK: - Acciones

    fileprivate func copy() {
        capture.copyToPasteboard()
        view.showToast("Copiado", symbol: "checkmark")
    }

    fileprivate func save() {
        do {
            try capture.saveToDefaultFolder()
            view.showToast("Guardado", symbol: "checkmark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in self?.dismiss() }
        } catch {
            manager?.actions?.thumbnailReport(error: error)
        }
    }

    fileprivate func saveAs() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = capture.fileName
        savePanel.directoryURL = Settings.saveDirectory
        savePanel.allowedContentTypes = [capture.export.format.type]
        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        do {
            guard let data = capture.exportedData() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            manager?.actions?.thumbnailReport(error: error)
        }
    }

    fileprivate func pin() {
        PinManager.shared.pin(capture, on: screen)
        dismiss()
    }

    fileprivate func copyText() {
        TextRecognizer.copyText(from: capture.image, on: screen)
    }

    fileprivate func edit() { manager?.actions?.thumbnailEdit(capture) }
    fileprivate func preview() { manager?.actions?.thumbnailPreview(capture) }
    fileprivate func dismissAll() { manager?.dismissAll() }
}

// MARK: - Vista

final class ThumbnailView: NSView, NSDraggingSource {
    static let cornerRadius: CGFloat = 12
    private static let ciContext = CIContext()

    fileprivate weak var controller: ThumbnailController?

    private let imageLayer = CALayer()
    private let blurLayer = CALayer()
    private let tintLayer = CALayer()
    private let depthLayer = CALayer()
    private let badge = CATextLayer()
    private let badgeBack = CALayer()
    private let overlay = PassthroughView()
    private let actionStack = NSStackView()
    private var exportChip: HoverButton!
    private var chipToken = 0
    private let toast = NSView()
    private let toastIcon = NSImageView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var mouseDownPoint: CGPoint?
    private var didDrag = false
    private var isHovering = false
    private var toastToken = 0
    private var swipeOffset: CGFloat = 0
    private var isSwiping = false
    private var draggedControllers: [ThumbnailController] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ThumbnailView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        blurLayer.contentsGravity = .resizeAspect
        blurLayer.opacity = 0
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        tintLayer.opacity = 0
        for sublayer in [imageLayer, blurLayer, tintLayer] {
            sublayer.frame = bounds
            sublayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(sublayer)
        }

        buildOverlay()
        buildToast()
        buildStackLayers()

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    func setImage(_ image: CGImage, pointSize: CGSize) {
        withoutActions { imageLayer.contents = image }
        refreshExportChip()
        // La versión desenfocada para el hover se prepara fuera del hilo principal.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let blurred = ThumbnailView.blurred(image)
            DispatchQueue.main.async {
                withoutActions { self?.blurLayer.contents = blurred ?? image }
            }
        }
    }

    static func blurred(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let ratio = min(1, 520 / CGFloat(max(image.width, image.height)))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        let output = scaled.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: scaled.extent)
        return ciContext.createCGImage(output, from: scaled.extent)
    }

    private func buildOverlay() {
        overlay.wantsLayer = true
        overlay.alphaValue = 0
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        let copy = makePill(title: "Copiar", symbol: "doc.on.doc") { [weak self] in self?.controller?.copy() }
        let save = makePill(title: "Guardar", symbol: "square.and.arrow.down") { [weak self] in self?.controller?.save() }
        actionStack.orientation = .vertical
        actionStack.spacing = 7
        actionStack.addArrangedSubview(copy)
        actionStack.addArrangedSubview(save)
        actionStack.wantsLayer = true
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(actionStack)

        let close = makeCorner(symbol: "xmark", tooltip: "Cerrar") { [weak self] in self?.controller?.dismiss() }
        let edit = makeCorner(symbol: "pencil", tooltip: "Editar y anotar") { [weak self] in self?.controller?.edit() }
        let preview = makeCorner(symbol: "eye", tooltip: "Vista rápida") { [weak self] in self?.controller?.preview() }
        let pin = makeCorner(symbol: "pin.fill", tooltip: "Fijar en pantalla") { [weak self] in self?.controller?.pin() }
        for button in [close, edit, preview, pin] { overlay.addSubview(button) }

        // Etiqueta de exportación: formato, tamaño y peso. Al pulsarla se cambian al vuelo.
        exportChip = HoverButton(title: "PNG", fontSize: 10, tooltip: "Cambiar formato y tamaño",
                                 padding: 8, height: 22)
        exportChip.cornerRadius = nil
        exportChip.normalColor = NSColor.black.withAlphaComponent(0.5)
        exportChip.hoverColor = NSColor.black.withAlphaComponent(0.82)
        exportChip.normalTint = .white
        exportChip.titleLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        exportChip.titleLabel.lineBreakMode = .byTruncatingTail
        exportChip.titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        exportChip.onClick = { [weak self] in self?.showExportMenu() }
        overlay.addSubview(exportChip)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            actionStack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 7),
            close.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 7),
            edit.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -7),
            edit.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 7),
            pin.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -5),
            pin.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 7),
            preview.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -7),
            preview.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -7),
            exportChip.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 7),
            exportChip.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            exportChip.trailingAnchor.constraint(lessThanOrEqualTo: preview.leadingAnchor, constant: -6),
        ])
    }

    private func makePill(title: String, symbol: String, action: @escaping () -> Void) -> HoverButton {
        let button = HoverButton(symbol: symbol, title: title, symbolSize: 11, fontSize: 12,
                                 size: CGSize(width: 108, height: 27))
        button.cornerRadius = nil
        button.normalColor = NSColor.white.withAlphaComponent(0.92)
        button.hoverColor = .white
        button.normalTint = NSColor.black.withAlphaComponent(0.85)
        button.hoverTint = .black
        button.onClick = action
        return button
    }

    private func makeCorner(symbol: String, tooltip: String, action: @escaping () -> Void) -> HoverButton {
        let button = HoverButton(symbol: symbol, symbolSize: 10.5, size: CGSize(width: 24, height: 24), tooltip: tooltip)
        button.cornerRadius = nil
        button.normalColor = NSColor.black.withAlphaComponent(0.5)
        button.hoverColor = NSColor.black.withAlphaComponent(0.8)
        button.normalTint = .white
        button.onClick = action
        return button
    }

    private func buildToast() {
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        toast.layer?.cornerRadius = 15
        toast.layer?.cornerCurve = .continuous
        toast.alphaValue = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        toastIcon.contentTintColor = Theme.accent
        toastLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        toastLabel.textColor = .white
        let stack = NSStackView(views: [toastIcon, toastLabel])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(stack)
        addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: centerXAnchor),
            toast.centerYAnchor.constraint(equalTo: centerYAnchor),
            toast.heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: toast.centerYAnchor),
        ])
    }

    // MARK: Pila

    private func buildStackLayers() {
        depthLayer.backgroundColor = NSColor.black.cgColor
        depthLayer.opacity = 0
        depthLayer.frame = bounds
        depthLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        depthLayer.zPosition = 10
        layer?.addSublayer(depthLayer)

        badgeBack.backgroundColor = Theme.accent.cgColor
        badgeBack.cornerCurve = .continuous
        badgeBack.opacity = 0
        badgeBack.zPosition = 11
        badgeBack.shadowColor = NSColor.black.cgColor
        badgeBack.shadowOpacity = 0.35
        badgeBack.shadowRadius = 3
        badgeBack.shadowOffset = CGSize(width: 0, height: -1)
        badge.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badge.fontSize = 11
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        badgeBack.addSublayer(badge)
        layer?.addSublayer(badgeBack)
    }

    /// `depth` oscurece la tarjeta según lo atrás que esté; `badge` muestra cuántas capturas hay en la pila.
    func setStack(depth: Int, badge count: Int) {
        let text = count > 1 ? "\(count)" : ""
        if (badge.string as? String) != text, count > 1 {
            withoutActions {
                badge.string = text
                let width = max(20, CGFloat(text.count) * 7 + 13)
                badgeBack.bounds = CGRect(x: 0, y: 0, width: width, height: 20)
                badgeBack.cornerRadius = 10
                badge.frame = CGRect(x: 0, y: 3, width: width, height: 14)
                layoutBadge()
            }
        }
        withLayerAnimation(0.22) {
            depthLayer.opacity = Float(min(depth, 3)) * 0.26
            badgeBack.opacity = count > 1 ? 1 : 0
        }
    }

    private func layoutBadge() {
        badgeBack.position = CGPoint(x: bounds.maxX - 8 - badgeBack.bounds.width / 2, y: bounds.maxY - 8 - 10)
    }

    override func layout() {
        super.layout()
        withoutActions { layoutBadge() }
    }

    // MARK: Formato y tamaño

    /// Actualiza la etiqueta; el peso se calcula en segundo plano porque exige codificar la imagen.
    func refreshExportChip() {
        guard let capture = controller?.capture else { return }
        chipToken += 1
        let token = chipToken
        let size = capture.exportPixelSize
        let base = "\(capture.export.format.label) · \(size.width)×\(size.height)"
        exportChip.setTitle(base)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let bytes = capture.exportedData()?.count else { return }
            let weight = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            DispatchQueue.main.async {
                guard let self, self.chipToken == token else { return }
                self.exportChip.setTitle("\(base) · \(weight)")
            }
        }
    }

    private func showExportMenu() {
        let menu = NSMenu()
        addExportItems(to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: exportChip.frame.minX, y: exportChip.frame.maxY + 4), in: self)
    }

    private func addExportItems(to menu: NSMenu) {
        guard let capture = controller?.capture else { return }
        let options = capture.export
        menu.addItem(.sectionHeader(title: "Formato"))
        for format in ExportFormat.allCases {
            let item = menu.addItem(withTitle: format.label, action: #selector(chooseFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            item.state = options.format == format ? .on : .off
        }
        menu.addItem(.sectionHeader(title: "Tamaño"))
        for (title, scale) in [("Original", 1.0), ("Mitad", 0.5), ("25 %", 0.25)] {
            let size = ExportOptions(scale: scale).pixelSize(for: capture.image)
            let item = menu.addItem(withTitle: "\(title)  ·  \(size.width) × \(size.height)",
                                    action: #selector(chooseScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scale
            item.state = options.customWidth == nil && options.scale == scale ? .on : .off
        }
        let customTitle = options.customWidth.map { "Ancho a medida  ·  \($0) px…" } ?? "Ancho a medida…"
        let custom = menu.addItem(withTitle: customTitle, action: #selector(chooseCustomWidth), keyEquivalent: "")
        custom.target = self
        custom.state = options.customWidth != nil ? .on : .off
    }

    private func setExport(_ change: (inout ExportOptions) -> Void) {
        guard let capture = controller?.capture else { return }
        var options = capture.export
        change(&options)
        capture.export = options
        refreshExportChip()
        exportChip.springScale(to: 1, from: 0.9, stiffness: 480, damping: 18)
    }

    @objc private func chooseFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = ExportFormat(rawValue: raw) else { return }
        setExport { $0.format = format }
    }

    @objc private func chooseScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        setExport {
            $0.scale = scale
            $0.customWidth = nil
        }
    }

    @objc private func chooseCustomWidth() {
        guard let capture = controller?.capture else { return }
        let alert = NSAlert()
        alert.messageText = "Ancho a medida"
        alert.informativeText = "Ancho en píxeles (máximo \(capture.image.width)). El alto se ajusta solo."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "\(capture.exportPixelSize.width)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Aplicar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let width = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), width > 0 else { return }
        setExport { $0.customWidth = min(width, capture.image.width) }
    }

    /// Confirmación breve en el centro de la miniatura ("Copiado", "Guardado").
    func showToast(_ text: String, symbol: String) {
        toastToken += 1
        let token = toastToken
        toastIcon.image = Theme.symbol(symbol, size: 11, weight: .bold)
        toastLabel.stringValue = text
        layoutSubtreeIfNeeded()
        actionStack.animator().alphaValue = 0
        toast.alphaValue = 1
        toast.springScale(to: 1, from: 0.6, stiffness: 520, damping: 20)
        setDimmed(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.toastToken == token else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.toast.animator().alphaValue = 0
                self.actionStack.animator().alphaValue = 1
            }
            if !self.isHovering { self.setDimmed(false) }
        }
    }

    /// Para las capturas internas de revisión de diseño.
    func debugSetChip(_ text: String) { exportChip.setTitle(text) }

    /// Para las capturas internas de revisión de diseño.
    func debugSetHover(_ hovering: Bool) {
        if hovering, blurLayer.contents == nil, let image = imageLayer.contents {
            let cgImage = image as! CGImage
            blurLayer.contents = ThumbnailView.blurred(cgImage)
        }
        withoutActions {
            blurLayer.opacity = hovering ? 1 : 0
            tintLayer.opacity = hovering ? 1 : 0
        }
        overlay.alphaValue = hovering ? 1 : 0
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        controller?.hoverChanged(inside: true)
        setDimmed(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            overlay.animator().alphaValue = 1
        }
        actionStack.springScale(to: 1, from: 0.9, stiffness: 480, damping: 24)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        controller?.hoverChanged(inside: false)
        if toast.alphaValue == 0 { setDimmed(false) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            overlay.animator().alphaValue = 0
        }
    }

    private func setDimmed(_ dimmed: Bool) {
        withLayerAnimation(0.2) {
            blurLayer.opacity = dimmed ? 1 : 0
            tintLayer.opacity = dimmed ? 1 : 0
        }
    }

    // MARK: Clic, arrastre y menú contextual

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag, let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        // Con ⇧ se arrastran a la vez todas las capturas de la bandeja.
        let group = event.modifierFlags.contains(.shift) ? controller.siblings : [controller]
        var items: [NSDraggingItem] = []
        var dragged: [ThumbnailController] = []
        for (index, member) in group.enumerated() {
            guard let url = member.capture.temporaryFileURL() else { continue }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let shift = CGFloat(index) * 10
            item.setDraggingFrame(bounds.offsetBy(dx: shift, dy: shift), contents: member.capture.nsImage)
            items.append(item)
            dragged.append(member)
        }
        guard !items.isEmpty else { return }
        didDrag = true
        draggedControllers = dragged
        beginDraggingSession(with: items, event: event, source: self)
    }

    // MARK: Descartar deslizando

    /// Deslizar con dos dedos hacia el borde de la pantalla lanza la miniatura fuera, como una notificación.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let controller, let panel = window else { return }
        if event.phase == .began {
            isSwiping = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            swipeOffset = 0
        }
        guard isSwiping else { return }
        if event.phase == .changed || event.phase == .began {
            swipeOffset += event.scrollingDeltaX
            // Hacia el borde sigue al dedo; hacia dentro ofrece resistencia.
            let offset = swipeOffset < 0 ? swipeOffset : swipeOffset * 0.18
            let target = controller.targetFrame
            panel.setFrameOrigin(CGPoint(x: target.minX + offset, y: target.minY))
            panel.alphaValue = 1 - min(1, max(0, -offset) / 240) * 0.65
        } else if event.phase == .ended || event.phase == .cancelled {
            isSwiping = false
            if event.phase == .ended, swipeOffset < -90 {
                controller.dismiss()
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.reduceMotion ? 0 : 0.3
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    panel.animator().setFrame(controller.targetFrame, display: true)
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard mouseDownPoint != nil, !didDrag else { return }
        controller?.preview()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let dragged = draggedControllers
        draggedControllers = []
        if !operation.isEmpty {
            // El destino puede tardar en leer los archivos: no se borran de inmediato.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dragged.forEach { $0.dismiss() } }
            dragged.forEach { $0.panel.orderOut(nil) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        add("Copiar", "doc.on.doc", #selector(menuCopy))
        add("Guardar", "square.and.arrow.down", #selector(menuSave))
        add("Guardar como…", "folder", #selector(menuSaveAs))
        let exportItem = menu.addItem(withTitle: "Formato y tamaño", action: nil, keyEquivalent: "")
        exportItem.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        let exportMenu = NSMenu()
        addExportItems(to: exportMenu)
        exportItem.submenu = exportMenu
        menu.addItem(.separator())
        add("Editar y anotar", "pencil", #selector(menuEdit))
        add("Vista rápida", "eye", #selector(menuPreview))
        add("Fijar en pantalla", "pin", #selector(menuPin))
        add("Copiar el texto de la imagen", "text.viewfinder", #selector(menuCopyText))
        menu.addItem(.separator())
        add("Cerrar", "xmark", #selector(menuClose))
        add("Cerrar todas", "xmark.circle", #selector(menuCloseAll))
        return menu
    }

    @objc private func menuCopy() { controller?.copy() }
    @objc private func menuSave() { controller?.save() }
    @objc private func menuSaveAs() { controller?.saveAs() }
    @objc private func menuEdit() { controller?.edit() }
    @objc private func menuPreview() { controller?.preview() }
    @objc private func menuPin() { controller?.pin() }
    @objc private func menuCopyText() { controller?.copyText() }
    @objc private func menuClose() { controller?.dismiss() }
    @objc private func menuCloseAll() { controller?.dismissAll() }
}

/// Deja pasar los clics que no caen sobre un botón para que la miniatura pueda arrastrarse.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
