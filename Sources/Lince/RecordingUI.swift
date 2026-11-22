import AppKit
import AVFoundation

enum RecordingStyle {
    /// El rojo de "grabando", que se entiende sin leer nada.
    static let red = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)

    static func panel(frame: CGRect, level: NSWindow.Level = .statusBar) -> RecordPanel {
        let panel = RecordPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 22),
        ])
        return line
    }
}

/// Panel de los controles de grabación. Solo toma el teclado mientras se eligen las opciones.
final class RecordPanel: NSPanel {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var acceptsKey = false

    override var canBecomeKey: Bool { acceptsKey }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Fondo oscuro y redondeado común a la barra de opciones y al control de grabación.
class RecordChrome: NSView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.96).cgColor
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.height / 2, 18)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Opciones antes de grabar

/// Barra que aparece tras elegir qué grabar: formato, cursor, clics, sonido y el botón de empezar.
final class RecordSetupView: RecordChrome {
    static let height: CGFloat = 52
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?

    private let target: RecordingTarget
    private var formatButtons: [(RecordingFormat, HoverButton)] = []
    private let sizeLabel = NSTextField(labelWithString: "")
    private var cursorButton: HoverButton!
    private var clicksButton: HoverButton!
    private var audioButton: HoverButton!
    private var microphoneButton: HoverButton?

