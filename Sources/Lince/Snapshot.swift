import AppKit

/// Modo interno (`Lince --snapshot <carpeta>`): renderiza cada pantalla con una imagen de prueba
/// para poder revisar el diseño sin capturar la pantalla real.
enum Snapshot {
    static func run(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = testImage(width: 1600, height: 1000)
        let pointSize = CGSize(width: 800, height: 500)

        // Miniatura, en reposo y con el ratón encima.
        for hovering in [false, true] {
            let size = ThumbnailController.thumbnailSize(for: pointSize)
            let view = ThumbnailView(frame: CGRect(origin: .zero, size: size))
            let window = host(view, size: size)
            view.setImage(image, pointSize: pointSize)
            view.debugSetChip("HEIC · 5120×2880 · 12,4 MB")
            view.debugSetHover(hovering)
            write(view, to: directory.appendingPathComponent(hovering ? "thumbnail-hover.png" : "thumbnail.png"))
            _ = window
        }

        // Exportación: cada formato y tamaño, con sus medidas y peso reales.
        var report = ""
        for format in ExportFormat.allCases {
            for scale in [1.0, 0.5, 0.25] {
                let capture = Capture(image: image, scale: 2, export: ExportOptions(format: format, scale: scale))
                let size = capture.exportPixelSize
                let data = capture.exportedData()
                var decoded = "no se pudo leer"
                if let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let read = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    decoded = "\(read.width)x\(read.height) \(CGImageSourceGetType(source) as String? ?? "?")"
                }
                report += "\(format.label) x\(scale): esperado \(size.width)x\(size.height), leído \(decoded), "
                    + "\(data?.count ?? 0) bytes, archivo \(capture.temporaryFileURL()?.lastPathComponent ?? "-")\n"
                capture.cleanUp()
            }
        }
        let custom = Capture(image: image, scale: 2, export: ExportOptions(format: .jpeg, customWidth: 777))
        report += "JPG ancho 777: \(custom.exportPixelSize)\n"
        // Editor con una anotación de cada tipo.
        let editor = EditorController(capture: Capture(image: image, scale: 2))
        let annotations = editor.canvas.annotationView
        let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
        annotations.annotations = [
            Annotation(tool: .arrow, points: [CGPoint(x: 300, y: 250), CGPoint(x: 620, y: 520)], color: red, width: 8, unit: 2),
            Annotation(tool: .rectangle, points: [CGPoint(x: 700, y: 560), CGPoint(x: 1080, y: 800)], color: Theme.accent, width: 8, unit: 2),
            Annotation(tool: .ellipse, points: [CGPoint(x: 1150, y: 300), CGPoint(x: 1450, y: 520)], color: blue, width: 8, unit: 2),
            Annotation(tool: .highlighter, points: [CGPoint(x: 200, y: 820), CGPoint(x: 560, y: 820)], color: .systemYellow, width: 8, unit: 2),
            Annotation(tool: .text, points: [CGPoint(x: 200, y: 640)], color: .white, width: 0, unit: 2, text: "Texto de prueba", fontSize: 44),
            Annotation(tool: .counter, points: [CGPoint(x: 900, y: 300)], color: red, width: 8, unit: 2, text: "1"),
            Annotation(tool: .counter, points: [CGPoint(x: 1000, y: 300)], color: .white, width: 8, unit: 2, text: "2"),
            Annotation(tool: .pixelate, points: [CGPoint(x: 1150, y: 620), CGPoint(x: 1480, y: 860)], color: red, width: 8, unit: 2),
        ]
        annotations.debugSelect(1)
        editor.window.layoutIfNeeded()
        if let content = editor.window.contentView {
            write(content, to: directory.appendingPathComponent("editor.png"))
        }

        // Selección: antes de arrastrar y con un área marcada.
        if let screen = NSScreen.main {
            let size = CGSize(width: 1200, height: 750)
            let shot = ScreenShot(image: image, screen: screen, scale: 2)
            let fakeWindow = WindowInfo(id: 1, frame: .zero, appName: "Safari")
            let view = SelectionView(shot: shot, windowList: [fakeWindow], purpose: .image, showsHint: true)
            let window = host(view, size: size)
            view.debugSet(selection: .zero, cursor: CGPoint(x: 420, y: 380))
            write(view, to: directory.appendingPathComponent("selection-idle.png"))
            view.debugSet(selection: CGRect(x: 260, y: 220, width: 520, height: 330), cursor: CGPoint(x: 780, y: 220))
            write(view, to: directory.appendingPathComponent("selection-drag.png"))
            // Modo ventana: una ventana resaltada bajo el cursor.
            if let hostFrame = view.window?.frame {
                let info = WindowInfo(id: 1, frame: CGRect(x: hostFrame.minX + 135, y: hostFrame.minY + 113,
                                                           width: 930, height: 524), appName: "Safari")
                view.debugSetWindowMode(hovering: info, cursor: CGPoint(x: 600, y: 400))
                write(view, to: directory.appendingPathComponent("selection-window.png"))
            }
            _ = window
        }

