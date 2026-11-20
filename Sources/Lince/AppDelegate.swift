import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ThumbnailActions {
    private var statusItem: NSStatusItem!
    private var areaItem: NSMenuItem!
    private var fullItem: NSMenuItem!
    private var repeatItem: NSMenuItem!
    private var overrideItem: NSMenuItem!
    private var loupeItem: NSMenuItem!
    private var iconsItem: NSMenuItem!
    private var shadowItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let selection = SelectionController()
    private let thumbnails = ThumbnailManager()
    private var editors: [EditorController] = []
    private var isCapturing = false
    private var shortcutTimer: Timer?
    private var commandShortcutIDs: [UInt32] = []
    /// La app que estaba delante al empezar a capturar, para devolverle el foco al terminar.
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Modo interno: renderiza las pantallas a PNG para revisar el diseño y termina.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > index + 1 {
            Snapshot.run(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            NSApp.terminate(nil)
            return
        }

        thumbnails.actions = self
        WelcomeController.shared.onShortcutsChanged = { [weak self] in self?.syncSystemShortcuts() }
        HistoryController.shared.onRestore = { [weak self] entry in self?.restore(entry) }
        buildStatusItem()

        // ⌃⇧ + número: siempre disponibles.
        let hotKeys: [(Int, () -> Void)] = [
            (kVK_ANSI_4, { [weak self] in self?.captureArea() }),
            (kVK_ANSI_3, { [weak self] in self?.captureFullScreen() }),
            (kVK_ANSI_2, { [weak self] in self?.captureText() }),
            (kVK_ANSI_5, { [weak self] in self?.repeatLastArea() }),
        ]
        for (keyCode, handler) in hotKeys {
            HotKeyCenter.shared.register(keyCode: keyCode, modifiers: controlKey | shiftKey, handler: handler)
        }
        // ⌘⇧3/4 solo se toman cuando macOS los ha soltado; si no, se dispararían los dos a la vez.
        syncSystemShortcuts()
        shortcutTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.syncSystemShortcuts()
        }
        shortcutTimer?.tolerance = 1

        if !Settings.didShowWelcome || !ScreenCapturer.hasPermission {
            WelcomeController.shared.show()
        }
    }

    /// Registra o suelta ⌘⇧3/4 según estén o no activos los atajos nativos de macOS.
    private func syncSystemShortcuts() {
        let shouldOwn = !SystemShortcuts.nativeScreenshotsEnabled
        guard shouldOwn != !commandShortcutIDs.isEmpty else { return }
        if shouldOwn {
            let area = HotKeyCenter.shared.register(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey) { [weak self] in
                self?.captureArea()
            }
            let full = HotKeyCenter.shared.register(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey) { [weak self] in
                self?.captureFullScreen()
            }
            commandShortcutIDs = [area, full].compactMap { $0 }
        } else {
            for id in commandShortcutIDs { HotKeyCenter.shared.unregister(id) }
            commandShortcutIDs = []
        }
    }

    // MARK: - Menú

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Theme.menuBarIcon()
        statusItem.button?.toolTip = "Lince"

        let menu = NSMenu()
        menu.delegate = self

        func add(_ title: String, _ symbol: String, _ action: Selector?, key: String = "",
                 to target: NSMenu) -> NSMenuItem {
            let item = target.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .shift] }
            return item
        }

        areaItem = add("Capturar área", "rectangle.dashed", #selector(captureArea), key: "4", to: menu)
        _ = add("Capturar ventana", "macwindow", #selector(captureWindowMode), to: menu)
        fullItem = add("Capturar pantalla completa", "display", #selector(captureFullScreen), key: "3", to: menu)
        _ = add("Copiar texto de la pantalla", "text.viewfinder", #selector(captureText), key: "2", to: menu)
        repeatItem = add("Repetir última área", "arrow.clockwise", #selector(repeatLastArea), key: "5", to: menu)

        let timerItem = add("Capturar con temporizador", "timer", nil, to: menu)
        let timerMenu = NSMenu()
        for seconds in [3, 5, 10] {
            let item = add("\(seconds) segundos", "timer", #selector(captureWithTimer(_:)), to: timerMenu)
            item.tag = seconds
        }
        timerItem.submenu = timerMenu

        menu.addItem(.separator())
        _ = add("Historial de capturas…", "clock.arrow.circlepath", #selector(showHistory), to: menu)
        _ = add("Abrir carpeta de capturas", "folder", #selector(openSaveFolder), to: menu)
        menu.addItem(.separator())

        let settingsItem = add("Ajustes", "gearshape", nil, to: menu)
        let settings = NSMenu()
        settings.delegate = self
        overrideItem = add("Sustituir ⌘⇧3 y ⌘⇧4 de macOS", "command", #selector(toggleSystemOverride), to: settings)
        loginItem = add("Abrir al iniciar sesión", "power", #selector(toggleLoginItem), to: settings)
        settings.addItem(.separator())
        loupeItem = add("Lupa al seleccionar", "magnifyingglass", #selector(toggleLoupe), to: settings)
        iconsItem = add("Ocultar los iconos del escritorio", "eye.slash", #selector(toggleDesktopIcons), to: settings)
        shadowItem = add("Sombra en las capturas de ventana", "shadow", #selector(toggleWindowShadow), to: settings)
        settings.addItem(.separator())
        _ = add("Cambiar carpeta de guardado…", "folder.badge.gearshape", #selector(chooseSaveFolder), to: settings)
        settingsItem.submenu = settings

        _ = add("Atajos y permisos…", "keyboard", #selector(showWelcome), to: menu)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Salir de Lince", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // El menú enseña el atajo que de verdad funciona ahora mismo.
        syncSystemShortcuts()
        let native = SystemShortcuts.nativeScreenshotsEnabled
        let modifiers: NSEvent.ModifierFlags = native ? [.control, .shift] : [.command, .shift]
        areaItem.keyEquivalentModifierMask = modifiers
        fullItem.keyEquivalentModifierMask = modifiers
        repeatItem.isEnabled = Settings.lastArea != nil
        overrideItem.state = native ? .off : .on
        loupeItem.state = Settings.showsLoupe ? .on : .off
        iconsItem.state = Settings.hidesDesktopIcons ? .on : .off
        shadowItem.state = Settings.windowShadow ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== repeatItem || Settings.lastArea != nil
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(Settings.saveDirectory)
    }

    @objc private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveDirectory
        panel.prompt = "Elegir"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.saveDirectory = url
        }
    }

    @objc private func toggleSystemOverride() {
        // Si macOS los tiene activos se los quitamos; si ya son de Lince, se los devolvemos.
        let giveBack = !SystemShortcuts.nativeScreenshotsEnabled
        if !SystemShortcuts.setNativeScreenshots(enabled: giveBack) {
            WelcomeController.shared.show()
        }
        syncSystemShortcuts()
    }

    @objc private func toggleLoupe() { Settings.showsLoupe.toggle() }
    @objc private func toggleDesktopIcons() { Settings.hidesDesktopIcons.toggle() }
    @objc private func toggleWindowShadow() { Settings.windowShadow.toggle() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            thumbnailReport(error: error)
        }
    }

    @objc private func showWelcome() { WelcomeController.shared.show() }
    @objc private func showHistory() { HistoryController.shared.show() }

    // MARK: - Captura

    @objc func captureArea() { startSelection(.image) }
    @objc func captureWindowMode() { startSelection(.image, windowMode: true) }
    @objc func captureText() { startSelection(.text) }
    @objc private func captureWithTimer(_ sender: NSMenuItem) { startSelection(.timer(sender.tag)) }

    @objc func captureFullScreen() {
        guard beginCapture() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }
            do {
                if let shot = try await ScreenCapturer.capture(screens: [NSScreen.underMouse]).first {
                    self.present(shot, from: shot.screen.frame)
                }
            } catch {
                self.thumbnailReport(error: error)
            }
        }
    }

    @objc func repeatLastArea() {
        guard let rect = Settings.lastArea else {
            Toast.show("Aún no hay un área que repetir", symbol: "arrow.clockwise", on: NSScreen.underMouse)
            return
        }
        guard beginCapture() else { return }
        captureLive(rect)
    }

    private func beginCapture() -> Bool {
        guard !isCapturing, !selection.isActive else { return false }
        guard ScreenCapturer.hasPermission else {
            WelcomeController.shared.show()
            return false
        }
        isCapturing = true
        return true
    }

    private func startSelection(_ purpose: SelectionPurpose, windowMode: Bool = false) {
        guard beginCapture() else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // La pantalla se congela y la lista de ventanas se toma en el mismo instante.
                let shots = try await ScreenCapturer.capture(screens: NSScreen.screens)
                let windowList = ScreenCapturer.windowList()
                self.selection.begin(shots: shots, windowList: windowList, purpose: purpose,
                                     startInWindowMode: windowMode) { [weak self] result in
                    self?.handle(result, purpose: purpose)
                }
            } catch {
                self.isCapturing = false
                self.thumbnailReport(error: error)
            }
        }
    }

    private func handle(_ result: SelectionResult?, purpose: SelectionPurpose) {
        previousApp?.activate()
        previousApp = nil
        guard let result else {
            isCapturing = false
            return
        }
        switch (purpose, result) {
        case (.image, .area(let shot, let rect)):
            isCapturing = false
            Settings.lastArea = rect
            present(shot, from: rect)
        case (.image, .window(let info)):
            captureWindow(info)
        case (.text, .area(let shot, _)):
            isCapturing = false
            TextRecognizer.copyText(from: shot.image, on: shot.screen)
        case (.text, .window):
            isCapturing = false
        case (.timer(let seconds), .area(_, let rect)):
            Settings.lastArea = rect
            CountdownHUD.run(seconds: seconds, around: rect, on: NSScreen.containing(rect)) { [weak self] completed in
                if completed { self?.captureLive(rect) } else { self?.isCapturing = false }
            }
        case (.timer(let seconds), .window(let info)):
            CountdownHUD.run(seconds: seconds, around: info.frame,
                             on: NSScreen.containing(info.frame)) { [weak self] completed in
                if completed { self?.captureWindow(info) } else { self?.isCapturing = false }
            }
        }
    }

    /// Captura un rectángulo tal y como está la pantalla ahora mismo.
    private func captureLive(_ rect: CGRect) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }
            do {
                if let shot = try await ScreenCapturer.captureArea(rect, on: NSScreen.containing(rect)) {
                    self.present(shot, from: rect)
                }
            } catch {
                self.thumbnailReport(error: error)
            }
        }
    }

    private func captureWindow(_ info: WindowInfo) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false }
            do {
                guard var shot = try await ScreenCapturer.captureWindow(info) else {
                    Toast.show("No se ha podido capturar la ventana", symbol: "exclamationmark.triangle",
                               on: NSScreen.containing(info.frame))
                    return
                }
                if Settings.windowShadow,
                   let shadowed = Backdrop.addWindowShadow(to: shot.image, unit: shot.scale) {
                    shot = ScreenShot(image: shadowed, screen: shot.screen, scale: shot.scale)
                }
                self.present(shot, from: info.frame, hasTransparency: true)
            } catch {
                self.thumbnailReport(error: error)
            }
        }
    }

    private func present(_ shot: ScreenShot, from source: CGRect, hasTransparency: Bool = false) {
        playShutter()
        let capture = Capture(image: shot.image, scale: shot.scale)
        capture.sourceRect = source
        capture.hasTransparency = hasTransparency
        thumbnails.add(capture, on: shot.screen, from: source)
        HistoryStore.shared.save(capture)
    }

    /// Vuelve a sacar como miniatura una captura del historial.
    private func restore(_ entry: HistoryStore.Entry) {
        let screen = NSScreen.underMouse
        if thumbnails.controller(forID: entry.id) != nil {
            Toast.show("Esa captura ya está en pantalla", symbol: "rectangle.on.rectangle", on: screen)
            return
        }
        guard let image = HistoryStore.shared.image(for: entry.id) else {
            HistoryStore.shared.remove(entry.id)
            return
        }
        let capture = Capture(image: image, scale: CGFloat(entry.scale), id: entry.id)
        capture.hasTransparency = entry.hasTransparency
        thumbnails.add(capture, on: screen, from: nil)
    }

    private lazy var shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    private func playShutter() {
        shutterSound?.stop()
        shutterSound?.play()
    }

    // MARK: - Acciones de la miniatura

    func thumbnailEdit(_ capture: Capture) {
        if let existing = editors.first(where: { $0.capture === capture }) {
            existing.show()
            return
        }
        let editor = EditorController(capture: capture)
        editor.onUpdate = { [weak self] in
            self?.thumbnails.controller(for: capture)?.refreshImage()
            HistoryStore.shared.save(capture)
        }
        editor.onSaved = { [weak self] in
            self?.thumbnails.controller(for: capture)?.dismiss()
        }
        editor.onClose = { [weak self, weak editor] in
            // Se libera en el siguiente ciclo para no destruir la ventana mientras se cierra.
            DispatchQueue.main.async {
                self?.editors.removeAll { $0 === editor }
            }
        }
        editors.append(editor)
        editor.show()
    }

    func thumbnailPreview(_ capture: Capture) {
        let controller = thumbnails.controller(for: capture)
        guard let screen = controller?.panel.screen ?? controller?.screen ?? NSScreen.main else { return }
        let id = capture.id
        PreviewController.shared.toggle(capture, on: screen) { [weak self] in
            self?.thumbnails.controller(forID: id)?.imageFrameOnScreen
        }
    }

    func thumbnailReport(error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }
}
