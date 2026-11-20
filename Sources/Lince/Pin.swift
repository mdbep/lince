import AppKit

/// Capturas fijadas: flotan sobre todas las ventanas como referencia.
final class PinManager {
    static let shared = PinManager()
    private var pins: [PinController] = []

    func pin(_ capture: Capture, on screen: NSScreen) {
        let controller = PinController(image: capture.image, pointSize: capture.pointSize,
                                       scale: capture.scale, sourceRect: capture.sourceRect, screen: screen)
        controller.onClose = { [weak self, weak controller] in
            self?.pins.removeAll { $0 === controller }
        }
        pins.append(controller)
        controller.show()
    }
}

final class PinController {
    var onClose: (() -> Void)?
    let panel: NSPanel
    private let image: CGImage
    private let scale: CGFloat

    init(image: CGImage, pointSize: CGSize, scale: CGFloat, sourceRect: CGRect?, screen: NSScreen) {
        self.image = image
        self.scale = scale
        // Tamaño real, salvo que no quepa; centrada donde se tomó la captura.
        let visible = screen.visibleFrame
        let fit = min(1, visible.width * 0.7 / pointSize.width, visible.height * 0.7 / pointSize.height)
        let size = CGSize(width: max(60, pointSize.width * fit), height: max(40, pointSize.height * fit))
        let center = sourceRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        frame.origin.x = min(max(visible.minX, frame.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(visible.minY, frame.minY), visible.maxY - frame.height)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentAspectRatio = size
        panel.minSize = CGSize(width: 80, height: 80 * size.height / size.width)

        let view = PinView(frame: CGRect(origin: .zero, size: size), image: image)
        view.onClose = { [weak self] in self?.close() }
        view.onCopy = { [weak self] in self?.copy() }
        panel.contentView = view
    }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func copy() {
        Capture.copy(image: image, png: Capture.encodePNG(image, scale: scale))
    }

    func close() {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.reduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.onClose?()
        })
    }
}

final class PinView: NSView {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    private let controls = PassthroughView()
    private var copyButton: HoverButton!

    init(frame: CGRect, image: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        controls.alphaValue = 0
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        let close = makeButton("xmark", tooltip: "Cerrar (doble clic)") { [weak self] in self?.onClose?() }
        copyButton = makeButton("doc.on.doc", tooltip: "Copiar") { [weak self] in
            self?.onCopy?()
            self?.copyButton.setSymbol("checkmark", size: 10.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                self?.copyButton.setSymbol("doc.on.doc", size: 10.5)
            }
        }
        controls.addSubview(close)
        controls.addSubview(copyButton)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            close.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 7),
            close.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7),
            copyButton.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -7),
            copyButton.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    private func makeButton(_ symbol: String, tooltip: String, action: @escaping () -> Void) -> HoverButton {
        let button = HoverButton(symbol: symbol, symbolSize: 10.5, size: CGSize(width: 24, height: 24), tooltip: tooltip)
        button.cornerRadius = nil
        button.normalColor = NSColor.black.withAlphaComponent(0.55)
        button.hoverColor = NSColor.black.withAlphaComponent(0.85)
        button.normalTint = .white
        button.onClick = action
        return button
    }

    func debugShowControls() { controls.alphaValue = 1 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { setControls(visible: true) }
    override func mouseExited(with event: NSEvent) { setControls(visible: false) }

    private func setControls(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onClose?() }
    }

    /// La rueda o el gesto de desplazamiento amplían y reducen la captura fijada.
    override func scrollWheel(with event: NSEvent) {
        guard let window, event.scrollingDeltaY != 0 else { return }
        let factor = 1 + max(-0.2, min(0.2, event.scrollingDeltaY * 0.01))
        let old = window.frame
        var width = max(window.minSize.width, old.width * factor)
        if let screen = window.screen { width = min(width, screen.visibleFrame.width) }
        let height = width * old.height / old.width
        window.setFrame(CGRect(x: old.midX - width / 2, y: old.midY - height / 2, width: width, height: height),
                        display: true)
    }
}
