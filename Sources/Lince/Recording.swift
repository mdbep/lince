import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import os
import UniformTypeIdentifiers

enum RecordingFormat: String, CaseIterable {
    case video, gif

    var label: String { self == .video ? "MP4" : "GIF" }
    var fileExtension: String { self == .video ? "mp4" : "gif" }
    var type: UTType { self == .video ? .mpeg4Movie : .gif }
}

extension Settings {
    private static let store = UserDefaults.standard

    static var recordFormat: RecordingFormat {
        get { RecordingFormat(rawValue: store.string(forKey: "recordFormat") ?? "") ?? .video }
        set { store.set(newValue.rawValue, forKey: "recordFormat") }
    }

    static var recordCursor: Bool {
        get { store.object(forKey: "recordCursor") as? Bool ?? true }
        set { store.set(newValue, forKey: "recordCursor") }
    }

    /// Dibuja una onda alrededor del cursor en cada clic.
    static var recordClicks: Bool {
        get { store.bool(forKey: "recordClicks") }
        set { store.set(newValue, forKey: "recordClicks") }
    }

    static var recordSystemAudio: Bool {
        get { store.bool(forKey: "recordSystemAudio") }
        set { store.set(newValue, forKey: "recordSystemAudio") }
    }

    static var recordMicrophone: Bool {
        get { store.bool(forKey: "recordMicrophone") }
        set { store.set(newValue, forKey: "recordMicrophone") }
    }

    /// Segundos de cuenta atrás antes de empezar; 0 empieza al momento.
    static var recordCountdown: Int {
        get { store.object(forKey: "recordCountdown") as? Int ?? 3 }
        set { store.set(newValue, forKey: "recordCountdown") }
    }

    static var recordFPS: Int {
        get { store.integer(forKey: "recordFPS") == 60 ? 60 : 30 }
        set { store.set(newValue, forKey: "recordFPS") }
    }

    /// Graba todos los píxeles de una pantalla Retina en lugar de uno por punto.
    static var recordRetina: Bool {
        get { store.object(forKey: "recordRetina") as? Bool ?? true }
        set { store.set(newValue, forKey: "recordRetina") }
    }

    static var gifFPS: Int {
        get { [10, 15, 20].contains(store.integer(forKey: "gifFPS")) ? store.integer(forKey: "gifFPS") : 15 }
        set { store.set(newValue, forKey: "gifFPS") }
    }

    /// Tamaño del GIF respecto al tamaño en puntos de lo grabado.
    static var gifScale: Double {
        get {
            let value = store.double(forKey: "gifScale")
            return value > 0 && value <= 1 ? value : 1
        }
        set { store.set(newValue, forKey: "gifScale") }
    }
}

/// Qué se graba.
enum RecordingTarget {
    case area(CGRect, NSScreen)
    case screen(NSScreen)
    case window(WindowInfo)

    /// Rectángulo en coordenadas globales.
    var frame: CGRect {
        switch self {
        case .area(let rect, _): return rect
        case .screen(let screen): return screen.frame
        case .window(let info): return info.frame
        }
    }

    var screen: NSScreen {
        switch self {
        case .area(_, let screen), .screen(let screen): return screen
        case .window(let info): return NSScreen.containing(info.frame)
        }
    }

    /// Las ventanas se graban aisladas y pueden moverse: no llevan marco ni ondas de clic.
    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }

    var isFullScreen: Bool {
        if case .screen = self { return true }
        return false
    }
}

enum RecordingError: LocalizedError {
    case targetUnavailable
    case empty
    case writer(Error?)

    var errorDescription: String? {
        switch self {
        case .targetUnavailable: return "Lo que ibas a grabar ya no está disponible."
        case .empty: return "La grabación no ha llegado a recoger ninguna imagen."
        case .writer(let error): return error?.localizedDescription ?? "No se ha podido escribir el vídeo."
        }
    }
}

// MARK: - Escritura

