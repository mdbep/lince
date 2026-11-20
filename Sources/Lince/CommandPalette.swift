import AppKit

/// Una acción de la paleta de comandos.
struct Command {
    let title: String
    let symbol: String
    /// Palabras extra por las que también se encuentra.
    var keywords = ""
    /// Teclas del atajo, si lo tiene, para mostrarlas a la derecha.
    var keys: [String] = []
    let run: () -> Void

    /// Texto de búsqueda sin mayúsculas ni tildes.
    fileprivate var haystack: String { CommandPaletteController.normalize(title + " " + keywords) }
}

/// Buscador flotante con todas las acciones de Lince: se abre con un atajo, se escribe y se pulsa retorno.
final class CommandPaletteController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = CommandPaletteController()

    /// La app entrega aquí la lista de acciones cada vez que se abre la paleta.
    var commands: () -> [Command] = { [] }

    private var panel: PalettePanel?
    private let field = NSTextField()
    private let list = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nada con ese nombre")
    private var all: [Command] = []
    private var matches: [Command] = []
    private var selected = 0
    private var firstVisible = 0

    static let width: CGFloat = 580
    private static let headerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 40
    private static let maxRows = 8
    private static let listInset: CGFloat = 8

    var isVisible: Bool { panel?.isVisible ?? false }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    /// Las acciones que casan con lo escrito: primero las que empiezan por ello, luego el resto.
    static func filter(_ commands: [Command], query: String) -> [Command] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return commands }
        let found = commands.filter { command in
            let haystack = command.haystack
            return words.allSatisfy { haystack.contains($0) }
        }
        let start = words[0]
        func rank(_ command: Command) -> Int {
            let title = normalize(command.title)
            if title.hasPrefix(start) { return 0 }
            return title.split(separator: " ").contains { $0.hasPrefix(start) } ? 1 : 2
        }
        return found.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        all = commands()
        field.stringValue = ""
        update()
        let screen = NSScreen.underMouse
        let height = panelHeight
        let frame = CGRect(x: (screen.frame.midX - Self.width / 2).rounded(),
                           y: (screen.visibleFrame.maxY - screen.visibleFrame.height * 0.2 - height).rounded(),
                           width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        panel.contentView?.springScale(to: 1, from: 0.96, stiffness: 520, damping: 30)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Construcción

    private func build() {
        let panel = PalettePanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 200),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let content = makeContent()
        panel.contentView = content
        self.panel = panel
    }

    /// El contenido completo; separado de la ventana para poder renderizarlo en las pruebas.
    func makeContent() -> NSView {
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.appearance = NSAppearance(named: .vibrantDark)
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let icon = NSImageView()
        icon.image = Theme.menuBarIcon()
        icon.contentTintColor = Theme.accent
        icon.imageScaling = .scaleProportionallyUpOrDown

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "¿Qué quieres hacer?",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.32),
                         .font: NSFont.systemFont(ofSize: 20, weight: .regular)])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        for view in [icon, field, separator, list, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Self.headerHeight / 2),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.headerHeight),
            separator.heightAnchor.constraint(equalToConstant: 1),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.listInset),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.listInset),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Self.listInset),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Self.listInset + 11),
        ])
        return root
    }

    private var visibleRows: Int { min(matches.count, Self.maxRows) }

    private var panelHeight: CGFloat {
        Self.headerHeight + 1 + Self.listInset * 2 + CGFloat(max(visibleRows, 1)) * Self.rowHeight
    }

    // MARK: Resultados

    /// Para las pruebas: carga unas acciones y un texto sin abrir la ventana.
    func debugLoad(_ commands: [Command], query: String) -> CGSize {
        all = commands
        field.stringValue = query
        update()
        return CGSize(width: Self.width, height: panelHeight)
    }

    private func update() {
        matches = Self.filter(all, query: field.stringValue)
        selected = 0
        firstVisible = 0
        rebuildRows()
        guard let panel, panel.isVisible else { return }
        // La ventana crece o encoge hacia abajo, con el campo de búsqueda siempre en su sitio.
        var frame = panel.frame
        let height = panelHeight
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func rebuildRows() {
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        emptyLabel.isHidden = !matches.isEmpty
        guard !matches.isEmpty else { return }
        let last = min(matches.count, firstVisible + Self.maxRows)
        for index in firstVisible..<last {
            let row = CommandRow(command: matches[index], width: Self.width - Self.listInset * 2,
                                 height: Self.rowHeight)
            row.isSelected = index == selected
            row.onHover = { [weak self] in self?.select(index, scroll: false) }
            row.onClick = { [weak self] in self?.run(index) }
            list.addArrangedSubview(row)
        }
    }

    private func select(_ index: Int, scroll: Bool = true) {
        guard !matches.isEmpty else { return }
        let target = (index + matches.count) % matches.count
        guard target != selected else { return }
        selected = target
        if scroll, selected < firstVisible || selected >= firstVisible + Self.maxRows {
            firstVisible = min(max(0, selected - Self.maxRows + 1), max(0, selected))
            if selected < firstVisible { firstVisible = selected }
            rebuildRows()
            return
        }
        for (offset, view) in list.arrangedSubviews.enumerated() {
            (view as? CommandRow)?.isSelected = firstVisible + offset == selected
        }
    }

    private func run(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        let command = matches[index]
        close()
        // La paleta se retira antes de actuar, para que no salga en la captura ni tape nada.
        DispatchQueue.main.async { command.run() }
    }

    // MARK: Teclado

    func controlTextDidChange(_ notification: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(selected + 1)
        case #selector(NSResponder.moveUp(_:)):
            select(selected - 1)
        case #selector(NSResponder.insertNewline(_:)):
            run(selected)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }
}

final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Una fila de la paleta: icono, nombre y, a la derecha, las teclas de su atajo.
final class CommandRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { refresh() } } }

    private let background = CALayer()
    private let icon = NSImageView()
    private var lastMouse: CGPoint?

    init(command: Command, width: CGFloat, height: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        background.cornerRadius = 9
        background.cornerCurve = .continuous
        layer?.addSublayer(background)

        icon.image = Theme.symbol(command.symbol, size: 14, weight: .medium)
        icon.imageScaling = .scaleNone
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 14)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail

        let keys = NSStackView(views: command.keys.map(CommandRow.keycap))
        keys.spacing = 3

        for view in [icon, title, keys] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 23),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 46),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    private static func keycap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        cap.layer?.cornerRadius = 5
        cap.layer?.cornerCurve = .continuous
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: 20),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        return cap
    }

    override func layout() {
        super.layout()
        withoutActions { background.frame = bounds }
    }

    private func refresh() {
        withoutActions {
            background.backgroundColor = isSelected ? Theme.accent.withAlphaComponent(0.9).cgColor : NSColor.clear.cgColor
        }
        icon.contentTintColor = isSelected ? .white : Theme.accent
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Solo un movimiento real del ratón cambia la selección: si las filas se recolocan bajo
    /// un cursor quieto mientras se escribe, manda el teclado.
    override func mouseMoved(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        if let lastMouse, lastMouse == location { return }
        lastMouse = location
        onHover?()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