    static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    init(target: RecordingTarget) {
        self.target = target
        super.init(frame: .zero)

        let close = HoverButton(symbol: "xmark", symbolSize: 11, size: CGSize(width: 30, height: 30),
                                tooltip: "Cancelar (Esc)")
        close.cornerRadius = nil
        close.normalTint = NSColor.white.withAlphaComponent(0.6)
        close.onClick = { [weak self] in self?.onCancel?() }

        // Vídeo o GIF: luego se puede cambiar desde la miniatura sin volver a grabar.
        let segment = NSView()
        segment.wantsLayer = true
        segment.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        segment.layer?.cornerRadius = 9
        segment.layer?.cornerCurve = .continuous
        let formats = NSStackView()
        formats.spacing = 2
        formats.translatesAutoresizingMaskIntoConstraints = false
        for (format, title, tip) in [(RecordingFormat.video, "Vídeo", "Vídeo MP4, con sonido si lo activas"),
                                     (RecordingFormat.gif, "GIF", "GIF animado, sin sonido")] {
            let button = HoverButton(title: title, fontSize: 12, tooltip: tip, padding: 13, height: 26)
            button.cornerRadius = 7
            button.normalTint = NSColor.white.withAlphaComponent(0.6)
            button.selectedColor = NSColor.white.withAlphaComponent(0.2)
            button.onClick = { [weak self] in
                Settings.recordFormat = format
                self?.refresh()
            }
            formats.addArrangedSubview(button)
            formatButtons.append((format, button))
        }
        segment.addSubview(formats)
        segment.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            formats.leadingAnchor.constraint(equalTo: segment.leadingAnchor, constant: 2),
            formats.trailingAnchor.constraint(equalTo: segment.trailingAnchor, constant: -2),
            formats.topAnchor.constraint(equalTo: segment.topAnchor, constant: 2),
            formats.bottomAnchor.constraint(equalTo: segment.bottomAnchor, constant: -2),
        ])

        cursorButton = toggle("cursorarrow", "Mostrar el cursor") {
            Settings.recordCursor.toggle()
        }
        clicksButton = toggle("cursorarrow.rays", target.isWindow
                              ? "Las ondas de clic no están disponibles al grabar una sola ventana"
                              : "Resaltar los clics con una onda") {
            Settings.recordClicks.toggle()
        }
        clicksButton.isEnabled = !target.isWindow
        audioButton = toggle("speaker.wave.2.fill", "Grabar el sonido del Mac") {
            Settings.recordSystemAudio.toggle()
        }
        var toggles: [NSView] = [cursorButton, clicksButton, audioButton]
        if #available(macOS 15.0, *) {
            let button = toggle("mic.fill", "Grabar el micrófono") { [weak self] in self?.toggleMicrophone() }
            microphoneButton = button
            toggles.append(button)
        }
        let toggleStack = NSStackView(views: toggles)
        toggleStack.spacing = 2

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        sizeLabel.toolTip = "Tamaño con el que saldrá"

        let record = HoverButton(symbol: "record.circle", title: "Grabar", symbolSize: 12.5, fontSize: 12.5,
                                 tooltip: "Empezar a grabar (↩)", padding: 15, height: 32)
        record.cornerRadius = nil
        record.normalColor = RecordingStyle.red
        record.hoverColor = NSColor(srgbRed: 1, green: 0.38, blue: 0.34, alpha: 1)
        record.normalTint = .white
        record.onClick = { [weak self] in self?.onRecord?() }

        let stack = NSStackView(views: [close, RecordingStyle.divider(), segment, toggleStack,
                                        RecordingStyle.divider(), sizeLabel, record])
        stack.spacing = 10
        stack.setCustomSpacing(12, after: sizeLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    private func toggle(_ symbol: String, _ tooltip: String, action: @escaping () -> Void) -> HoverButton {
        let button = HoverButton(symbol: symbol, symbolSize: 13, size: CGSize(width: 34, height: 30), tooltip: tooltip)
        button.cornerRadius = 8
        button.normalTint = NSColor.white.withAlphaComponent(0.42)
        button.hoverTint = NSColor.white.withAlphaComponent(0.9)
        button.selectedColor = Theme.accent.withAlphaComponent(0.22)
        button.selectedTint = Theme.accent
        button.onClick = { [weak self] in
            action()
            self?.refresh()
        }
        return button
    }

    /// El micrófono necesita su propio permiso de macOS; se pide la primera vez que se activa.
    private func toggleMicrophone() {
        if Settings.recordMicrophone, Self.microphoneAllowed {
            Settings.recordMicrophone = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Settings.recordMicrophone = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    Settings.recordMicrophone = granted
                    self?.refresh()
                }
            }
        default:
            Toast.show("Permite el micrófono a Lince en Ajustes del Sistema", symbol: "mic.slash", on: target.screen)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func refresh() {
        let format = Settings.recordFormat
        for (candidate, button) in formatButtons { button.isSelected = candidate == format }
        cursorButton.isSelected = Settings.recordCursor
        clicksButton.isSelected = Settings.recordClicks && !target.isWindow
        audioButton.isSelected = Settings.recordSystemAudio
        microphoneButton?.isSelected = Settings.recordMicrophone && Self.microphoneAllowed

        let points = target.frame.size
        let video = ScreenRecorder.pixelSize(for: points, nativeScale: target.screen.backingScaleFactor,
                                             retina: Settings.recordRetina)
        if format == .video {
            sizeLabel.stringValue = "\(video.width) × \(video.height)"
        } else {
            let width = min(CGFloat(video.width), max(16, (points.width * CGFloat(Settings.gifScale)).rounded()))
            let height = (CGFloat(video.height) * width / CGFloat(max(video.width, 1))).rounded()
            sizeLabel.stringValue = "\(Int(width)) × \(Int(height))"
        }
    }
}

// MARK: - Control durante la grabación

/// Píldora con el tiempo, parar, pausar y descartar. No sale en lo grabado.
final class RecordingPillView: RecordChrome {
    static let height: CGFloat = 44
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let dot = NSView()
    private let time = NSTextField(labelWithString: "0:00")
    private var stop: HoverButton!
    private var pause: HoverButton!
    private var discard: HoverButton!
    private let controls = NSStackView()
    private let saving = NSStackView()
    private let spinner = NSProgressIndicator()
    private var discardArmed = false
    private var discardToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        stop = HoverButton(symbol: "stop.fill", symbolSize: 10.5, size: CGSize(width: 28, height: 28),
                           tooltip: "Detener y guardar")
        stop.cornerRadius = nil
        stop.normalColor = RecordingStyle.red
        stop.hoverColor = NSColor(srgbRed: 1, green: 0.38, blue: 0.34, alpha: 1)
        stop.normalTint = .white
        stop.onClick = { [weak self] in self?.onStop?() }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        time.textColor = .white
        time.alignment = .left
        time.translatesAutoresizingMaskIntoConstraints = false

