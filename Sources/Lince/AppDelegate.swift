import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ThumbnailActions {
    private var statusItem: NSStatusItem!
    private var areaItem: NSMenuItem!
    private var fullItem: NSMenuItem!
    private var repeatItem: NSMenuItem!
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    private var shortcutIDs: [UInt32] = []
    private var shortcutsSuspended = false
    private let selection = SelectionController()
    private let thumbnails = ThumbnailManager()
    private let recorder = RecordingController()
    private var statusMenu: NSMenu!
    private var recordItem: NSMenuItem!
    /// Se pidió salir en plena grabación: se sale en cuanto el vídeo quede cerrado.
    private var quitsAfterRecording = false
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
        // Modo interno: graba unos segundos de una ventana de prueba propia y comprueba el resultado.
        if let index = CommandLine.arguments.firstIndex(of: "--record-selftest"),
           CommandLine.arguments.count > index + 1 {
            RecordingChecks.live(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            NSApp.terminate(nil)
            return
        }

        thumbnails.actions = self
        WelcomeController.shared.onShortcutsChanged = { [weak self] in self?.syncSystemShortcuts() }
        HistoryController.shared.onRestore = { [weak self] entry in self?.restore(entry) }
        buildStatusItem()
        recorder.onStatus = { [weak self] in
            guard let self else { return }
            self.updateRecordingStatus()
            if self.quitsAfterRecording, !self.recorder.isActive {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        recorder.onError = { [weak self] in self?.thumbnailReport(error: $0) }
        recorder.onFinish = { [weak self] capture, screen, rect in
            self?.statusItem.blink()
            self?.thumbnails.add(capture, on: screen, from: rect)
        }
        RecordingStore.purge()

        SettingsController.shared.onSystemShortcutsChanged = { [weak self] in self?.syncSystemShortcuts() }
        SettingsController.shared.onError = { [weak self] in self?.thumbnailReport(error: $0) }
        CommandPaletteController.shared.commands = { [weak self] in self?.commands() ?? [] }
        ShortcutStore.onChange = { [weak self] in
            self?.registerShortcuts()
            WelcomeController.shared.refresh()
        }
        ShortcutStore.onRecording = { [weak self] recording in
            self?.shortcutsSuspended = recording
            self?.registerShortcuts()
            self?.syncSystemShortcuts()
        }
        registerShortcuts()
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

    /// Salir mientras se graba dejaría un vídeo a medias e ilegible: antes se detiene y se guarda.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }
        quitsAfterRecording = true
        recorder.stop()
        return .terminateLater
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .area: captureArea()
        case .window: captureWindowMode()
        case .fullScreen: captureFullScreen()
        case .text: captureText()
        case .repeatArea: repeatLastArea()
        case .record: toggleRecording()
        case .palette: CommandPaletteController.shared.toggle()
        }
    }

    /// Registra los atajos elegidos en Ajustes; mientras se graba uno nuevo, no hay ninguno activo.
    private func registerShortcuts() {
        for id in shortcutIDs { HotKeyCenter.shared.unregister(id) }
        shortcutIDs = []
        guard !shortcutsSuspended else { return }
        for action in ShortcutAction.allCases {
            guard let shortcut = ShortcutStore.shortcut(for: action) else { continue }
            let id = HotKeyCenter.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                self?.perform(action)
            }
            if let id { shortcutIDs.append(id) }
        }
    }

    /// Registra o suelta ⌘⇧3/4 según estén o no activos los atajos nativos de macOS.
    private func syncSystemShortcuts() {
        let shouldOwn = !SystemShortcuts.nativeScreenshotsEnabled && !shortcutsSuspended
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

        func add(_ title: String, _ symbol: String, _ action: Selector?, to target: NSMenu,
                 shortcut: ShortcutAction? = nil) -> NSMenuItem {
            let item = target.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let shortcut { shortcutItems[shortcut] = item }
            return item
        }

        areaItem = add("Capturar área", "rectangle.dashed", #selector(captureArea), to: menu, shortcut: .area)
        _ = add("Capturar ventana", "macwindow", #selector(captureWindowMode), to: menu, shortcut: .window)
        fullItem = add("Capturar pantalla completa", "display", #selector(captureFullScreen), to: menu,
                       shortcut: .fullScreen)
        _ = add("Copiar texto de la pantalla", "text.viewfinder", #selector(captureText), to: menu, shortcut: .text)
        repeatItem = add("Repetir última área", "arrow.clockwise", #selector(repeatLastArea), to: menu,
                         shortcut: .repeatArea)

        let timerItem = add("Capturar con temporizador", "timer", nil, to: menu)
        let timerMenu = NSMenu()
        for seconds in [3, 5, 10] {
            let item = add("\(seconds) segundos", "timer", #selector(captureWithTimer(_:)), to: timerMenu)
            item.tag = seconds
        }
        timerItem.submenu = timerMenu

        menu.addItem(.separator())
        recordItem = add("Grabar la pantalla…", "record.circle", #selector(toggleRecording), to: menu, shortcut: .record)
        menu.addItem(.separator())
        _ = add("Paleta de comandos…", "command", #selector(showPalette), to: menu, shortcut: .palette)
        _ = add("Historial de capturas…", "clock.arrow.circlepath", #selector(showHistory), to: menu)
        _ = add("Abrir carpeta de capturas", "folder", #selector(openSaveFolder), to: menu)
        menu.addItem(.separator())
        let settings = add("Ajustes…", "gearshape", #selector(showSettings), to: menu)
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        _ = add("Permisos y bienvenida…", "hand.raised", #selector(showWelcome), to: menu)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Salir de Lince", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        statusItem.menu = menu
        statusMenu = menu
    }

    /// Mientras se graba, el icono de la barra de menús es un botón de parar con el tiempo al lado.
    private func updateRecordingStatus() {
        guard let button = statusItem.button else { return }
        let recording = recorder.isRecording || recorder.phase == .finishing
        if recording {
            if statusItem.menu != nil {
                statusItem.menu = nil
                statusItem.length = NSStatusItem.variableLength
                button.image = Theme.symbol("stop.circle.fill", size: 14, weight: .semibold)
                button.image?.isTemplate = true
                button.contentTintColor = RecordingStyle.red
                button.imagePosition = .imageLeading
                button.target = self
                button.action = #selector(stopRecording)
                button.toolTip = "Detener la grabación"
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.attributedTitle = NSAttributedString(string: " \(recorder.elapsedText)", attributes: [.font: font])
        } else if statusItem.menu == nil {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = Theme.menuBarIcon()
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.action = nil
            button.toolTip = "Lince"
            statusItem.length = NSStatusItem.squareLength
            statusItem.menu = statusMenu
        }
    }

    @objc private func stopRecording() { recorder.stop() }

    /// El mismo atajo empieza y detiene; si aún se estaban eligiendo las opciones, las cierra.
    @objc func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else if recorder.isActive {
            recorder.cancel()
        } else {
            startSelection(.record)
        }
    }

    private func recordWindow() {
        guard !recorder.isActive else { return }
        startSelection(.record, windowMode: true)
    }

    private func recordFullScreen() {
        guard !recorder.isActive, !selection.isActive else { return }
        guard ScreenCapturer.hasPermission else {
            WelcomeController.shared.show()
            return
        }
        recorder.begin(.screen(NSScreen.underMouse))
    }

    /// Vuelve a sacar como miniatura la última grabación, aunque se hubiera cerrado.
    private func restoreLastRecording() {
        let screen = NSScreen.underMouse
        guard let url = RecordingStore.latest else {
            Toast.show("No hay grabaciones recientes", symbol: "film", on: screen)
            return
        }
        guard !thumbnails.showsRecording(at: url) else {
            Toast.show("Esa grabación ya está en pantalla", symbol: "rectangle.on.rectangle", on: screen)
            return
        }
        Task { @MainActor [weak self] in
            guard let loaded = await RecordingStore.load(url) else {
                Toast.show("No se ha podido abrir la grabación", symbol: "exclamationmark.triangle", on: screen)
                return
            }
            self?.thumbnails.add(Capture(recording: loaded.recording, poster: loaded.poster), on: screen, from: nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // El menú enseña los atajos que de verdad funcionan ahora mismo.
        syncSystemShortcuts()
        for (action, item) in shortcutItems {
            let shortcut = ShortcutStore.shortcut(for: action)
            item.keyEquivalent = shortcut?.menuKey ?? ""
            item.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
        }
        if !SystemShortcuts.nativeScreenshotsEnabled {
            // Con los de macOS sustituidos, se muestran ⌘⇧4 y ⌘⇧3, que son los que la gente recuerda.
            for (item, key) in [(areaItem, "4"), (fullItem, "3")] {
                item?.keyEquivalent = key
                item?.keyEquivalentModifierMask = [.command, .shift]
            }
        }
        repeatItem.isEnabled = Settings.lastArea != nil
        recordItem.title = recorder.isActive ? "Cancelar la grabación" : "Grabar la pantalla…"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== repeatItem || Settings.lastArea != nil
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(Settings.saveDirectory)
    }

    @objc private func showSettings() { SettingsController.shared.show() }
    @objc private func showPalette() { CommandPaletteController.shared.show() }

    // MARK: - Paleta de comandos

    /// Todas las acciones de Lince, con el atajo que tengan ahora mismo.
    private func commands() -> [Command] {
        func keys(_ action: ShortcutAction) -> [String] { ShortcutStore.shortcut(for: action)?.keys ?? [] }
        var list = [
            Command(title: "Capturar área", symbol: "rectangle.dashed", keywords: "seleccion recorte zona",
                    keys: keys(.area)) { [weak self] in self?.captureArea() },
            Command(title: "Capturar ventana", symbol: "macwindow", keywords: "app aplicacion",
                    keys: keys(.window)) { [weak self] in self?.captureWindowMode() },
            Command(title: "Capturar pantalla completa", symbol: "display", keywords: "entera monitor todo",
                    keys: keys(.fullScreen)) { [weak self] in self?.captureFullScreen() },
            Command(title: "Copiar texto de la pantalla", symbol: "text.viewfinder", keywords: "ocr leer reconocer",
                    keys: keys(.text)) { [weak self] in self?.captureText() },
        ]
        if recorder.isRecording {
            list.insert(Command(title: "Detener la grabación", symbol: "stop.circle", keywords: "parar terminar video",
                                keys: keys(.record)) { [weak self] in self?.recorder.stop() }, at: 0)
        } else if !recorder.isActive {
            list += [
                Command(title: "Grabar la pantalla", symbol: "record.circle", keywords: "video gif area zona grabacion",
                        keys: keys(.record)) { [weak self] in self?.toggleRecording() },
                Command(title: "Grabar una ventana", symbol: "macwindow.badge.plus", keywords: "video gif app grabacion") {
                    [weak self] in self?.recordWindow()
                },
                Command(title: "Grabar la pantalla completa", symbol: "display", keywords: "video gif entera monitor grabacion") {
                    [weak self] in self?.recordFullScreen()
                },
            ]
        }
        if RecordingStore.latest != nil {
            list.append(Command(title: "Recuperar la última grabación", symbol: "film", keywords: "video gif volver reciente") {
                [weak self] in self?.restoreLastRecording()
            })
        }
        if Settings.lastArea != nil {
            list.append(Command(title: "Repetir última área", symbol: "arrow.clockwise", keywords: "otra vez misma",
                                keys: keys(.repeatArea)) { [weak self] in self?.repeatLastArea() })
        }
        for seconds in [3, 5, 10] {
            list.append(Command(title: "Capturar en \(seconds) segundos", symbol: "timer",
                                keywords: "temporizador cuenta atras retardo") { [weak self] in
                self?.startSelection(.timer(seconds))
            })
        }
        if let last = HistoryStore.shared.entries.first {
            list.append(Command(title: "Copiar la última captura", symbol: "doc.on.doc",
                                keywords: "portapapeles reciente") {
                guard let image = HistoryStore.shared.image(for: last.id) else { return }
                Capture.copy(image: image, png: Capture.encodePNG(image, scale: CGFloat(last.scale)))
                Toast.show("Copiada", symbol: "checkmark", on: NSScreen.underMouse)
            })
            list.append(Command(title: "Recuperar la última captura", symbol: "arrow.uturn.backward",
                                keywords: "miniatura volver reciente") { [weak self] in self?.restore(last) })
        }
        list += [
            Command(title: "Historial de capturas", symbol: "clock.arrow.circlepath", keywords: "anteriores recientes") {
                HistoryController.shared.show()
            },
            Command(title: "Abrir carpeta de capturas", symbol: "folder", keywords: "finder guardadas archivos") {
                NSWorkspace.shared.open(Settings.saveDirectory)
            },
            Command(title: "Cerrar todas las miniaturas", symbol: "xmark.circle", keywords: "limpiar bandeja descartar") {
                [weak self] in self?.thumbnails.dismissAll()
            },
            Command(title: "Ajustes", symbol: "gearshape", keywords: "preferencias opciones configuracion") {
                SettingsController.shared.show()
            },
            Command(title: "Cambiar atajos de teclado", symbol: "keyboard", keywords: "teclas combinacion") {
                SettingsController.shared.show(tab: SettingsController.shortcutsTab)
            },
            Command(title: "Permisos y bienvenida", symbol: "hand.raised", keywords: "grabacion pantalla ayuda") {
                WelcomeController.shared.show()
            },
            Command(title: "Salir de Lince", symbol: "power", keywords: "cerrar terminar") { NSApp.terminate(nil) },
        ]
        return list
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
        if purpose.isRecording, recorder.isActive { return }
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
        case (.record, .area(_, let rect)):
            isCapturing = false
            recorder.begin(.area(rect, NSScreen.containing(rect)))
        case (.record, .window(let info)):
            isCapturing = false
            recorder.begin(.window(info))
        case (.record, .screen(let screen)):
            isCapturing = false
            recorder.begin(.screen(screen))
        case (_, .screen):
            isCapturing = false
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
        Shutter.play()
        statusItem.blink()
        let capture = Capture(image: shot.image, scale: shot.scale)
        capture.sourceRect = source
        capture.hasTransparency = hasTransparency
        thumbnails.add(capture, on: shot.screen, from: source)
        HistoryStore.shared.save(capture)
        if Settings.copiesOnCapture { capture.copyWhenEncoded() }
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

    // MARK: - Acciones de la miniatura

    func thumbnailEdit(_ capture: Capture) {
        guard capture.recording == nil else { return }
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
