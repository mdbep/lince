import AppKit
import ServiceManagement

/// Ventana de ajustes: cuatro pestañas (General, Captura, Grabación y Atajos) con cambios que se aplican al momento.
final class SettingsController: NSObject, NSWindowDelegate {
    static let shared = SettingsController()

    /// Avisa a la app cuando cambia quién tiene ⌘⇧3 y ⌘⇧4.
    var onSystemShortcutsChanged: (() -> Void)?
    var onError: ((Error) -> Void)?

    private var window: NSWindow?
    private var tabButtons: [HoverButton] = []
    private var pages: [NSView] = []
    private let pageHost = NSView()
    private var pageHeight: NSLayoutConstraint!
    private var current = 0
    private var refreshers: [() -> Void] = []
    private var recorders: [ShortcutRecorder] = []
    private var timer: Timer?

    private static let width: CGFloat = 520
    private static let inset: CGFloat = 24
    private static let tabs = [("General", "gearshape"), ("Captura", "viewfinder"),
                               ("Grabación", "record.circle"), ("Atajos", "keyboard")]
    /// Posición de la pestaña de atajos, para abrirla directamente.
    static let shortcutsTab = 3

    func show(tab: Int? = nil) {
        if window == nil { build() }
        if let tab { select(tab, animated: false) }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        // Algunos ajustes pueden cambiar fuera de Lince (el inicio de sesión, los atajos de macOS).
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        refreshers.forEach { $0() }
        recorders.forEach { $0.refresh() }
    }

    // MARK: Construcción