        pause = HoverButton(symbol: "pause.fill", symbolSize: 11, size: CGSize(width: 28, height: 28), tooltip: "Pausar")
        pause.cornerRadius = nil
        pause.onClick = { [weak self] in self?.onPause?() }
        discard = HoverButton(symbol: "trash", symbolSize: 11.5, size: CGSize(width: 28, height: 28),
                              tooltip: "Descartar la grabación")
        discard.cornerRadius = nil
        discard.normalTint = NSColor.white.withAlphaComponent(0.6)
        discard.onClick = { [weak self] in self?.discardTapped() }

        for view in [stop!, dot, time, RecordingStyle.divider(), pause!, discard!] as [NSView] {
            controls.addArrangedSubview(view)
        }
        controls.spacing = 8
        controls.setCustomSpacing(10, after: stop)
        controls.setCustomSpacing(6, after: dot)
        controls.setCustomSpacing(4, after: pause)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        let label = NSTextField(labelWithString: "Guardando…")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        saving.addArrangedSubview(spinner)
        saving.addArrangedSubview(label)
        saving.spacing = 8
        saving.isHidden = true
        saving.translatesAutoresizingMaskIntoConstraints = false
        addSubview(saving)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            time.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            saving.centerXAnchor.constraint(equalTo: centerXAnchor),
            saving.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    func set(elapsed: TimeInterval) {
        let text = Recording.format(elapsed.rounded(.down))
        if time.stringValue != text { time.stringValue = text }
    }

    /// El punto late en rojo mientras se graba, y se queda quieto y ámbar en pausa.
    func set(running: Bool, paused: Bool) {
        guard let layer = dot.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        let color = paused ? NSColor.systemYellow : (running ? RecordingStyle.red : NSColor.white.withAlphaComponent(0.35))
        withLayerAnimation(0.15) { layer.backgroundColor = color.cgColor }
        time.textColor = paused ? NSColor.white.withAlphaComponent(0.55) : .white
        pause.setSymbol(paused ? "play.fill" : "pause.fill", size: 11)
        pause.toolTip = paused ? "Continuar" : "Pausar"
        pause.isEnabled = running || paused
        if running, !paused, !Theme.reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }
    }

    func setSaving() {
        dot.layer?.removeAnimation(forKey: "pulse")
        controls.isHidden = true
        saving.isHidden = false
        spinner.startAnimation(nil)
    }

    /// Descartar pide un segundo clic: es lo único aquí que no tiene vuelta atrás.
    private func discardTapped() {
        if discardArmed {
            onDiscard?()
            return
        }
        discardArmed = true
        discardToken += 1
        let token = discardToken
        discard.setSymbol("trash.fill", size: 11.5)
        discard.normalTint = RecordingStyle.red
        discard.hoverTint = RecordingStyle.red
        discard.toolTip = "Pulsa otra vez para descartar"
        discard.springScale(to: 1, from: 1.25, stiffness: 420, damping: 14)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.discardToken == token else { return }
            self.discardArmed = false
            self.discard.setSymbol("trash", size: 11.5)
            self.discard.normalTint = NSColor.white.withAlphaComponent(0.6)
            self.discard.hoverTint = .white
            self.discard.toolTip = "Descartar la grabación"
        }
    }
}

// MARK: - Contorno y clics

/// Marca en pantalla lo que se va a grabar: atenúa el resto mientras se eligen las opciones
/// y deja un filo rojo alrededor durante la grabación.
final class RegionOutline {
    enum Style { case setup, recording, paused }

