import AppKit
import ImageIO

/// Guarda en disco las últimas capturas para poder recuperarlas.
final class HistoryStore {
    static let shared = HistoryStore()
    static let limit = 30

    struct Entry: Codable, Equatable {
        let id: String
        var date: Date
        var width: Int
        var height: Int
        var scale: Double
        var hasTransparency: Bool
    }

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    private let directory: URL
    private let queue = DispatchQueue(label: "lince.history", qos: .utility)
    private let thumbnails = NSCache<NSString, CGImage>()

    private init() {
        if let override = ProcessInfo.processInfo.environment["LINCE_HISTORY_DIR"] {
            // Las pruebas internas usan una carpeta aparte para no tocar el historial real.
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("Lince/History", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved.filter { FileManager.default.fileExists(atPath: fileURL(for: $0.id).path) }
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    func fileURL(for id: String) -> URL { directory.appendingPathComponent("\(id).png") }

    /// Añade la captura (o la actualiza si ya estaba, por ejemplo tras editarla).
    func save(_ capture: Capture) {
        let entry = Entry(id: capture.id, date: capture.date, width: capture.image.width,
                          height: capture.image.height, scale: Double(capture.scale),
                          hasTransparency: capture.hasTransparency)
        let image = capture.image
        let url = fileURL(for: entry.id)
        thumbnails.removeObject(forKey: entry.id as NSString)
        // Codificar el PNG es lo caro: se hace fuera del hilo principal y con prioridad baja.
        queue.async { [weak self] in
            guard let data = Capture.encodePNG(image, scale: CGFloat(entry.scale)),
                  (try? data.write(to: url, options: .atomic)) != nil else { return }
            DispatchQueue.main.async { self?.insert(entry) }
        }
    }

    private func insert(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        while entries.count > HistoryStore.limit {
            let removed = entries.removeLast()
            deleteFile(removed.id)
        }
        persist()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        deleteFile(id)
        persist()
    }

    func clear() {
        for entry in entries { deleteFile(entry.id) }
        entries.removeAll()
        persist()
    }

    private func deleteFile(_ id: String) {
        thumbnails.removeObject(forKey: id as NSString)
        let url = fileURL(for: id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    private func persist() {
        let snapshot = entries
        let url = indexURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        onChange?()
    }

    /// Imagen completa, para restaurar la captura.
    func image(for id: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL(for: id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Miniatura reducida, decodificada en segundo plano y guardada en caché.
    func thumbnail(for id: String, completion: @escaping (CGImage?) -> Void) {
        if let cached = thumbnails.object(forKey: id as NSString) {
            completion(cached)
            return
        }
        let url = fileURL(for: id)
        queue.async { [weak self] in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 520,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            var image: CGImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            if let image { self?.thumbnails.setObject(image, forKey: id as NSString) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - Ventana

final class HistoryController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let shared = HistoryController()
    /// Recupera una captura como miniatura flotante.
    var onRestore: ((HistoryStore.Entry) -> Void)?

    private(set) var window: NSWindow?
    private var collection: NSCollectionView!
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyState = NSStackView()
    private var clearButton: HoverButton!

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func build() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Historial de capturas"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.canvas
        window.minSize = CGSize(width: 520, height: 360)
        window.center()

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.canvas.cgColor

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.chrome.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)

        let title = NSTextField(labelWithString: "Historial")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.9)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        let titles = NSStackView(views: [title, countLabel])
        titles.spacing = 8
        titles.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(titles)

        clearButton = HoverButton(symbol: "trash", title: "Vaciar", symbolSize: 11, tooltip: "Borrar todo el historial")
        clearButton.normalColor = NSColor.white.withAlphaComponent(0.08)
        clearButton.hoverColor = NSColor.white.withAlphaComponent(0.15)
        clearButton.onClick = { [weak self] in self?.confirmClear() }
        bar.addSubview(clearButton)

        // La rejilla reparte las columnas a lo ancho y estira las celdas para que no queden huecos.
        let layout = NSCollectionViewGridLayout()
        layout.minimumItemSize = NSSize(width: 200, height: 176)
        layout.maximumItemSize = NSSize(width: 300, height: 186)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.margins = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.register(HistoryItem.self, forItemWithIdentifier: HistoryItem.identifier)
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView()
        emptyIcon.image = Theme.symbol("clock.arrow.circlepath", size: 34, weight: .regular)
        emptyIcon.contentTintColor = NSColor.white.withAlphaComponent(0.25)
        let emptyTitle = NSTextField(labelWithString: "Aún no hay capturas")
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = NSColor.white.withAlphaComponent(0.7)
        let emptyDetail = NSTextField(labelWithString: "Las últimas \(HistoryStore.limit) capturas aparecerán aquí.")
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = NSColor.white.withAlphaComponent(0.4)
        emptyState.orientation = .vertical
        emptyState.spacing = 8
        emptyState.setViews([emptyIcon, emptyTitle, emptyDetail], in: .center)
        emptyState.setCustomSpacing(14, after: emptyIcon)
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(emptyState)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            titles.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titles.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 20),
        ])
        window.contentView = root
        self.window = window
        HistoryStore.shared.onChange = { [weak self] in self?.reload() }
    }

    func reload() {
        guard window != nil else { return }
        let count = HistoryStore.shared.entries.count
        countLabel.stringValue = count == 1 ? "1 captura" : "\(count) capturas"
        emptyState.isHidden = count > 0
        clearButton.isHidden = count == 0
        collection.reloadData()
    }

    private func confirmClear() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "¿Vaciar el historial?"
        alert.informativeText = "Se borrarán las capturas guardadas en el historial. Las que hayas guardado en tu carpeta no se tocan."
        alert.addButton(withTitle: "Vaciar")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { HistoryStore.shared.clear() }
        }
    }

    // MARK: Datos

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        HistoryStore.shared.entries.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: HistoryItem.identifier, for: indexPath)
        let entries = HistoryStore.shared.entries
        guard let cell = item.view as? HistoryCell, indexPath.item < entries.count else { return item }
        let entry = entries[indexPath.item]
        cell.configure(with: entry)
        cell.onOpen = { [weak self] in self?.onRestore?(entry) }
        cell.onCopy = {
            guard let image = HistoryStore.shared.image(for: entry.id) else { return }
            Capture.copy(image: image, png: try? Data(contentsOf: HistoryStore.shared.fileURL(for: entry.id)))
        }
        cell.onDelete = { HistoryStore.shared.remove(entry.id) }
        return item
    }
}