/// Escribe el MP4: vídeo H.264 con los fotogramas tal y como llegan y, si se pide, una pista de audio AAC.
final class MovieWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let frameDuration: CMTime
    private(set) var startTime: CMTime?
    private(set) var lastVideoTime = CMTime.invalid
    private(set) var frameCount = 0

    init(url: URL, width: Int, height: Int, fps: Int, audio hasAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        // La pantalla comprime muy bien: con esto el texto queda nítido sin archivos enormes.
        let bitrate = min(max(Double(width * height * fps) * 0.07, 1_500_000), 45_000_000)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw RecordingError.writer(nil) }
        writer.add(video)

        if hasAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioTrackWriter.aacSettings(channels: 2))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.writer(nil) }
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }
        guard writer.startWriting() else { throw RecordingError.writer(writer.error) }
    }

    /// Devuelve `true` si el fotograma ha entrado. El primero marca el instante cero del vídeo.
    @discardableResult
    func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard writer.status == .writing else { return false }
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        } else if time <= lastVideoTime {
            return false
        }
        guard video.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else { return false }
        lastVideoTime = time
        frameCount += 1
        return true
    }

    /// Añade audio ya desplazado a la línea de tiempo del vídeo; lo anterior al primer fotograma se descarta.
    @discardableResult
    func append(audio sample: CMSampleBuffer) -> Bool {
        guard let audio, let startTime, writer.status == .writing, audio.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= startTime else { return false }
        return audio.append(sample)
    }

    /// Cierra el archivo; el último fotograma dura hasta `end`.
    func finish(at end: CMTime) async -> Bool {
        guard writer.status == .writing, startTime != nil else {
            writer.cancelWriting()
            return false
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(end, lastVideoTime + frameDuration))
        await writer.finishWriting()
        return writer.status == .completed
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}