    private let panel: RecordPanel
    private let dim = CAShapeLayer()
    private let stroke = CAShapeLayer()

    init(rect: CGRect, on screen: NSScreen) {
        let frame = screen.frame
        panel = RecordingStyle.panel(frame: frame)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)

        let outside = CGMutablePath()
        outside.addRect(view.bounds)
        outside.addRect(local)
        dim.path = outside
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        // El filo va justo por fuera del área, para no pisar ni un píxel de lo grabado.
        stroke.path = CGPath(rect: local.insetBy(dx: -1, dy: -1), transform: nil)
        stroke.fillColor = nil
        stroke.shadowColor = NSColor.black.cgColor
        stroke.shadowOpacity = 0.5
        stroke.shadowRadius = 2
        stroke.shadowOffset = .zero
        view.layer?.addSublayer(dim)
        view.layer?.addSublayer(stroke)
        panel.contentView = view
        set(.setup, animated: false)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func set(_ style: Style, animated: Bool = true) {
        stroke.removeAnimation(forKey: "march")
        let apply = {
            switch style {
            case .setup:
                self.dim.opacity = 1
                self.stroke.strokeColor = NSColor.white.cgColor
                self.stroke.lineWidth = 1.5
                self.stroke.lineDashPattern = [6, 5]
            case .recording:
                self.dim.opacity = 0
                self.stroke.strokeColor = RecordingStyle.red.cgColor
                self.stroke.lineWidth = 2
                self.stroke.lineDashPattern = nil
            case .paused:
                self.dim.opacity = 0
                self.stroke.strokeColor = NSColor.systemYellow.cgColor
                self.stroke.lineWidth = 2
                self.stroke.lineDashPattern = [6, 5]
            }
        }
        if animated { withLayerAnimation(0.25, apply) } else { withoutActions(apply) }
        if style == .setup, !Theme.reduceMotion {
            let march = CABasicAnimation(keyPath: "lineDashPhase")
            march.fromValue = 0
            march.toValue = -11
            march.duration = 0.5
            march.repeatCount = .infinity
            stroke.add(march, forKey: "march")
        }
    }
}

/// Ventana transparente que dibuja una onda en cada clic. Es la única de Lince que sale en la grabación.
final class ClickOverlay {
    private let panel: RecordPanel
    private let host: CALayer
    private var monitors: [Any] = []

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(screen: NSScreen) {
        panel = RecordingStyle.panel(frame: screen.frame, level: .screenSaver)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        host = view.layer ?? CALayer()
        panel.contentView = view
    }

    func show() {
        panel.orderFrontRegardless()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.ripple(secondary: event.type == .rightMouseDown)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.ripple(secondary: event.type == .rightMouseDown)
            return event
        }) {
            monitors.append(local)
        }
    }

    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel.orderOut(nil)
    }

    func ripple(secondary: Bool = false, at location: CGPoint = NSEvent.mouseLocation) {
        let frame = panel.frame
        guard frame.contains(location) else { return }
        let ring = CALayer()
        let size: CGFloat = 46
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.position = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        ring.cornerRadius = size / 2
        let color = secondary ? NSColor.white : Theme.accent
        ring.backgroundColor = color.withAlphaComponent(0.3).cgColor
        ring.borderColor = color.withAlphaComponent(0.95).cgColor
        ring.borderWidth = 2
        ring.opacity = 0
        host.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.85, 0]
        fade.keyTimes = [0, 0.4, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.48
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}

// MARK: - Sesión de grabación

/// Lleva una grabación de principio a fin: opciones, cuenta atrás, grabación y entrega del resultado.
final class RecordingController {
    enum Phase { case idle, setup, countdown, starting, recording, paused, finishing }

    private(set) var phase = Phase.idle {
        didSet { if phase != oldValue { onStatus?() } }
    }
    /// La grabación terminada, lista para aparecer como miniatura.
    var onFinish: ((Capture, NSScreen, CGRect) -> Void)?
    var onError: ((Error) -> Void)?
    /// Cambia la fase o el tiempo transcurrido.
    var onStatus: (() -> Void)?

