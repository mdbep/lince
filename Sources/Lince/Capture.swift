import AppKit
import UniformTypeIdentifiers

enum Settings {
    private static let defaults = UserDefaults.standard

    static var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: "saveDirectory") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { defaults.set(newValue.path, forKey: "saveDirectory") }
    }

    static var showsLoupe: Bool {
        get { defaults.object(forKey: "showsLoupe") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showsLoupe") }
    }

    /// La selección se pega a los bordes de las ventanas.
    static var magnet: Bool {
        get { defaults.object(forKey: "magnet") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "magnet") }
    }

    static var shutterSound: ShutterSound {
        get { ShutterSound(rawValue: defaults.string(forKey: "shutterSound") ?? "") ?? .lince }
        set { defaults.set(newValue.rawValue, forKey: "shutterSound") }
    }

    static var didShowWelcome: Bool {
        get { defaults.bool(forKey: "didShowWelcome") }
        set { defaults.set(newValue, forKey: "didShowWelcome") }
    }

    static var hidesDesktopIcons: Bool {
        get { defaults.bool(forKey: "hidesDesktopIcons") }
        set { defaults.set(newValue, forKey: "hidesDesktopIcons") }
    }

    static var windowShadow: Bool {
        get { defaults.object(forKey: "windowShadow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "windowShadow") }
    }

    /// Última área capturada (coordenadas globales), para poder repetirla.
    static var lastArea: CGRect? {
        get {
            guard let text = defaults.string(forKey: "lastArea") else { return nil }
            let rect = NSRectFromString(text)
            return rect.width >= 1 && rect.height >= 1 ? rect : nil
        }
        set { defaults.set(newValue.map { NSStringFromRect($0) }, forKey: "lastArea") }
    }

    static var editorTool: Int {
        get { defaults.integer(forKey: "editorTool") }
        set { defaults.set(newValue, forKey: "editorTool") }
    }

    static var editorColor: Int {
        get { defaults.integer(forKey: "editorColor") }
        set { defaults.set(newValue, forKey: "editorColor") }
    }

    /// Últimos ajustes del fondo del editor (estilo, margen, esquinas y sombra).
    static var backdropOptions: BackdropChoice {
        get {
            var choice = BackdropChoice(style: 0)
            if let style = defaults.object(forKey: "backdropStyle") as? Int {
                // -1 recuerda que se usó el automático; sus colores se calculan con cada captura.
                if style == -1 { choice.auto = [] } else if Backdrop.styles.indices.contains(style) { choice.style = style }
            }
            if let padding = defaults.object(forKey: "backdropPadding") as? Double { choice.padding = CGFloat(padding) }
            if let radius = defaults.object(forKey: "backdropRadius") as? Double { choice.radius = CGFloat(radius) }
            if let shadow = defaults.object(forKey: "backdropShadow") as? Double { choice.shadow = CGFloat(shadow) }
            choice.padding = min(max(choice.padding, BackdropChoice.paddingRange.lowerBound),
                                 BackdropChoice.paddingRange.upperBound)
            choice.radius = min(max(choice.radius, BackdropChoice.radiusRange.lowerBound),
                                BackdropChoice.radiusRange.upperBound)
            choice.shadow = min(max(choice.shadow, 0), 1)
            return choice
        }
        set {
            defaults.set(newValue.auto != nil ? -1 : newValue.style, forKey: "backdropStyle")
            defaults.set(Double(newValue.padding), forKey: "backdropPadding")
            defaults.set(Double(newValue.radius), forKey: "backdropRadius")
            defaults.set(Double(newValue.shadow), forKey: "backdropShadow")
        }
    }

    static var editorWidth: Int {
        get { defaults.object(forKey: "editorWidth") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "editorWidth") }
    }
}

/// Estado de los atajos de captura nativos de macOS (solo lectura).
enum SystemShortcuts {
    /// 28 es ⌘⇧3 y 30 es ⌘⇧4 en las preferencias de atajos del sistema.
    private static func isEnabled(_ id: Int) -> Bool {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all["\(id)"] as? [String: Any],
              let enabled = entry["enabled"] as? Bool else { return true }
        return enabled
    }

    /// Mientras macOS los tenga activos, ⌘⇧3 y ⌘⇧4 no llegan a Lince.
    static var nativeScreenshotsEnabled: Bool { isEnabled(28) || isEnabled(30) }

    /// Activa o desactiva ⌘⇧3 y ⌘⇧4 de macOS, igual que hacerlo en Ajustes › Teclado.
    /// Devuelve `false` si el sistema no aceptó el cambio.
    @discardableResult
    static func setNativeScreenshots(enabled: Bool) -> Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        let key = "AppleSymbolicHotKeys" as CFString
        var all = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        // (carácter, tecla, modificadores) con los que macOS define cada atajo: ⌘⇧3 y ⌘⇧4.
        for (id, parameters) in [(28, [51, 20, 1_179_648]), (30, [52, 21, 1_179_648])] {
            var entry = (all["\(id)"] as? [String: Any]) ?? [:]
            entry["enabled"] = enabled
            if entry["value"] == nil {
                entry["value"] = ["type": "standard", "parameters": parameters] as [String: Any]
            }
            all["\(id)"] = entry
        }
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }

        // Hace que el sistema relea los atajos sin tener que cerrar sesión.
        let apply = Process()
        apply.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        apply.arguments = ["-u"]
        do {
            try apply.run()
            apply.waitUntilExit()
        } catch {
            return false
        }
        return nativeScreenshotsEnabled == enabled
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum ExportFormat: String, CaseIterable {
    case png, jpeg, heic

    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
}