/// El micrófono va a su propio archivo: si su formato diera problemas, el vídeo no se pierde.
final class AudioTrackWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var startTime: CMTime?
    private(set) var sampleCount = 0

    static func aacSettings(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000]
    }

    init(url: URL) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writer(nil) }
        writer.add(input)
        guard writer.startWriting() else { throw RecordingError.writer(writer.error) }
    }

    /// Empieza en el mismo instante que el vídeo para que las dos pistas queden alineadas.
    func start(at time: CMTime) {
        guard startTime == nil, writer.status == .writing else { return }
        writer.startSession(atSourceTime: time)
        startTime = time
    }

    @discardableResult
    func append(_ sample: CMSampleBuffer) -> Bool {
        guard let startTime, writer.status == .writing, input.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= startTime, input.append(sample) else { return false }
        sampleCount += 1
        return true
    }

    func finish(at end: CMTime) async -> Bool {
        guard writer.status == .writing, startTime != nil, sampleCount > 0 else {
            cancel()
            return false
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        return writer.status == .completed
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

extension CMSampleBuffer {
    /// Copia con todos sus tiempos adelantados `offset` (lo que se ha estado en pausa).
    func shifted(back offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return self }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - offset
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: self,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy
    }
}

/// Une el vídeo con la pista del micrófono: el vídeo pasa tal cual y todo el audio se mezcla en una sola pista,
/// que es lo que reproducen bien los navegadores y las apps de mensajería.
enum RecordingMixer {
    static func merge(movie: URL, microphone: URL, to output: URL) async throws {
        let main = AVURLAsset(url: movie), voice = AVURLAsset(url: microphone)
        guard let videoTrack = try await main.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let whole = CMTimeRange(start: .zero, duration: try await main.load(.duration))
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try video.insertTimeRange(whole, of: videoTrack, at: .zero)
        let audioTracks = try await main.loadTracks(withMediaType: .audio) + voice.loadTracks(withMediaType: .audio)
        var mixed: [AVCompositionTrack] = []
        for track in audioTracks {
            let range = try await track.load(.timeRange).intersection(whole)
            guard range.duration > .zero,
                  let target = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(range, of: track, at: range.start)
            mixed.append(target)
        }
        guard !mixed.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: mixed, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        for item in [videoOutput, audioOutput] as [AVAssetReaderOutput] {
            item.alwaysCopiesSampleData = false
            guard reader.canAdd(item) else { throw CocoaError(.fileReadCorruptFile) }
            reader.add(item)
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let format = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioTrackWriter.aacSettings(channels: 2))
        for input in [videoInput, audioInput] {
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
        }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            // Cada pista se copia en su propia cola; la entrada y la salida de una pista solo se tocan desde ella.
            for pump in [Unchecked((videoInput, videoOutput as AVAssetReaderOutput, "video")),
                         Unchecked((audioInput, audioOutput as AVAssetReaderOutput, "audio"))] {
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let (input, _, name) = pump.value
                        input.requestMediaDataWhenReady(on: DispatchQueue(label: "lince.mixer.\(name)")) {
                            let (input, source, _) = pump.value
                            while input.isReadyForMoreMediaData {
                                guard let sample = source.copyNextSampleBuffer(), input.append(sample) else {
                                    input.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        writer.endSession(atSourceTime: whole.duration)
        await writer.finishWriting()
        guard writer.status == .completed, reader.status != .failed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - Grabador

/// Graba la pantalla con ScreenCaptureKit. Los fotogramas solo llegan cuando algo cambia,
/// así que una pantalla quieta apenas gasta procesador ni espacio.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Options {
        var fps = 30
        var showsCursor = true
        var systemAudio = false
        var microphone = false
        var retina = true
        /// Ventanas de Lince que sí deben salir (las ondas de los clics).
        var includedWindows: [CGWindowID] = []
    }

    struct Result {
        let url: URL
        let duration: Double
        let width: Int
        let height: Int
        let scale: CGFloat
        let poster: CGImage
        let hasAudio: Bool
        let frameCount: Int
    }

    /// Ha entrado el primer fotograma: la grabación ha empezado de verdad. En el hilo principal.
    var onStart: (() -> Void)?
    /// El sistema ha cortado la captura (se cerró la ventana, se desconectó la pantalla…). En el hilo principal.
    var onInterrupted: (() -> Void)?
    /// Cuántas de las ventanas pedidas en `includedWindows` se han encontrado.
    private(set) var includedWindowCount = 0

    private let target: RecordingTarget
    private let options: Options
    private let outputURL: URL
    private let queue = DispatchQueue(label: "lince.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: MovieWriter?
    private var voice: AudioTrackWriter?
    private var poster: CGImage?
    private var pausedAt: CMTime?
    private var pausedTotal = CMTime.zero
    private var finished = false
    /// Se pidió parar o cancelar; si la captura aún estaba arrancando, se cierra en cuanto arranque.
    private var stopRequested = false
    private var size = (width: 0, height: 0)
    private var scale: CGFloat = 1

    init(target: RecordingTarget, options: Options, outputURL: URL) {
        self.target = target
        self.options = options
        self.outputURL = outputURL
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Tamaño en píxeles con el que saldrá un área de ese tamaño en puntos.
    static func pixelSize(for pointSize: CGSize, nativeScale: CGFloat, retina: Bool) -> (width: Int, height: Int, scale: CGFloat) {
        var scale = retina ? max(nativeScale, 1) : 1
        // Por encima de 4K el códec deja de ser compatible con casi todo: se reduce lo justo.
        let pixels = pointSize.width * pointSize.height * scale * scale
        let limit: CGFloat = 3840 * 2160
        if pixels > limit { scale *= (limit / pixels).squareRoot() }
        let width = max(2, Int((pointSize.width * scale).rounded()) & ~1)
        let height = max(2, Int((pointSize.height * scale).rounded()) & ~1)
        return (width, height, scale)
    }

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        var sourceRect: CGRect?
        let pointSize: CGSize
        switch target {
        case .window(let info):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else {
                throw RecordingError.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointSize = filter.contentRect.size
        case .area, .screen:
            let screen = target.screen
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingError.targetUnavailable
            }
            // Fuera todo lo de Lince (controles, miniaturas…), menos las ondas de los clics.
            let pid = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == pid }
            let included = content.windows.filter { options.includedWindows.contains($0.windowID) }
            includedWindowCount = included.count
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: included)
            let frame = screen.frame
            let local = target.frame.intersection(frame)
            guard local.width >= 2, local.height >= 2 else { throw RecordingError.targetUnavailable }
            if !target.isFullScreen {
                // ScreenCaptureKit mide desde la esquina superior izquierda de la pantalla.
                sourceRect = CGRect(x: local.minX - frame.minX, y: frame.maxY - local.maxY,
                                    width: local.width, height: local.height)
            }
            pointSize = local.size
        }

        let output = Self.pixelSize(for: pointSize, nativeScale: CGFloat(filter.pointPixelScale), retina: options.retina)
        size = (output.width, output.height)
        scale = output.scale

        let config = SCStreamConfiguration()
        config.width = output.width
        config.height = output.height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.showsCursor = options.showsCursor
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.queueDepth = 6
        config.scalesToFit = true
        config.captureResolution = options.retina ? .best : .nominal
        if target.isWindow {
            config.ignoreShadowsSingleWindow = true
            config.backgroundColor = .black
        }
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        var microphone = false
        if #available(macOS 15.0, *), options.microphone {
            config.captureMicrophone = true
            microphone = true
        }

        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        writer = try MovieWriter(url: outputURL, width: output.width, height: output.height, fps: options.fps,
                                 audio: options.systemAudio)
        if microphone {
            // Si el micrófono no se puede preparar, se graba igualmente sin él.
            voice = try? AudioTrackWriter(url: outputURL.deletingPathExtension().appendingPathExtension("mic.m4a"))
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *), voice != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            discard()
            throw error
        }
        if stopRequested {
            self.stream = nil
            try? await stream.stopCapture()
        }
    }

    // MARK: Muestras

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // Se ejecuta en `queue`.
        guard !finished, pausedAt == nil, CMSampleBufferIsValid(sample), let writer else { return }
        switch type {
        case .screen:
            // Solo los fotogramas completos traen imagen; el resto avisa de que nada ha cambiado.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sample) - pausedTotal
            let first = writer.startTime == nil
            guard writer.append(buffer, at: time), first else { return }
            // El primer fotograma hace de miniatura; se convierte ya para no retener el búfer de la captura.
            poster = Self.image(from: buffer)
            voice?.start(at: time)
            DispatchQueue.main.async { [weak self] in self?.onStart?() }
        case .audio:
            if let shifted = sample.shifted(back: pausedTotal) { writer.append(audio: shifted) }
        default:
            if let shifted = sample.shifted(back: pausedTotal) { voice?.append(shifted) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream != nil else { return }
            self.onInterrupted?()
        }
    }

    // MARK: Control

    func pause() {
        queue.async { if self.pausedAt == nil { self.pausedAt = Self.now } }
    }

    func resume() {
        queue.async {
            guard let pausedAt = self.pausedAt else { return }
            self.pausedTotal = self.pausedTotal + (Self.now - pausedAt)
            self.pausedAt = nil
        }
    }

    /// Detiene la captura y cierra el archivo.
    @MainActor
    func stop() async throws -> Result {
        stopRequested = true
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        let (writer, voice, poster, end) = queue.sync { () -> (MovieWriter?, AudioTrackWriter?, CGImage?, CMTime) in
            finished = true
            return (self.writer, self.voice, self.poster, (pausedAt ?? Self.now) - pausedTotal)
        }
        guard let writer, let poster, await writer.finish(at: end) else {
            writer?.cancel()
            voice?.cancel()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.empty
        }
        var hasAudio = options.systemAudio
        if let voice, await voice.finish(at: end) {
            // Si la mezcla falla, se conserva el vídeo sin la voz antes que perderlo todo.
            let mixed = outputURL.deletingPathExtension().appendingPathExtension("mix.mp4")
            if (try? await RecordingMixer.merge(movie: outputURL, microphone: voice.url, to: mixed)) != nil,
               (try? FileManager.default.replaceItemAt(outputURL, withItemAt: mixed)) != nil {
                hasAudio = true
            }
            try? FileManager.default.removeItem(at: mixed)
            try? FileManager.default.removeItem(at: voice.url)
        }
        let duration = (try? await AVURLAsset(url: outputURL).load(.duration).seconds) ?? 0
        return Result(url: outputURL, duration: duration, width: size.width, height: size.height, scale: scale,
                      poster: poster, hasAudio: hasAudio, frameCount: writer.frameCount)
    }

    /// Detiene la captura y borra lo grabado.
    @MainActor
    func cancel() async {
        stopRequested = true
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        discard()
    }

    private func discard() {
        stream = nil
        queue.sync {
            finished = true
            writer?.cancel()
            voice?.cancel()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    private static let imageContext = CIContext()

    private static func image(from buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return imageContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

// MARK: - Grabación terminada

/// Formato con el que una grabación se copia, se guarda o se arrastra.
struct RecordingExport: Equatable {
    var format: RecordingFormat = Settings.recordFormat
    var gifFPS = Settings.gifFPS
    var gifScale = Settings.gifScale
}

/// Una grabación terminada: el MP4 original y, si se pide, el GIF que sale de él.
final class Recording {
    let movieURL: URL
    let duration: Double
    let width: Int
    let height: Int
    /// Píxeles del vídeo por punto de pantalla.
    let scale: CGFloat
    let hasAudio: Bool
    let date: Date

    /// Avisa, en el hilo principal, cada vez que cambia el progreso o termina una conversión.
    var onChange: (() -> Void)?

    var export: RecordingExport {
        didSet {
            guard export != oldValue else { return }
            Settings.recordFormat = export.format
            Settings.gifFPS = export.gifFPS
            Settings.gifScale = export.gifScale
            prepare()
        }
    }

    /// Progreso de la conversión a GIF en curso, de 0 a 1; `nil` si no hay ninguna.
    private(set) var progress: Double?
    private(set) var failed = false
    private var gifURL: URL?
    private var gifSettings: RecordingExport?
    private var generation = 0
    private var conversion: ConversionToken?
    private var waiting: [(URL?) -> Void] = []

    init(movieURL: URL, duration: Double, width: Int, height: Int, scale: CGFloat, hasAudio: Bool,
         date: Date = Date(), export: RecordingExport = RecordingExport()) {
        self.movieURL = movieURL
        self.duration = duration
        self.width = width
        self.height = height
        self.scale = max(scale, 0.1)
        self.hasAudio = hasAudio
        self.date = date
        self.export = export
        prepare()
    }

    deinit { removeGIF() }

    /// Peso del archivo listo, si lo hay.
    var readyFileSize: Int64? {
        guard let url = readyURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    var pointSize: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }

    /// Tamaño del GIF: el de lo grabado en puntos, por la fracción elegida.
    func gifSize(scale fraction: Double) -> (width: Int, height: Int) {
        let target = min(CGFloat(width), max(16, (pointSize.width * CGFloat(fraction)).rounded()))
        let ratio = target / CGFloat(max(width, 1))
        return (Int(target), max(1, Int((CGFloat(height) * ratio).rounded())))
    }

    /// Tamaño en píxeles con el que saldrá con el formato actual.
    var exportPixelSize: (width: Int, height: Int) {
        export.format == .video ? (width, height) : gifSize(scale: export.gifScale)
    }

    var fileName: String {
        "\(movieURL.deletingPathExtension().lastPathComponent).\(export.format.fileExtension)"
    }

    /// El archivo listo para usar, o `nil` mientras se convierte.
    var readyURL: URL? {
        switch export.format {
        case .video: return movieURL
        case .gif: return gifSettings == export && progress == nil ? gifURL : nil
        }
    }

    var durationText: String { Recording.format(duration) }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Ejecuta `body` con el archivo en cuanto esté listo (al momento si ya lo está); `nil` si la conversión falla.
    func whenReady(_ body: @escaping (URL?) -> Void) {
        if let readyURL {
            body(readyURL)
        } else if failed {
            body(nil)
        } else {
            waiting.append(body)
        }
    }

    private func removeGIF() {
        if let gifURL { try? FileManager.default.removeItem(at: gifURL.deletingLastPathComponent()) }
        gifURL = nil
        gifSettings = nil
    }

    private func settle(_ url: URL?) {
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0(url) }
        onChange?()
    }

    /// Deja listo el archivo del formato elegido; el GIF se genera en segundo plano.
    private func prepare() {
        generation += 1
        conversion?.cancel()
        conversion = nil
        failed = false
        guard export.format == .gif else {
            progress = nil
            settle(movieURL)
            return
        }
        if gifSettings == export, gifURL != nil {
            progress = nil
            settle(gifURL)
            return
        }
        removeGIF()
        let token = generation
        let settings = export
        let size = gifSize(scale: settings.gifScale)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lince", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(fileName)
        let movie = movieURL
        progress = 0
        onChange?()
        let job = ConversionToken()
        conversion = job
        let owner = WeakBox(self)
        Task.detached(priority: .userInitiated) {
            let result: Bool
            do {
                try await GIFConverter.convert(movie: movie, to: output, width: size.width, height: size.height,
                                               fps: settings.gifFPS, progress: { value in
                    // Con avisar cada 2 % basta para que el porcentaje se mueva con fluidez.
                    guard job.shouldReport(value) else { return }
                    DispatchQueue.main.async {
                        guard let self = owner.value, self.generation == token else { return }
                        self.progress = value
                        self.onChange?()
                    }
                }, isCancelled: { job.isCancelled })
                result = true
            } catch {
                result = false
            }
            await MainActor.run {
                guard let self = owner.value, self.generation == token else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.progress = nil
                if result {
                    self.gifURL = output
                    self.gifSettings = settings
                    self.settle(output)
                } else {
                    try? FileManager.default.removeItem(at: directory)
                    self.failed = true
                    self.settle(nil)
                }
            }
        }
    }

    /// Borra lo derivado (el GIF). El MP4 original se queda en el almacén por si hay que recuperarlo.
    func cleanUp() {
        generation += 1
        conversion?.cancel()
        conversion = nil
        progress = nil
        waiting = []
        onChange = nil
        // Si se acaba de arrastrar a otra app, puede que aún lo esté leyendo: se borra pasado un rato.
        if let directory = gifURL?.deletingLastPathComponent() {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        gifURL = nil
        gifSettings = nil
    }
}

/// Estado de una conversión a GIF que comparten el hilo principal y el que convierte.
private final class ConversionToken: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Solo lo toca el hilo que convierte.
    private var lastReport = 0.0

    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }

    func shouldReport(_ value: Double) -> Bool {
        guard value - lastReport >= 0.02 else { return false }
        lastReport = value
        return true
    }
}

/// Referencia débil a un objeto que solo se usa en el hilo principal, para llevarla a una tarea en segundo plano.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Envuelve objetos de AVFoundation que se entregan a una única cola.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Guarda los MP4 originales de las últimas grabaciones, para que cerrar una miniatura no las pierda.
enum RecordingStore {
    private static let keepCount = 12
    private static let keepSeconds: TimeInterval = 7 * 24 * 3600

    static let directory: URL = {
        let url: URL
        if let override = ProcessInfo.processInfo.environment["LINCE_HISTORY_DIR"] {
            url = URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Recordings", isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            url = base.appendingPathComponent("Lince/Recordings", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Ruta para una grabación nueva, con el mismo nombre que llevan las capturas.
    static func newURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        let base = "Lince \(formatter.string(from: date))"
        var url = directory.appendingPathComponent("\(base).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).mp4")
            counter += 1
        }
        return url
    }

    private static let scaleAttribute = "com.sowify.lince.scale"

    /// La escala (píxeles por punto) se anota en el propio archivo para poder recuperarlo tal cual.
    static func setScale(_ scale: CGFloat, for url: URL) {
        let text = String(Double(scale))
        _ = text.withCString { setxattr(url.path, scaleAttribute, $0, strlen($0), 0, 0) }
    }

    static func scale(for url: URL) -> CGFloat? {
        var buffer = [CChar](repeating: 0, count: 32)
        let length = getxattr(url.path, scaleAttribute, &buffer, buffer.count - 1, 0, 0)
        guard length > 0, let value = Double(String(cString: buffer)), value > 0 else { return nil }
        return CGFloat(value)
    }

    /// Las grabaciones guardadas, de la más reciente a la más antigua.
    static func stored() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(".mix.mp4") }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static var latest: URL? { stored().first }

    /// Borra lo que sobra: lo antiguo, lo que pasa del cupo y los restos de grabaciones interrumpidas.
    static func purge(keeping current: Set<URL> = []) {
        let now = Date()
        for (index, url) in stored().enumerated() where !current.contains(url) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if index >= keepCount || now.timeIntervalSince(date) > keepSeconds {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers where url.pathExtension == "m4a" || url.lastPathComponent.hasSuffix(".mix.mp4") {
            if !current.contains(where: { $0.deletingPathExtension().lastPathComponent
                == url.deletingPathExtension().deletingPathExtension().lastPathComponent }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Vuelve a abrir una grabación del almacén, con su primer fotograma como miniatura.
    static func load(_ url: URL) async -> (recording: Recording, poster: CGImage)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration).seconds else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let poster = try? await generator.image(at: .zero).image else { return nil }
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let scale = self.scale(for: url) ?? NSScreen.main?.backingScaleFactor ?? 2
        let recording = Recording(movieURL: url, duration: duration, width: Int(size.width), height: Int(size.height),
                                  scale: scale, hasAudio: hasAudio, date: date)
        return (recording, poster)
    }
}