    private var target: RecordingTarget?
    private var recorder: ScreenRecorder?
    private var bar: RecordPanel?
    private var pill: RecordingPillView?
    private var outline: RegionOutline?
    private var clicks: ClickOverlay?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var lastStatus = ""

    var isActive: Bool { phase != .idle }
    /// Hay una grabación en marcha (o en pausa) que se puede detener.
    var isRecording: Bool { phase == .starting || phase == .recording || phase == .paused }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (pausedAt ?? Date()).timeIntervalSince(startedAt) - pausedTotal)
    }

    var elapsedText: String { Recording.format(elapsed.rounded(.down)) }

    // MARK: Opciones

    /// Enseña lo elegido y la barra de opciones.
    func begin(_ target: RecordingTarget) {
        guard phase == .idle else { return }
        self.target = target
        phase = .setup
        if !target.isFullScreen {
            let outline = RegionOutline(rect: target.frame, on: target.screen)
            outline.show()
            self.outline = outline
        }
        let view = RecordSetupView(target: target)
        view.onRecord = { [weak self] in self?.startRecording() }
        view.onCancel = { [weak self] in self?.cancel() }
        let panel = present(view)
        panel.acceptsKey = true
        panel.onReturn = { [weak self] in self?.startRecording() }
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Coloca un control junto al área: debajo si cabe, si no encima y, si tampoco, dentro.
    static func origin(for size: CGSize, around rect: CGRect, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        var y = max(visible.minY + 18, rect.minY + 18)
        if rect.minY - size.height - gap >= visible.minY + 4 {
            y = rect.minY - size.height - gap
        } else if rect.maxY + gap + size.height <= visible.maxY - 4 {
            y = rect.maxY + gap
        }
        let x = min(max(visible.minX + 8, rect.midX - size.width / 2), visible.maxX - size.width - 8)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    @discardableResult
    private func present(_ view: NSView) -> RecordPanel {
        bar?.orderOut(nil)
        guard let target else { return RecordingStyle.panel(frame: .zero) }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let origin = Self.origin(for: size, around: target.frame, on: target.screen)
        let panel = RecordingStyle.panel(frame: CGRect(origin: origin, size: size))
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = view
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        bar = panel
        return panel
    }

    // MARK: Grabación

    private func startRecording() {
        guard phase == .setup, let target else { return }
        bar?.orderOut(nil)
        bar = nil
        let seconds = Settings.recordCountdown
        guard seconds > 0 else {
            launch()
            return
        }
        phase = .countdown
        outline?.set(.recording)
        CountdownHUD.run(seconds: seconds, around: target.frame, on: target.screen, centered: true) { [weak self] done in
            guard let self, self.phase == .countdown else { return }
            if done { self.launch() } else { self.cancel() }
        }
    }

    /// Para las pruebas internas: empieza a grabar sin cuenta atrás.
    func debugLaunch() {
        guard phase == .setup else { return }
        bar?.orderOut(nil)
        bar = nil
        launch()
    }

    private func launch() {
        guard let target else { return }
        phase = .starting
        startedAt = nil
        pausedAt = nil
        pausedTotal = 0
        // Una ventana puede moverse mientras se graba: su contorno solo sirve hasta aquí.
        if target.isWindow {
            outline?.hide()
            outline = nil
        } else {
            outline?.set(.recording)
        }

        var options = ScreenRecorder.Options()
        options.fps = Settings.recordFPS
        options.showsCursor = Settings.recordCursor
        options.systemAudio = Settings.recordSystemAudio
        options.microphone = Settings.recordMicrophone && RecordSetupView.microphoneAllowed
        options.retina = Settings.recordRetina
        if Settings.recordClicks, !target.isWindow {
            let overlay = ClickOverlay(screen: target.screen)
            overlay.show()
            clicks = overlay
            options.includedWindows = [overlay.windowID]
        }

        let pill = RecordingPillView()
        pill.onStop = { [weak self] in self?.stop() }
        pill.onPause = { [weak self] in self?.togglePause() }
        pill.onDiscard = { [weak self] in self?.cancel() }
        pill.set(running: false, paused: false)
        self.pill = pill
        present(pill)

        let recorder = ScreenRecorder(target: target, options: options, outputURL: RecordingStore.newURL())
        recorder.onStart = { [weak self, weak recorder] in
            guard let self, self.recorder === recorder, self.phase == .starting else { return }
            self.startedAt = Date()
            self.phase = .recording
            self.pill?.set(running: true, paused: false)
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        recorder.onInterrupted = { [weak self, weak recorder] in
            guard let self, self.recorder === recorder else { return }
            // Lo grabado hasta el corte se conserva.
            Toast.show("La grabación se ha detenido", symbol: "exclamationmark.triangle", on: target.screen)
            self.stop()
        }
        self.recorder = recorder
        Task { @MainActor [weak self] in
            do {
                try await recorder.start()
                // Si se canceló mientras arrancaba, la captura recién abierta se cierra.
                if self?.recorder !== recorder { await recorder.cancel() }
            } catch {
                guard let self, self.recorder === recorder else { return }
                self.tearDown()
                self.onError?(error)
            }
        }
    }

    private func tick() {
        pill?.set(elapsed: elapsed)
        let text = elapsedText
        if text != lastStatus {
            lastStatus = text
            onStatus?()
        }
    }

    func togglePause() {
        guard let recorder else { return }
        if phase == .recording {
            recorder.pause()
            pausedAt = Date()
            phase = .paused
            outline?.set(.paused)
            pill?.set(running: false, paused: true)
        } else if phase == .paused {
            recorder.resume()
            if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
            phase = .recording
            outline?.set(.recording)
            pill?.set(running: true, paused: false)
        }
    }

    /// Detiene, cierra el archivo y entrega la grabación.
    func stop() {
        guard isRecording, let recorder, let target else { return }
        phase = .finishing
        timer?.invalidate()
        timer = nil
        outline?.hide()
        clicks?.hide()
        pill?.setSaving()
        Task { @MainActor [weak self] in
            do {
                let result = try await recorder.stop()
                RecordingStore.setScale(result.scale, for: result.url)
                let recording = Recording(movieURL: result.url, duration: result.duration, width: result.width,
                                          height: result.height, scale: result.scale, hasAudio: result.hasAudio)
                let capture = Capture(recording: recording, poster: result.poster)
                capture.sourceRect = target.frame
                self?.tearDown()
                self?.onFinish?(capture, target.screen, target.frame)
                RecordingStore.purge(keeping: [result.url])
            } catch {
                self?.tearDown()
                if case RecordingError.empty = error {
                    Toast.show("La grabación era demasiado corta", symbol: "exclamationmark.triangle", on: target.screen)
                } else {
                    self?.onError?(error)
                }
            }
        }
    }

    /// Cancela en cualquier fase; si ya se estaba grabando, lo grabado se descarta.
    func cancel() {
        guard phase != .idle, phase != .finishing else { return }
        let wasRecording = isRecording
        let wasCounting = phase == .countdown
        let recorder = self.recorder
        let screen = target?.screen
        tearDown()
        if wasCounting { CountdownHUD.cancel() }
        guard wasRecording, let recorder else { return }
        Task { @MainActor in
            await recorder.cancel()
            if let screen { Toast.show("Grabación descartada", symbol: "trash", on: screen) }
        }
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        bar?.orderOut(nil)
        bar = nil
        pill = nil
        outline?.hide()
        outline = nil
        clicks?.hide()
        clicks = nil
        recorder = nil
        target = nil
        startedAt = nil
        pausedAt = nil
        lastStatus = ""
        phase = .idle
    }
}
