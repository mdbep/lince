import AppKit
import Vision

/// Reconocimiento de texto con Vision: funciona sin conexión.
enum TextRecognizer {
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["es-ES", "en-US"]
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { completion(lines.joined(separator: "\n")) }
        }
    }

    /// Reconoce el texto, lo copia y avisa del resultado.
    static func copyText(from image: CGImage, on screen: NSScreen) {
        recognize(image) { text in
            guard !text.isEmpty else {
                Toast.show("No se ha encontrado texto", symbol: "text.magnifyingglass", on: screen)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let lines = text.components(separatedBy: "\n").count
            Toast.show(lines == 1 ? "Texto copiado" : "Texto copiado · \(lines) líneas",
                       symbol: "checkmark", on: screen)
        }
    }
}

/// Aviso breve en la parte baja de la pantalla.
enum Toast {
    private static var panel: NSPanel?
    private static var token = 0

    static func makeContent(_ text: String, symbol: String) -> NSView {
        let icon = NSImageView()
        icon.image = Theme.symbol(symbol, size: 13, weight: .bold)
        icon.contentTintColor = Theme.accent
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13.5, weight: .semibold)
        label.textColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        content.layer?.cornerRadius = 21
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.heightAnchor.constraint(equalToConstant: 42),
        ])
        return content
    }

    static func show(_ text: String, symbol: String, on screen: NSScreen) {
        token += 1
        let current = token
        panel?.orderOut(nil)

        let content = makeContent(text, symbol: symbol)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 96,
                           width: size.width, height: size.height)
        panel.setFrame(frame.offsetBy(dx: 0, dy: -14), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            guard token == current else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if token == current { panel.orderOut(nil) }
            })
        }
    }
}

/// Cuenta atrás del temporizador. No activa Lince, para no cerrar los menús que el usuario abra.
final class CountdownHUD {
    private static var current: CountdownHUD?

    private let panel: NSPanel
    private let outline: NSPanel?
    private let view: CountdownView
    private var remaining: Int
    private var timer: Timer?
    private let completion: (Bool) -> Void

    /// `completion(true)` al llegar a cero; `false` si se cancela con un clic.
    static func run(seconds: Int, around rect: CGRect?, on screen: NSScreen, completion: @escaping (Bool) -> Void) {
        current?.finish(completed: false)
        let hud = CountdownHUD(seconds: seconds, around: rect, on: screen, completion: completion)
        current = hud
        hud.start()
    }

    private init(seconds: Int, around rect: CGRect?, on screen: NSScreen, completion: @escaping (Bool) -> Void) {
        remaining = seconds
        self.completion = completion
        let size = CountdownView.size
        view = CountdownView(frame: CGRect(origin: .zero, size: size), total: seconds)

        // Fuera del área si cabe, para no tapar lo que se va a capturar.
        let visible = screen.visibleFrame
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 60)
        if let rect {
            origin.x = rect.midX - size.width / 2
            if rect.minY - size.height - 16 >= visible.minY {
                origin.y = rect.minY - size.height - 16
            } else if rect.maxY + size.height + 16 <= visible.maxY {
                origin.y = rect.maxY + 16
            } else {
                origin.y = rect.minY + 16
            }
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        }

        panel = CountdownHUD.makePanel(frame: CGRect(origin: origin, size: size))
        panel.contentView = view

        if let rect {
            let outlinePanel = CountdownHUD.makePanel(frame: rect.insetBy(dx: -2, dy: -2))
            outlinePanel.ignoresMouseEvents = true
            outlinePanel.hasShadow = false
            let outlineView = NSView(frame: CGRect(origin: .zero, size: outlinePanel.frame.size))
            outlineView.wantsLayer = true
            let dashes = CAShapeLayer()
            dashes.path = CGPath(rect: outlineView.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            dashes.fillColor = nil
            dashes.strokeColor = NSColor.white.cgColor
            dashes.lineWidth = 1.5
            dashes.lineDashPattern = [6, 5]
            dashes.shadowColor = NSColor.black.cgColor
            dashes.shadowOpacity = 0.6
            dashes.shadowRadius = 2
            dashes.shadowOffset = .zero
            outlineView.layer?.addSublayer(dashes)
            if !Theme.reduceMotion {
                let march = CABasicAnimation(keyPath: "lineDashPhase")
                march.fromValue = 0
                march.toValue = -11
                march.duration = 0.5
                march.repeatCount = .infinity
                dashes.add(march, forKey: "march")
            }
            outlinePanel.contentView = outlineView
            outline = outlinePanel
        } else {
            outline = nil
        }
        view.onCancel = { [weak self] in self?.finish(completed: false) }
    }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func start() {
        outline?.orderFrontRegardless()
        panel.orderFrontRegardless()
        view.show(remaining)
        view.startRing()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(completed: true)
        } else {
            view.show(remaining)
        }
    }

    private func finish(completed: Bool) {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        outline?.orderOut(nil)
        if CountdownHUD.current === self { CountdownHUD.current = nil }
        completion(completed)
    }
}

final class CountdownView: NSView {
    static let size = CGSize(width: 104, height: 104)
    var onCancel: (() -> Void)?

    private let total: Int
    private let number = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()

    init(frame: CGRect, total: Int) {
        self.total = total
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        layer?.cornerRadius = frame.width / 2
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let track = CAShapeLayer()
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: 9, dy: 9), transform: nil)
        track.path = circle
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        track.lineWidth = 4
        layer?.addSublayer(track)

        // El anillo se vacía desde arriba, en el sentido de las agujas del reloj.
        ring.frame = bounds
        ring.path = circle
        ring.fillColor = nil
        ring.strokeColor = Theme.accent.cgColor
        ring.lineWidth = 4
        ring.lineCap = .round
        ring.transform = CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1),
                                             CATransform3DMakeRotation(.pi / 2, 0, 0, 1))
        layer?.addSublayer(ring)

        number.font = .monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        number.textColor = .white
        number.alignment = .center
        number.wantsLayer = true
        number.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: "clic: cancelar")
        hint.font = .systemFont(ofSize: 8.5, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(number)
        addSubview(hint)
        NSLayoutConstraint.activate([
            number.centerXAnchor.constraint(equalTo: centerXAnchor),
            number.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    func show(_ value: Int) {
        number.stringValue = "\(value)"
        layoutSubtreeIfNeeded()
        number.springScale(to: 1, from: 1.35, stiffness: 380, damping: 18)
    }

    func startRing() {
        guard !Theme.reduceMotion else { return }
        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = 1
        drain.toValue = 0
        drain.duration = CFTimeInterval(total)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false
        ring.add(drain, forKey: "drain")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onCancel?() }
}
