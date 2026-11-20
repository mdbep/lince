import AppKit

/// Ventana de bienvenida: permiso de pantalla, atajos y cómo sustituir los de macOS.
final class WelcomeController: NSObject, NSWindowDelegate {
    static let shared = WelcomeController()

    private(set) var window: NSWindow?
    /// Avisa a la app para que tome o suelte ⌘⇧3/4 al instante.
    var onShortcutsChanged: (() -> Void)?
    private var timer: Timer?
    private var requestedPermission = false

    private let permissionIcon = NSImageView()
    private let permissionDetail = NSTextField(wrappingLabelWithString: "")
    private var permissionButton: HoverButton!
    private let shortcutIcon = NSImageView()
    private let shortcutDetail = NSTextField(wrappingLabelWithString: "")
    private var shortcutButton: HoverButton!
    private let areaKeys = NSStackView()
    private let fullKeys = NSStackView()
    private let textKeys = NSStackView()
    private let repeatKeys = NSStackView()

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        Settings.didShowWelcome = true
    }

    // MARK: Construcción

    func build() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 620),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.chrome
        window.isMovableByWindowBackground = true
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
        ])

        let title = NSTextField(labelWithString: "Lince")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .white
        let subtitle = NSTextField(labelWithString: "Capturas rápidas, limpias y siempre a mano.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.55)

        permissionButton = makeButton("Conceder permiso", primary: true) { [weak self] in self?.permissionTapped() }
        let permissionCard = card(icon: permissionIcon, title: "Grabación de pantalla",
                                  detail: permissionDetail, button: permissionButton)

        shortcutButton = makeButton("Usar ⌘⇧3 y ⌘⇧4 con Lince", primary: true) { [weak self] in
            self?.takeOverShortcuts()
        }
        let rows = NSStackView(views: [shortcutRow("Capturar área", keys: areaKeys),
                                       shortcutRow("Pantalla completa", keys: fullKeys),
                                       shortcutRow("Copiar texto (OCR)", keys: textKeys),
                                       shortcutRow("Repetir última área", keys: repeatKeys)])
        rows.orientation = .vertical
        rows.spacing = 8
        rows.alignment = .leading
        let shortcutCard = card(icon: shortcutIcon, title: "Atajos de teclado",
                                detail: shortcutDetail, button: shortcutButton, extra: rows)

        let start = makeButton("Empezar", primary: true, size: CGSize(width: 150, height: 32)) { [weak self] in
            self?.window?.close()
        }

        let stack = NSStackView(views: [icon, title, subtitle, permissionCard, shortcutCard, start])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(26, after: subtitle)
        stack.setCustomSpacing(12, after: permissionCard)
        stack.setCustomSpacing(24, after: shortcutCard)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.chrome.cgColor
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        window.contentView = root
        self.window = window
    }

    private func makeButton(_ title: String, primary: Bool, size: CGSize? = nil,
                            action: @escaping () -> Void) -> HoverButton {
        let button = HoverButton(title: title, fontSize: 12.5, size: size)
        button.cornerRadius = nil
        if primary {
            button.normalColor = Theme.accent
            button.hoverColor = Theme.accent.blended(withFraction: 0.12, of: .white) ?? Theme.accent
            button.normalTint = .white
        } else {
            button.normalColor = NSColor.white.withAlphaComponent(0.1)
            button.hoverColor = NSColor.white.withAlphaComponent(0.17)
        }
        button.onClick = action
        return button
    }

    private func card(icon: NSImageView, title: String, detail: NSTextField,
                      button: HoverButton, extra: NSView? = nil) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.hairline.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = .white
        let header = NSStackView(views: [icon, titleLabel])
        header.spacing = 8

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor.white.withAlphaComponent(0.6)
        detail.isSelectable = false

        var views: [NSView] = [header]
        if let extra { views.append(extra) }
        views.append(contentsOf: [detail, button])
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return card
    }

    private func shortcutRow(_ title: String, keys: NSStackView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        keys.spacing = 4
        let row = NSStackView(views: [label, keys])
        row.spacing = 8
        return row
    }

    private func keycap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
        cap.layer?.cornerRadius = 6
        cap.layer?.cornerCurve = .continuous
        cap.layer?.borderWidth = 1
        cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            cap.widthAnchor.constraint(equalToConstant: 26),
            cap.heightAnchor.constraint(equalToConstant: 24),
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        return cap
    }

    // MARK: Estado

    private func setStatus(_ icon: NSImageView, ok: Bool) {
        icon.image = Theme.symbol(ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", size: 15)
        icon.contentTintColor = ok ? NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1) : Theme.accent
    }

    private func setKeys(_ stack: NSStackView, _ keys: [String]) {
        guard stack.arrangedSubviews.count != keys.count
                || zip(stack.arrangedSubviews, keys).contains(where: { ($0.subviews.first as? NSTextField)?.stringValue != $1 })
        else { return }
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for key in keys { stack.addArrangedSubview(keycap(key)) }
    }

    func refresh() {
        let granted = ScreenCapturer.hasPermission
        setStatus(permissionIcon, ok: granted)
        if granted {
            permissionDetail.stringValue = "Permiso concedido. Lince ya puede capturar tu pantalla."
            permissionButton.isHidden = true
        } else if requestedPermission {
            permissionDetail.stringValue = "Activa Lince en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema. macOS solo lo aplica al reiniciar la app."
            permissionButton.setTitle("Reiniciar Lince")
            permissionButton.isHidden = false
        } else {
            permissionDetail.stringValue = "macOS necesita tu permiso para que Lince pueda ver la pantalla. Las capturas no salen de tu Mac."
            permissionButton.setTitle("Conceder permiso")
            permissionButton.isHidden = false
        }

        let native = SystemShortcuts.nativeScreenshotsEnabled
        setStatus(shortcutIcon, ok: !native)
        let modifier = native ? "⌃" : "⌘"
        setKeys(areaKeys, [modifier, "⇧", "4"])
        setKeys(fullKeys, [modifier, "⇧", "3"])
        setKeys(textKeys, ["⌃", "⇧", "2"])
        setKeys(repeatKeys, ["⌃", "⇧", "5"])
        if native {
            shortcutDetail.stringValue = shortcutFailed
                ? "macOS no ha dejado cambiarlo desde aquí. Hazlo a mano en Ajustes › Teclado › Funciones rápidas de teclado › Capturas de pantalla, desmarcando las dos primeras."
                : "Ahora mismo ⌘⇧3 y ⌘⇧4 son de macOS. Con un clic pasan a Lince; puedes devolvérselos cuando quieras desde el menú."
            shortcutButton.setTitle(shortcutFailed ? "Abrir ajustes de teclado" : "Usar ⌘⇧3 y ⌘⇧4 con Lince")
            shortcutButton.isHidden = false
        } else {
            shortcutDetail.stringValue = "Lince ha sustituido los atajos de captura de macOS. ⌃⇧3 y ⌃⇧4 también siguen funcionando."
            shortcutButton.isHidden = true
        }
    }

    private var shortcutFailed = false

    private func takeOverShortcuts() {
        if shortcutFailed {
            SystemShortcuts.openKeyboardSettings()
            return
        }
        shortcutFailed = !SystemShortcuts.setNativeScreenshots(enabled: false)
        onShortcutsChanged?()
        refresh()
    }

    private func permissionTapped() {
        if requestedPermission {
            WelcomeController.relaunch()
            return
        }
        requestedPermission = true
        ScreenCapturer.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