final class HistoryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryItem")
    override func loadView() { view = HistoryCell(frame: CGRect(x: 0, y: 0, width: 224, height: 178)) }
}

final class HistoryCell: NSView {
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    private let card = NSView()
    private let imageLayer = CALayer()
    private let controls = PassthroughView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var copyButton: HoverButton!
    private var entryID = ""

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.unitsStyle = .full
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.hairline.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        card.layer?.addSublayer(imageLayer)
        addSubview(card)

        controls.alphaValue = 0
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        controls.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(controls)

        copyButton = makeButton("doc.on.doc", tooltip: "Copiar") { [weak self] in
            self?.onCopy?()
            self?.copyButton.setSymbol("checkmark", size: 10.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                self?.copyButton.setSymbol("doc.on.doc", size: 10.5)
            }
        }
        let delete = makeButton("trash", tooltip: "Quitar del historial") { [weak self] in self?.onDelete?() }
        controls.addSubview(copyButton)
        controls.addSubview(delete)

        let open = HoverButton(title: "Recuperar", fontSize: 12, size: CGSize(width: 96, height: 27))
        open.cornerRadius = nil
        open.normalColor = NSColor.white.withAlphaComponent(0.92)
        open.hoverColor = .white
        open.normalTint = NSColor.black.withAlphaComponent(0.85)
        open.hoverTint = .black
        open.onClick = { [weak self] in self?.onOpen?() }
        controls.addSubview(open)

        dateLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(dateLabel)
        addSubview(sizeLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            dateLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            controls.topAnchor.constraint(equalTo: card.topAnchor),
            controls.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            open.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            open.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -7),
            copyButton.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7),
            delete.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 7),
            delete.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7),
            dateLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            sizeLabel.centerYAnchor.constraint(equalTo: dateLabel.centerYAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            dateLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
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

    override func layout() {
        super.layout()
        withoutActions { imageLayer.frame = card.bounds.insetBy(dx: 8, dy: 8) }
    }

    func configure(with entry: HistoryStore.Entry) {
        entryID = entry.id
        controls.alphaValue = 0
        if Date().timeIntervalSince(entry.date) < 60 {
            dateLabel.stringValue = "Ahora mismo"
        } else {
            let relative = HistoryCell.formatter.localizedString(for: entry.date, relativeTo: Date())
            dateLabel.stringValue = relative.prefix(1).uppercased() + relative.dropFirst()
        }
        sizeLabel.stringValue = "\(entry.width) × \(entry.height)"
        withoutActions { imageLayer.contents = nil }
        HistoryStore.shared.thumbnail(for: entry.id) { [weak self] image in
            // La celda puede haberse reutilizado para otra captura mientras se decodificaba.
            guard let self, self.entryID == entry.id else { return }
            withoutActions { self.imageLayer.contents = image }
        }
    }

    func debugShowControls() { controls.alphaValue = 1 }

    override func mouseEntered(with event: NSEvent) { setControls(visible: true) }
    override func mouseExited(with event: NSEvent) { setControls(visible: false) }

    private func setControls(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onOpen?() }
    }
}
