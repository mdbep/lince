import AppKit
import AVFoundation

/// Comprobaciones internas de la grabación: con datos sintéticos (`--snapshot`) y,
/// con `--record-selftest`, grabando de verdad una ventana de prueba propia.
enum RecordingChecks {
    private static func wait<T>(_ timeout: TimeInterval = 60, _ work: @escaping () async throws -> T) -> Result<T, Error> {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        Snapshot.spin(until: { result != nil }, timeout: timeout)
        return result ?? .failure(CocoaError(.userCancelled))
    }

    /// Fotograma de prueba: degradado fijo y un cuadrado blanco que avanza.
    private static func frame(width: Int, height: Int, step: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let square = CGRect(x: 20 + step * 12, y: height / 2 - 30, width: 60, height: 60)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                if square.contains(CGPoint(x: x, y: y)) {
                    p[0] = 255; p[1] = 255; p[2] = 255
                } else {
                    p[0] = UInt8(60 + 150 * y / height)
                    p[1] = UInt8(40 + 60 * x / width)
                    p[2] = UInt8(200 * x / width)
                }
                p[3] = 255
            }
        }
        return buffer
    }

    /// Un tramo de tono puro en PCM de 16 bits estéreo.
    private static func tone(_ frequency: Double, start: Int, frames: Int, base: CMTime) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Int16](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Int16(sin(2 * .pi * frequency * Double(start + index) / 48_000) * 9_000)
            samples[index * 2] = value
            samples[index * 2 + 1] = value
        }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        guard let block, let format else { return nil }
        CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: base + CMTime(value: CMTimeValue(start), timescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    private static func describe(_ url: URL) -> String {
        let asset = AVURLAsset(url: url)
        let result = wait {
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            let size = try await video.first?.load(.naturalSize) ?? .zero
            return "\(video.count) vídeo, \(audio.count) audio, \(Int(size.width))x\(Int(size.height)), "
                + String(format: "%.2f s", duration)
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        switch result {
        case .success(let text): return "\(text), \(bytes) bytes"
        case .failure(let error): return "ERROR \(error.localizedDescription)"
        }
    }

    /// Lee un GIF con ImageIO y lo compara con los fotogramas de origen.
    private static func describeGIF(_ url: URL, expecting size: (Int, Int)) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "ERROR no se puede leer" }
        let count = CGImageSourceGetCount(source)
        var delay = 0.0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delay += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
        }
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeOK = first?.width == size.0 && first?.height == size.1
        return "\(count) fotogramas, \(first?.width ?? 0)x\(first?.height ?? 0) (\(sizeOK ? "bien" : "MAL")), "
            + String(format: "%.2f s", delay) + ", \(bytes) bytes"
    }

    /// Error medio por canal entre una imagen y el fotograma de prueba de ese paso (0 = idénticos).
    private static func error(of image: CGImage, step: Int) -> Double {
        let width = image.width, height = image.height
        guard let reference = frame(width: width, height: height, step: step),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        CVPixelBufferLockBaseAddress(reference, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(reference, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(reference)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let rowBytes = CVPixelBufferGetBytesPerRow(reference)
        var total = 0
        for y in 0..<height {
            for x in 0..<width {
                let a = data + y * width * 4 + x * 4, b = base + y * rowBytes + x * 4
                total += abs(Int(a[0]) - Int(b[0])) + abs(Int(a[1]) - Int(b[1])) + abs(Int(a[2]) - Int(b[2]))
            }
        }
        return Double(total) / Double(width * height * 3)
    }

    static func run(to directory: URL) -> String {
        var report = "\n— Grabación —\n"
        let work = directory.appendingPathComponent("recording", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        for (points, native, retina) in [(CGSize(width: 1440, height: 900), 2.0, true),
                                         (CGSize(width: 2560, height: 1440), 2.0, true),
                                         (CGSize(width: 801, height: 455), 2.0, false)] {
            let size = ScreenRecorder.pixelSize(for: points, nativeScale: native, retina: retina)
            report += "Tamaño de \(Int(points.width))x\(Int(points.height)) @\(native) retina=\(retina): "
                + "\(size.width)x\(size.height)\n"
        }

        // Vídeo sintético: 45 fotogramas a 30 fps con un tono, en una línea de tiempo que no empieza en cero
        // y con medio segundo "en pausa" descontado, como en una grabación real.
        let width = 640, height = 400, fps = 30, frames = 45
        let movie = work.appendingPathComponent("Lince prueba.mp4")
        let base = CMTime(seconds: 5_000, preferredTimescale: 600)
        let paused = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let writer = try MovieWriter(url: movie, width: width, height: height, fps: fps, audio: true)
            var written = 0
            for step in 0..<frames {
                guard let buffer = frame(width: width, height: height, step: step) else { continue }
                let time = base + CMTime(value: CMTimeValue(step), timescale: CMTimeScale(fps))
                for _ in 0..<200 {
                    if writer.append(buffer, at: time - paused) { written += 1; break }
                    usleep(2_000)
                }
                // 1600 muestras de audio por fotograma.
                if let audio = tone(440, start: step * 1_600, frames: 1_600, base: base)?.shifted(back: paused) {
                    var tries = 0
                    while !writer.append(audio: audio), tries < 200 {
                        tries += 1
                        usleep(2_000)
                    }
                }
            }
            let end = base + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)) - paused
            let finished = wait { await writer.finish(at: end) }
            report += "Vídeo: \(written)/\(frames) fotogramas escritos, cierre \(finished), \(describe(movie))\n"
        } catch {
            report += "Vídeo: ERROR \(error.localizedDescription)\n"
        }

        // GIF a tamaño completo y a la mitad.
        for (name, size, gifFPS) in [("completo", (width, height), 15), ("mitad", (width / 2, height / 2), 10)] {
            let gif = work.appendingPathComponent("prueba-\(name).gif")
            let started = Date()
            let result = wait {
                try await GIFConverter.convert(movie: movie, to: gif, width: size.0, height: size.1, fps: gifFPS,
                                               progress: { _ in }, isCancelled: { false })
            }
            let elapsed = String(format: "%.2f s", Date().timeIntervalSince(started))
            switch result {
            case .success(let count):
                report += "GIF \(name) a \(gifFPS) fps: \(count) escritos en \(elapsed); leído: \(describeGIF(gif, expecting: size))\n"
            case .failure(let error):
                report += "GIF \(name): ERROR \(error)\n"
            }
        }
        // Fidelidad: el primer y el último fotograma del GIF frente a los de origen.
        if let source = CGImageSourceCreateWithURL(work.appendingPathComponent("prueba-completo.gif") as CFURL, nil) {
            let count = CGImageSourceGetCount(source)
            if count > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let last = CGImageSourceCreateImageAtIndex(source, count - 1, nil) {
                report += String(format: "GIF fidelidad (error medio por canal, 0-255): primero %.2f, último %.2f\n",
                                 error(of: first, step: 0), error(of: last, step: frames - 1))
                if let data = Capture.encodePNG(last, scale: 1) {
                    try? data.write(to: directory.appendingPathComponent("recording-gif-last.png"))
                }
            }
        }

        // Micrófono: una pista aparte que se mezcla con el audio del vídeo en una sola.
        do {
            let voiceURL = work.appendingPathComponent("Lince prueba.mic.m4a")
            let voice = try AudioTrackWriter(url: voiceURL)
            voice.start(at: base - paused)
            for step in 0..<frames {
                if let audio = tone(880, start: step * 1_600, frames: 1_600, base: base)?.shifted(back: paused) {
                    var tries = 0
                    while !voice.append(audio), tries < 200 {
                        tries += 1
                        usleep(2_000)
                    }
                }
            }
            let end = base + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)) - paused
            let closed = wait { await voice.finish(at: end) }
            let mixed = work.appendingPathComponent("mezcla.mp4")
            let merge = wait { try await RecordingMixer.merge(movie: movie, microphone: voiceURL, to: mixed) }
            if case .failure(let error) = merge {
                report += "Mezcla con micrófono: ERROR \(error)\n"
            } else {
                report += "Mezcla con micrófono: pista de voz \(closed), resultado \(describe(mixed))\n"
            }
        } catch {
            report += "Mezcla con micrófono: ERROR \(error.localizedDescription)\n"
        }

        // El modelo: pasar a GIF en segundo plano y volver a MP4.
        let recording = Recording(movieURL: movie, duration: 1.5, width: width, height: height, scale: 2, hasAudio: true,
                                  export: RecordingExport(format: .gif, gifFPS: 15, gifScale: 1))
        var changes = 0
        recording.onChange = { changes += 1 }
        Snapshot.spin(until: { recording.readyURL != nil || recording.failed }, timeout: 30)
        report += "Modelo en GIF: archivo \(recording.readyURL?.lastPathComponent ?? "-"), tamaño "
            + "\(recording.exportPixelSize), \(recording.readyFileSize ?? 0) bytes, avisos \(changes)\n"
        let poster = (frame(width: width, height: height, step: 0)).flatMap { buffer -> CGImage? in
            let image = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(image, from: image.extent)
        }

        // Interfaz: barra de opciones, control de grabación y miniatura.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let target = RecordingTarget.area(CGRect(x: 200, y: 200, width: 1280, height: 720), screen)
            let saved = Settings.recordFormat
            for format in RecordingFormat.allCases {
                Settings.recordFormat = format
                let setup = RecordSetupView(target: target)
                let size = setup.fittingSize
                setup.frame = CGRect(origin: .zero, size: size)
                let window = Snapshot.host(setup, size: size)
                Snapshot.write(setup, to: directory.appendingPathComponent("record-setup-\(format.rawValue).png"))
                _ = window
            }
            Settings.recordFormat = saved
            for (name, configure) in [("recording", { (pill: RecordingPillView) in
                pill.set(elapsed: 83)
                pill.set(running: true, paused: false)
            }), ("paused", { pill in
                pill.set(elapsed: 3_725)
                pill.set(running: false, paused: true)
            }), ("saving", { pill in pill.setSaving() })] as [(String, (RecordingPillView) -> Void)] {
                let pill = RecordingPillView()
                configure(pill)
                let size = pill.fittingSize
                pill.frame = CGRect(origin: .zero, size: size)
                let window = Snapshot.host(pill, size: size)
                Snapshot.write(pill, to: directory.appendingPathComponent("record-pill-\(name).png"))
                _ = window
            }
            let below = RecordingController.origin(for: CGSize(width: 500, height: 52),
                                                   around: CGRect(x: 300, y: 300, width: 600, height: 300), on: screen)
            let inside = RecordingController.origin(for: CGSize(width: 500, height: 52), around: screen.frame, on: screen)
            report += "Barra bajo un área en (300,300): \(below); a pantalla completa: \(inside)\n"

            if let poster {
                recording.export = RecordingExport(format: .video, gifFPS: 15, gifScale: 1)
                report += "Modelo en MP4: listo \(recording.readyURL == movie), nombre \(recording.fileName)\n"
                let capture = Capture(recording: recording, poster: poster)
                let manager = ThumbnailManager()
                let controller = ThumbnailController(capture: capture, screen: screen, manager: manager)
                if let view = controller.panel.contentView as? ThumbnailView {
                    for hovering in [false, true] {
                        view.debugSetHover(hovering)
                        Snapshot.write(view, to: directory.appendingPathComponent(
                            hovering ? "thumbnail-recording-hover.png" : "thumbnail-recording.png"))
                    }
                }
                report += "Captura de grabación: \(capture.fileName), puntos \(capture.pointSize), "
                    + "archivo listo \(capture.temporaryFileURL() != nil)\n"
            }
        }
        report += "Almacén: \(RecordingStore.directory.path)\n"
        return report
    }

    // MARK: - Prueba real

    /// Graba una ventana de prueba propia (cuatro colores y un cuadrado que se mueve) y comprueba
    /// que el vídeo contiene exactamente esa zona. No recoge nada de lo que haya en la pantalla.
    static func live(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = "Permiso de pantalla: \(ScreenCapturer.hasPermission)\n"
        defer { try? report.write(to: directory.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8) }
        guard let screen = NSScreen.main else {
            report += "ERROR sin pantalla\n"
            return
        }
        let visible = screen.visibleFrame
        let rect = CGRect(x: visible.minX + 120, y: visible.minY + 120, width: 400, height: 300)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.hasShadow = false
        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        // Abajo: rojo y verde. Arriba: azul y amarillo.
        let colors: [(NSColor, CGRect)] = [
            (.init(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGRect(x: 0, y: 0, width: 200, height: 150)),
            (.init(srgbRed: 0, green: 1, blue: 0, alpha: 1), CGRect(x: 200, y: 0, width: 200, height: 150)),
            (.init(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGRect(x: 0, y: 150, width: 200, height: 150)),
            (.init(srgbRed: 1, green: 1, blue: 0, alpha: 1), CGRect(x: 200, y: 150, width: 200, height: 150)),
        ]
        for (color, frame) in colors {
            let layer = CALayer()
            layer.backgroundColor = color.cgColor
            layer.frame = frame
            view.layer?.addSublayer(layer)
        }
        let mover = CALayer()
        mover.backgroundColor = NSColor.white.cgColor
        mover.frame = CGRect(x: 0, y: 140, width: 20, height: 20)
        view.layer?.addSublayer(mover)
        window.contentView = view
        window.orderFrontRegardless()
        var step = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            step += 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mover.frame.origin.x = CGFloat(step * 4 % 380)
            CATransaction.commit()
        }
        let overlay = ClickOverlay(screen: screen)
        overlay.show()
        defer {
            timer.invalidate()
            window.orderOut(nil)
            overlay.hide()
        }
        Snapshot.spin(until: { false }, timeout: 0.6)

        var options = ScreenRecorder.Options()
        options.showsCursor = false
        options.systemAudio = true
        options.includedWindows = [CGWindowID(window.windowNumber), overlay.windowID]
        let url = directory.appendingPathComponent("selftest.mp4")
        let recorder = ScreenRecorder(target: .area(rect, screen), options: options, outputURL: url)
        var started = false
        recorder.onStart = { started = true }
        if case .failure(let error) = wait(20, { try await recorder.start() }) {
            report += "ERROR al empezar: \(error)\n"
            return
        }
        Snapshot.spin(until: { started }, timeout: 5)
        report += "Primer fotograma: \(started). Ventanas propias incluidas: \(recorder.includedWindowCount) de 2\n"
        // Un segundo grabando, medio en pausa y otro segundo grabando: deben salir unos 2 s.
        Snapshot.spin(until: { false }, timeout: 1)
        overlay.ripple(at: CGPoint(x: rect.minX + 100, y: rect.minY + 75))
        recorder.pause()
        Snapshot.spin(until: { false }, timeout: 0.5)
        recorder.resume()
        Snapshot.spin(until: { false }, timeout: 1)
        switch wait(30, { try await recorder.stop() }) {
        case .failure(let error):
            report += "ERROR al terminar: \(error)\n"
            return
        case .success(let result):
            report += "Resultado: \(result.width)x\(result.height) escala \(result.scale), \(result.frameCount) fotogramas, "
                + String(format: "%.2f s", result.duration) + ", audio \(result.hasAudio)\n"
            report += "Archivo: \(describe(url))\n"
            // Color en el centro de cada cuadrante del primer fotograma (el origen de la imagen está arriba).
            let poster = result.poster
            if let context = CGContext(data: nil, width: poster.width, height: poster.height, bitsPerComponent: 8,
                                       bytesPerRow: poster.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(poster, in: CGRect(x: 0, y: 0, width: poster.width, height: poster.height))
                if let data = context.data?.assumingMemoryBound(to: UInt8.self) {
                    func color(_ fx: Double, _ fy: Double) -> String {
                        let x = Int(Double(poster.width) * fx), y = Int(Double(poster.height) * fy)
                        let p = data + y * poster.width * 4 + x * 4
                        return "(\(p[0]),\(p[1]),\(p[2]))"
                    }
                    report += "Cuadrantes (esperado azul, amarillo / rojo, verde): arriba \(color(0.25, 0.2)) \(color(0.75, 0.2))"
                        + " · abajo \(color(0.25, 0.8)) \(color(0.75, 0.8))\n"
                    report += "Esquinas (deben ser de la ventana, no del escritorio): \(color(0.01, 0.02)) \(color(0.99, 0.02))"
                        + " \(color(0.01, 0.98)) \(color(0.99, 0.98))\n"
                }
            }
            let gif = directory.appendingPathComponent("selftest.gif")
            let size = (Int(rect.width), Int(rect.height))
            let converted = wait {
                try await GIFConverter.convert(movie: url, to: gif, width: size.0, height: size.1, fps: 15,
                                               progress: { _ in }, isCancelled: { false })
            }
            if case .failure(let error) = converted {
                report += "GIF: ERROR \(error)\n"
            } else {
                report += "GIF: \(describeGIF(gif, expecting: size))\n"
            }
        }
        timer.invalidate()
        window.orderOut(nil)
        overlay.hide()

        // El recorrido completo, como lo haría una persona: opciones, grabar, pausar, parar y pasar a GIF.
        // Graba solo un recuadro de 64 puntos en una esquina y borra el resultado al terminar.
        let saved = (Settings.recordFormat, Settings.gifFPS, Settings.gifScale)
        defer { (Settings.recordFormat, Settings.gifFPS, Settings.gifScale) = saved }
        let controller = RecordingController()
        var delivered: Capture?
        var failure = ""
        var phases: [String] = []
        controller.onStatus = {
            let name = "\(controller.phase)"
            if phases.last != name { phases.append(name) }
        }
        controller.onFinish = { capture, _, _ in delivered = capture }
        controller.onError = { failure = "\($0)" }
        controller.begin(.area(CGRect(x: visible.minX, y: visible.minY, width: 64, height: 64), screen))
        Snapshot.spin(until: { false }, timeout: 0.4)
        controller.debugLaunch()
        Snapshot.spin(until: { controller.phase == .recording || !controller.isActive }, timeout: 8)
        Snapshot.spin(until: { false }, timeout: 1.1)
        controller.togglePause()
        Snapshot.spin(until: { false }, timeout: 0.4)
        let pausedText = controller.elapsedText
        controller.togglePause()
        Snapshot.spin(until: { false }, timeout: 0.6)
        controller.stop()
        Snapshot.spin(until: { delivered != nil || !controller.isActive }, timeout: 15)
        report += "Recorrido: fases \(phases.joined(separator: " → ")), en pausa marcaba \(pausedText)\(failure.isEmpty ? "" : ", ERROR \(failure)")\n"
        guard let capture = delivered, let recording = capture.recording else {
            report += "Recorrido: ERROR no se ha entregado ninguna grabación\n"
            return
        }
        report += "Entregado: \(capture.fileName), \(recording.width)x\(recording.height), \(recording.durationText), "
            + "escala guardada \(RecordingStore.scale(for: recording.movieURL).map { "\($0)" } ?? "-"), "
            + "archivo \(describe(recording.movieURL))\n"
        recording.export.format = .gif
        Snapshot.spin(until: { recording.readyURL != nil || recording.failed }, timeout: 20)
        report += "Pasado a GIF: \(recording.readyURL.map { describeGIF($0, expecting: recording.exportPixelSize) } ?? "ERROR")\n"
        let restored = wait { await RecordingStore.load(recording.movieURL) }
        if case .success(let loaded?) = restored {
            report += "Recuperada del almacén: \(loaded.recording.width)x\(loaded.recording.height), "
                + "\(loaded.recording.durationText), miniatura \(loaded.poster.width)x\(loaded.poster.height)\n"
            loaded.recording.cleanUp()
        } else {
            report += "Recuperada del almacén: ERROR\n"
        }
        capture.cleanUp()
        try? FileManager.default.removeItem(at: recording.movieURL)
    }
}