    private func build() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Ajustes de Lince"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.chrome
        window.isMovableByWindowBackground = true
        window.delegate = self
        let toolbar = NSToolbar(identifier: "LinceSettings")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentView = makeContent()
        self.window = window
        select(0, animated: false)
    }

    /// El contenido completo; separado de la ventana para poder renderizarlo en las pruebas.
    func makeContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.chrome.cgColor

        tabButtons = Self.tabs.enumerated().map { index, tab in
            let button = HoverButton(symbol: tab.1, title: tab.0, symbolSize: 12, fontSize: 12.5, padding: 14, height: 30)
            button.cornerRadius = nil
            button.selectedColor = NSColor.white.withAlphaComponent(0.14)
            button.onClick = { [weak self] in self?.select(index, animated: true) }
            return button
        }
        let tabBar = NSStackView(views: tabButtons)
        tabBar.spacing = 4
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false

        pages = [generalPage(), capturePage(), recordingPage(), shortcutsPage()]
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = true
            pageHost.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                page.topAnchor.constraint(equalTo: pageHost.topAnchor),
            ])
        }
        pageHeight = pageHost.heightAnchor.constraint(equalToConstant: 100)

        for view in [tabBar, line, pageHost] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            tabBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabBar.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            line.heightAnchor.constraint(equalToConstant: 1),
            pageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            pageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            pageHost.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 20),
            pageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.inset),
            pageHeight,
        ])
        return root
    }

    /// Muestra una pestaña y ajusta el alto de la ventana a su contenido.
    func select(_ index: Int, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        current = index
        for (offset, button) in tabButtons.enumerated() { button.isSelected = offset == index }
        for (offset, page) in pages.enumerated() { page.isHidden = offset != index }
        let height = pages[index].fittingSize.height
        guard let window, let content = window.contentView else {
            pageHeight.constant = height
            return
        }
        pageHeight.constant = height
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: Self.width, height: content.fittingSize.height)
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if animated, !Theme.reduceMotion {
            pages[index].alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                window.animator().setFrame(frame, display: true)
                pages[index].animator().alphaValue = 1
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: Páginas

    private func generalPage() -> NSView {
        let login = toggle { SMAppService.mainApp.status == .enabled } set: { [weak self] on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self?.onError?(error)
            }
        }

        let path = NSTextField(labelWithString: "")
        path.font = .systemFont(ofSize: 12)
        path.textColor = NSColor.white.withAlphaComponent(0.5)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshers.append {
            path.stringValue = (Settings.saveDirectory.path as NSString).abbreviatingWithTildeInPath
        }
        let change = pill("Cambiar…") { [weak self] in self?.chooseFolder() }
        let folder = NSStackView(views: [path, change])
        folder.spacing = 10

        let sound = NSSegmentedControl(labels: ShutterSound.allCases.map(\.label), trackingMode: .selectOne,
                                       target: self, action: #selector(soundChanged(_:)))
        sound.controlSize = .small
        refreshers.append {
            sound.selectedSegment = ShutterSound.allCases.firstIndex(of: Settings.shutterSound) ?? 0
        }

        return card([
            row("Abrir al iniciar sesión", "Lince queda lista en la barra de menús al encender el Mac.", login),
            row("Carpeta de guardado", nil, folder),
            row("Sonido al capturar", "Al elegir uno, suena para que lo oigas.", sound),
        ])
    }

    private func capturePage() -> NSView {
        card([
            row("Lupa al seleccionar", "Amplía la zona bajo el cursor para afinar al píxel.",
                toggle { Settings.showsLoupe } set: { Settings.showsLoupe = $0 }),
            row("Imán en los bordes", "La selección se pega a los bordes de las ventanas. Con ⌘ pulsado, no.",
                toggle { Settings.magnet } set: { Settings.magnet = $0 }),
            row("Ocultar los iconos del escritorio", "No salen en las capturas; tu escritorio no cambia.",
                toggle { Settings.hidesDesktopIcons } set: { Settings.hidesDesktopIcons = $0 }),
            row("Sombra en las capturas de ventana", "Añade a cada ventana una sombra como la del sistema.",
                toggle { Settings.windowShadow } set: { Settings.windowShadow = $0 }),
        ])
    }

    private func recordingPage() -> NSView {
        card([
            row("Cuenta atrás", "Tiempo para prepararte antes de que empiece a grabar.",
                choice(["Sin cuenta", "3 s", "5 s"], values: [0, 3, 5]) { Settings.recordCountdown } set: {
                    Settings.recordCountdown = $0
                }),
            row("Fluidez del vídeo", "A 60 el movimiento es más suave y el archivo pesa más.",
                choice(["30 fps", "60 fps"], values: [30, 60]) { Settings.recordFPS } set: { Settings.recordFPS = $0 }),
            row("Resolución Retina", "Graba todos los píxeles de la pantalla. Sin ella, los archivos pesan mucho menos.",
                toggle { Settings.recordRetina } set: { Settings.recordRetina = $0 }),
            row("Mostrar el cursor", nil,
                toggle { Settings.recordCursor } set: { Settings.recordCursor = $0 }),
            row("Resaltar los clics", "Dibuja una onda alrededor del cursor cada vez que haces clic.",
                toggle { Settings.recordClicks } set: { Settings.recordClicks = $0 }),
        ])
    }

    private func shortcutsPage() -> NSView {
        var rows: [NSView] = ShortcutAction.allCases.map { action in
            let recorder = ShortcutRecorder(action: action)
            recorders.append(recorder)
            return row(action.title, nil, recorder)
        }
        let system = toggle { !SystemShortcuts.nativeScreenshotsEnabled } set: { [weak self] on in
            if !SystemShortcuts.setNativeScreenshots(enabled: !on) { SystemShortcuts.openKeyboardSettings() }
            self?.onSystemShortcutsChanged?()
        }
        rows.append(row("Usar también ⌘⇧3 y ⌘⇧4", "Lince sustituye a la captura de macOS en esos dos atajos.", system))

        let reset = pill("Restablecer atajos") { ShortcutStore.resetAll() }
        let footer = NSStackView(views: [NSView(), reset])
        let page = NSStackView(views: [card(rows), footer])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        return page
    }

    // MARK: Piezas

    /// Tarjeta con filas separadas por una línea fina.
    private func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = Theme.hairline.cgColor
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.heightAnchor.constraint(equalToConstant: 1),
                    line.widthAnchor.constraint(equalTo: stack.widthAnchor),
                ])
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.hairline.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Self.width - Self.inset * 2),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
        ])
        return card
    }

    private func row(_ title: String, _ detail: String?, _ control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .white
        let texts = NSStackView(views: [titleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11.5)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.48)
            texts.addArrangedSubview(detailLabel)
        }
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSView()
        for view in [texts, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            texts.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            texts.topAnchor.constraint(equalTo: row.topAnchor, constant: 11),
            texts.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -11),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 170),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return row
    }

    private var toggleActions: [ObjectIdentifier: (Bool) -> Void] = [:]
    private var choiceActions: [ObjectIdentifier: (Int) -> Void] = [:]

    /// Selector de unas pocas opciones, cada una con su valor.
    private func choice(_ labels: [String], values: [Int], _ get: @escaping () -> Int,
                        set: @escaping (Int) -> Void) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self,
                                         action: #selector(choiceChanged(_:)))
        control.controlSize = .small
        choiceActions[ObjectIdentifier(control)] = { index in
            if values.indices.contains(index) { set(values[index]) }
        }
        refreshers.append { [weak control] in
            control?.selectedSegment = values.firstIndex(of: get()) ?? 0
        }
        return control
    }

    @objc private func choiceChanged(_ sender: NSSegmentedControl) {
        choiceActions[ObjectIdentifier(sender)]?(sender.selectedSegment)
    }

    private func toggle(_ get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.target = self
        control.action = #selector(toggleChanged(_:))
        toggleActions[ObjectIdentifier(control)] = set
        refreshers.append { [weak control] in
            guard let control else { return }
            let state: NSControl.StateValue = get() ? .on : .off
            if control.state != state { control.state = state }
        }
        return control
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        toggleActions[ObjectIdentifier(sender)]?(sender.state == .on)
        // Si el cambio no se pudo aplicar, el interruptor vuelve a reflejar la realidad.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> HoverButton {
        let button = HoverButton(title: title, fontSize: 12, padding: 12, height: 26)
        button.cornerRadius = nil
        button.normalColor = NSColor.white.withAlphaComponent(0.1)
        button.hoverColor = NSColor.white.withAlphaComponent(0.17)
        button.onClick = action
        return button
    }

    @objc private func soundChanged(_ sender: NSSegmentedControl) {
        guard ShutterSound.allCases.indices.contains(sender.selectedSegment) else { return }
        let sound = ShutterSound.allCases[sender.selectedSegment]
        Settings.shutterSound = sound
        Shutter.play(sound)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveDirectory
        panel.prompt = "Elegir"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { Settings.saveDirectory = url }
            self?.refresh()
        }
    }
}
