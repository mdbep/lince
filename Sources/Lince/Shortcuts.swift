import AppKit
import Carbon.HIToolbox

/// Una combinación de teclas global: código de tecla y modificadores de Carbon.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: Int

    /// Las teclas una a una, para pintarlas como teclas sueltas: ["⌃", "⇧", "4"].
    var keys: [String] {
        var keys: [String] = []
        if modifiers & controlKey != 0 { keys.append("⌃") }
        if modifiers & optionKey != 0 { keys.append("⌥") }
        if modifiers & shiftKey != 0 { keys.append("⇧") }
        if modifiers & cmdKey != 0 { keys.append("⌘") }
        keys.append(Shortcut.keyName(keyCode))
        return keys
    }

    var display: String { keys.joined() }

    /// Equivalente para un elemento de menú; vacío si la tecla no se puede representar.
    var menuKey: String {
        if keyCode == kVK_Space { return " " }
        let name = Shortcut.keyName(keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A partir de una pulsación; `nil` si no lleva ⌘, ⌃ ni ⌥, que es lo mínimo para un atajo global.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        guard modifiers & (controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Espacio", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Nombre de la tecla según la distribución de teclado activa.
    static func keyName(_ keyCode: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count,
                                  &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Las acciones que pueden tener un atajo global.
enum ShortcutAction: String, CaseIterable {
    case area, window, fullScreen, text, repeatArea, palette

    var title: String {
        switch self {
        case .area: return "Capturar área"
        case .window: return "Capturar ventana"
        case .fullScreen: return "Capturar pantalla completa"
        case .text: return "Copiar texto de la pantalla"
        case .repeatArea: return "Repetir última área"
        case .palette: return "Paleta de comandos"
        }
    }

    var defaultShortcut: Shortcut? {
        let base = controlKey | shiftKey
        switch self {
        case .area: return Shortcut(keyCode: kVK_ANSI_4, modifiers: base)
        case .window: return nil
        case .fullScreen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: base)
        case .text: return Shortcut(keyCode: kVK_ANSI_2, modifiers: base)
        case .repeatArea: return Shortcut(keyCode: kVK_ANSI_5, modifiers: base)
        case .palette: return Shortcut(keyCode: kVK_Space, modifiers: base)
        }
    }
}

/// Guarda los atajos elegidos y avisa cuando cambian para volver a registrarlos.
enum ShortcutStore {
    static var onChange: (() -> Void)?
    /// Mientras se graba un atajo nuevo, los globales se sueltan para que no se disparen.
    static var onRecording: ((Bool) -> Void)?

    private static let defaults = UserDefaults.standard
    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }

    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard let stored = defaults.array(forKey: key(action)) as? [Int] else { return action.defaultShortcut }
        return stored.count == 2 ? Shortcut(keyCode: stored[0], modifiers: stored[1]) : nil
    }

    /// `nil` deja la acción sin atajo.
    static func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        defaults.set(shortcut.map { [$0.keyCode, $0.modifiers] } ?? [], forKey: key(action))
        onChange?()
    }

    static func resetAll() {
        for action in ShortcutAction.allCases { defaults.removeObject(forKey: key(action)) }
        onChange?()
    }

    /// La acción que ya usa esa combinación, si hay alguna distinta de `action`.
    static func owner(of shortcut: Shortcut, besides action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.shortcut(for: $0) == shortcut }
    }
}

/// Campo para grabar un atajo: se pulsa, se teclea la combinación y queda guardada.
final class ShortcutRecorder: NSView {
    private let action: ShortcutAction
    private let label = NSTextField(labelWithString: "")
    private let background = CALayer()
    private var monitor: Any?
    private var isRecording = false
    private var messageToken = 0

    init(action: ShortcutAction) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        background.cornerRadius = 7
        background.cornerCurve = .continuous
        background.borderWidth = 1
        layer?.addSublayer(background)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 132),
            heightAnchor.constraint(equalToConstant: 26),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        toolTip = "Haz clic y pulsa la combinación. ⌫ lo quita y Esc cancela."
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    override func layout() {
        super.layout()
        withoutActions { background.frame = bounds }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stop() : start()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    func refresh() {
        let shortcut = ShortcutStore.shortcut(for: action)
        if isRecording {
            label.stringValue = "Pulsa el atajo…"
            label.textColor = Theme.accent
        } else {
            label.stringValue = shortcut.map { $0.keys.joined(separator: " ") } ?? "Sin atajo"
            label.textColor = shortcut == nil ? NSColor.white.withAlphaComponent(0.4) : .white
        }
        withLayerAnimation(0.15) {
            background.backgroundColor = NSColor.white.withAlphaComponent(isRecording ? 0.04 : 0.09).cgColor
            background.borderColor = (isRecording ? Theme.accent : NSColor.white.withAlphaComponent(0.12)).cgColor
        }
    }

    private func start() {
        guard !isRecording else { return }
        isRecording = true
        ShortcutStore.onRecording?(true)
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .leftMouseDown {
                // Un clic fuera del campo termina la grabación sin cambiar nada.
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.stop()
                }
                return event
            }
            self.handle(event)
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ShortcutStore.onRecording?(false)
        refresh()
    }

    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, Int(event.keyCode) == kVK_Escape {
            stop()
        } else if plain, Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            ShortcutStore.set(nil, for: action)
            stop()
        } else if let shortcut = Shortcut(event: event) {
            if ShortcutStore.owner(of: shortcut, besides: action) != nil {
                flash("Ya está en uso")
            } else {
                ShortcutStore.set(shortcut, for: action)
                stop()
            }
        } else {
            flash("Añade ⌘, ⌃ o ⌥")
        }
    }

    /// Aviso breve dentro del campo, con una sacudida, cuando la combinación no vale.
    private func flash(_ message: String) {
        messageToken += 1
        let token = messageToken
        label.stringValue = message
        if !Theme.reduceMotion, let layer {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -5, 5, -3, 3, 0]
            shake.duration = 0.3
            layer.add(shake, forKey: "shake")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.refresh()
        }
    }
}