/// Formato y tamaño con los que una captura se copia, se guarda o se arrastra.
struct ExportOptions: Equatable {
    var format: ExportFormat = .png
    /// Fracción del tamaño original (1, 0,5 o 0,25). Se ignora si hay `customWidth`.
    var scale: CGFloat = 1
    /// Ancho exacto en píxeles, si se eligió uno a medida.
    var customWidth: Int?

    func pixelSize(for image: CGImage) -> (width: Int, height: Int) {
        let width: Int
        if let customWidth {
            width = max(1, min(customWidth, image.width))
        } else {
            width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        }
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        return (width, height)
    }

    /// La última elección se recuerda para las siguientes capturas.
    static var saved: ExportOptions {
        get {
            let defaults = UserDefaults.standard
            var options = ExportOptions()
            if let raw = defaults.string(forKey: "exportFormat"), let format = ExportFormat(rawValue: raw) {
                options.format = format
            }
            let scale = defaults.double(forKey: "exportScale")
            if scale > 0, scale <= 1 { options.scale = scale }
            let width = defaults.integer(forKey: "exportWidth")
            if width > 0 { options.customWidth = width }
            return options
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.format.rawValue, forKey: "exportFormat")
            defaults.set(Double(newValue.scale), forKey: "exportScale")
            defaults.set(newValue.customWidth ?? 0, forKey: "exportWidth")
        }
    }
}

/// Una captura en memoria. El archivo exportado se genera una sola vez por configuración y se reutiliza.
final class Capture {
    private(set) var image: CGImage
    /// Píxeles por punto de la pantalla de origen.
    let scale: CGFloat
    let date = Date()
    /// Identifica la captura en el historial.
    let id: String
    /// De dónde se tomó, en coordenadas globales de pantalla.
    var sourceRect: CGRect?
    /// La imagen tiene zonas transparentes (una ventana con sus esquinas y su sombra).
    var hasTransparency = false

    var export: ExportOptions {
        didSet {
            guard export != oldValue else { return }
            ExportOptions.saved = export
            invalidate()
            prewarm()
        }
    }

    private let lock = NSLock()
    private var cachedData: Data?
    private var cachedImage: CGImage?
    private var tempURL: URL?

    init(image: CGImage, scale: CGFloat, export: ExportOptions = .saved, id: String = UUID().uuidString) {
        self.id = id
        self.image = image
        self.scale = max(scale, 1)
        self.export = export
        prewarm()
    }

    /// Se codifica en segundo plano para que arrastrar o previsualizar sea inmediato.
    private func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.temporaryFileURL()
        }
    }

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    /// Tamaño en píxeles con el que saldrá la captura.
    var exportPixelSize: (width: Int, height: Int) { export.pixelSize(for: image) }

    var fileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        return "Lince \(formatter.string(from: date)).\(export.format.fileExtension)"
    }

    func update(image newImage: CGImage) {
        lock.lock()
        image = newImage
        lock.unlock()
        invalidate()
        prewarm()
    }

    private func invalidate() {
        lock.lock()
        cachedData = nil
        cachedImage = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        tempURL = nil
        lock.unlock()
    }

    /// Los datos de la captura en el formato y tamaño elegidos.
    func exportedData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return exportedDataLocked()
    }

    private func exportedDataLocked() -> Data? {
        if let cachedData { return cachedData }
        let options = export
        let size = options.pixelSize(for: image)
        let output = size.width == image.width ? image : (Capture.resized(image, width: size.width, height: size.height) ?? image)
        // Los puntos por pulgada se ajustan para que la imagen conserve su tamaño aparente.
        let effectiveScale = max(1, scale * CGFloat(output.width) / CGFloat(image.width))
        cachedImage = output
        cachedData = Capture.encode(output, format: options.format, scale: effectiveScale)
        return cachedData
    }

    /// Archivo temporal usado para arrastrar y para Vista Rápida.
    func temporaryFileURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let tempURL { return tempURL }
        guard let data = exportedDataLocked() else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lince", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            tempURL = url
            return url
        } catch {
            return nil
        }
    }

    func copyToPasteboard() {
        lock.lock()
        let data = exportedDataLocked()
        let output = cachedImage ?? image
        let format = export.format
        lock.unlock()
        Capture.copy(image: output, data: data, type: format.type)
    }

    @discardableResult
    func saveToDefaultFolder() throws -> URL {
        guard let data = exportedData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = Settings.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (fileName as NSString).deletingPathExtension
            url = dir.appendingPathComponent("\(base) (\(counter)).\(export.format.fileExtension)")
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    func cleanUp() {
        invalidate()
    }

    // MARK: - Utilidades

    static func copy(image: CGImage, png: Data?) {
        copy(image: image, data: png, type: .png)
    }

    static func copy(image: CGImage, data: Data?, type: UTType) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let data { item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier)) }
        // El TIFF (muy pesado) solo se genera si la app de destino lo pide.
        let provider = LazyTIFFProvider(image: image)
        LazyTIFFProvider.current = provider
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.writeObjects([item])
    }

    static func encodePNG(_ image: CGImage, scale: CGFloat) -> Data? {
        encode(image, format: .png, scale: scale)
    }

    static func encode(_ image: CGImage, format: ExportFormat, scale: CGFloat) -> Data? {
        // JPG y HEIC no guardan transparencia: se rellena de blanco para que no salga negra.
        var image = image
        if format != .png, ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.draw(image, in: rect)
            image = context.makeImage() ?? image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72.0 * scale
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.85
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    /// El portapapeles no retiene a su proveedor, así que se mantiene vivo el último.
    static var current: LazyTIFFProvider?
    private let image: CGImage

    init(image: CGImage) { self.image = image }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .tiff, properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)]) {
            item.setData(data, forType: .tiff)
        }
    }
}