        // Fondo: el editor con un degradado y la imagen final que se exporta.
        let backdropEditor = EditorController(capture: Capture(image: image, scale: 2))
        let composed = backdropEditor.debugSetBackdrop(BackdropChoice(style: 1, padding: 1))
        backdropEditor.window.layoutIfNeeded()
        if let content = backdropEditor.window.contentView {
            write(content, to: directory.appendingPathComponent("editor-backdrop.png"))
        }
        if let composed, let data = Capture.encodePNG(composed, scale: 2) {
            try? data.write(to: directory.appendingPathComponent("backdrop-output.png"))
            report += "Fondo: \(image.width)x\(image.height) -> \(composed.width)x\(composed.height)\n"
        }

        // Sombra de ventana: una "ventana" con esquinas transparentes, con sombra y sobre un fondo.
        let windowImage = roundedWindow(width: 900, height: 600)
        if let shadowed = Backdrop.addWindowShadow(to: windowImage, unit: 2) {
            report += "Sombra de ventana: \(windowImage.width)x\(windowImage.height) -> \(shadowed.width)x\(shadowed.height)\n"
            if let onBackdrop = Backdrop.compose(shadowed, choice: BackdropChoice(style: 2, padding: 0), unit: 2,
                                                 hasTransparency: true),
               let data = Capture.encodePNG(onBackdrop, scale: 2) {
                try? data.write(to: directory.appendingPathComponent("window-shadow.png"))
            }
            // Un JPG no puede ser transparente: las esquinas deben salir blancas, no negras.
            if let jpeg = Capture.encode(shadowed, format: .jpeg, scale: 2),
               let rep = NSBitmapImageRep(data: jpeg), let corner = rep.colorAt(x: 2, y: 2) {
                report += String(format: "Esquina del JPG de una ventana: r=%.2f g=%.2f b=%.2f\n",
                                 corner.redComponent, corner.greenComponent, corner.blueComponent)
            }
        }

        // OCR sobre un texto conocido.
        let textImage = textSample()
        var recognized: String?
        TextRecognizer.recognize(textImage) { recognized = $0 }
        spin(until: { recognized != nil }, timeout: 15)
        report += "OCR: \(recognized?.replacingOccurrences(of: "\n", with: " | ") ?? "sin respuesta")\n"

        // Recorte de un área en coordenadas globales.
        if let screen = NSScreen.main {
            let full = ScreenShot(image: testImage(width: Int(screen.frame.width) * 2, height: Int(screen.frame.height) * 2),
                                  screen: screen, scale: 2)
            let rect = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 50, width: 300, height: 200)
            if let piece = ScreenCapturer.crop(full, to: rect) {
                report += "Recorte de 300x200 pt a 2x: \(piece.image.width)x\(piece.image.height)\n"
            }
        }

        // Historial: guardar, listar, recuperar y purgar.
        let store = HistoryStore.shared
        store.clear()
        for index in 0..<4 {
            let capture = Capture(image: index == 1 ? windowImage : image, scale: 2)
            store.save(capture)
        }
        spin(until: { store.entries.count == 4 }, timeout: 10)
        let firstID = store.entries.first?.id ?? ""
        let restored = store.image(for: firstID)
        report += "Historial: \(store.entries.count) entradas, recuperada \(restored.map { "\($0.width)x\($0.height)" } ?? "nada")\n"
        let history = HistoryController.shared
        history.build()
        history.reload()
        history.window?.layoutIfNeeded()
        spin(until: { false }, timeout: 1.2)
        if let content = history.window?.contentView {
            for cell in allSubviews(of: content).compactMap({ $0 as? HistoryCell }).prefix(1) { cell.debugShowControls() }
            write(content, to: directory.appendingPathComponent("history.png"))
        }
        store.remove(firstID)
        report += "Historial tras quitar una: \(store.entries.count) entradas\n"
        store.clear()
        spin(until: { false }, timeout: 0.3)

        // Captura fijada, cuenta atrás y aviso.
        let pinSize = CGSize(width: 400, height: 250)
        let pin = PinView(frame: CGRect(origin: .zero, size: pinSize), image: image)
        let pinWindow = host(pin, size: pinSize)
        pin.debugShowControls()
        write(pin, to: directory.appendingPathComponent("pin.png"))
        _ = pinWindow

        // Vista previa: una captura pequeña se amplía y una grande se ajusta a la pantalla.
        let previewArea = CGSize(width: 1440, height: 900)
        for (name, size) in [("pequeña", CGSize(width: 240, height: 120)), ("mediana", CGSize(width: 800, height: 500)),
                             ("grande", CGSize(width: 3000, height: 1600))] {
            let shown = PreviewController.displaySize(for: size, in: previewArea)
            report += "Vista previa \(name) \(Int(size.width))x\(Int(size.height)) -> \(Int(shown.width))x\(Int(shown.height))\n"
        }
        let previewSize = CGSize(width: 1280, height: 800)
        let previewView = PreviewView(frame: CGRect(origin: .zero, size: previewSize), image: image,
                                  pointSize: CGSize(width: 420, height: 260))
        let previewWindow = host(previewView, size: previewSize)
        previewView.debugShow()
        write(previewView, to: directory.appendingPathComponent("preview.png"))
        _ = previewWindow

        let countdown = CountdownView(frame: CGRect(origin: .zero, size: CountdownView.size), total: 5)
        let countdownWindow = host(countdown, size: CountdownView.size)
        countdown.show(3)
        write(countdown, to: directory.appendingPathComponent("countdown.png"))
        _ = countdownWindow

        let toast = Toast.makeContent("Texto copiado · 4 líneas", symbol: "checkmark")
        let toastWindow = host(toast, size: toast.fittingSize)
        write(toast, to: directory.appendingPathComponent("toast.png"))
        _ = toastWindow

        try? report.write(to: directory.appendingPathComponent("export.txt"), atomically: true, encoding: .utf8)

        // Bienvenida.
        let welcome = WelcomeController.shared
        welcome.build()
        welcome.refresh()
        welcome.window?.layoutIfNeeded()
        if let content = welcome.window?.contentView {
            write(content, to: directory.appendingPathComponent("welcome.png"))
        }

        // Icono de la barra de menús, ampliado.
        let icon = Theme.menuBarIcon()
        let preview = NSImage(size: NSSize(width: 144, height: 144), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            icon.draw(in: rect.insetBy(dx: 18, dy: 18))
            return true
        }
        if let tiff = preview.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("menubar-icon.png"))
        }
    }

    private static func spin(until done: () -> Bool, timeout: TimeInterval) {
        let limit = Date().addingTimeInterval(timeout)
        while !done(), Date() < limit {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    /// Una ventana inventada con esquinas redondeadas sobre fondo transparente.
    private static func roundedWindow(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.clip()
        context.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
        context.fill(rect)
        context.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: height - 76, width: width, height: 76))
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: 28 + index * 40, y: height - 50, width: 24, height: 24))
        }
        context.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor)
        for row in 0..<6 {
            context.fill(CGRect(x: 60, y: height - 160 - row * 60, width: [520, 700, 610, 760, 430, 660][row], height: 22))
        }
        return context.makeImage()!
    }

    /// Texto negro sobre blanco para comprobar el reconocimiento.
    private static func textSample() -> CGImage {
        let size = NSSize(width: 900, height: 260)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .medium),
                                                         .foregroundColor: NSColor.black]
        ("El lince ibérico caza al atardecer" as NSString).draw(at: NSPoint(x: 40, y: 150), withAttributes: attributes)
        ("Pedido 48213 · total 1.250,90 €" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static func host(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // Las vistas hechas solo de capas se renderizan desde la capa; el resto, por AppKit.
        if view is SelectionView, let layer = view.layer {
            let scale: CGFloat = 2
            let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            guard let image = context.makeImage(), let data = Capture.encodePNG(image, scale: scale) else { return }
            try? data.write(to: url)
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Un "escritorio" inventado: degradado, ventana y algo de texto simulado.
    static func testImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [NSColor(srgbRed: 0.16, green: 0.32, blue: 0.62, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.55, green: 0.3, blue: 0.62, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.95, green: 0.6, blue: 0.4, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

        let windowRect = CGRect(x: 180, y: 150, width: width - 360, height: height - 300)
        context.setShadow(offset: CGSize(width: 0, height: -20), blur: 60,
                          color: NSColor.black.withAlphaComponent(0.4).cgColor)
        context.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: windowRect, cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: windowRect.minX + 28 + CGFloat(index) * 40,
                                           y: windowRect.maxY - 52, width: 24, height: 24))
        }
        context.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        for row in 0..<9 {
            let lineWidth = CGFloat([620, 880, 760, 940, 540, 820, 700, 900, 480][row])
            context.fill(CGRect(x: windowRect.minX + 60, y: windowRect.maxY - 150 - CGFloat(row) * 56,
                                width: lineWidth, height: 22))
        }
        return context.makeImage()!
    }
}
