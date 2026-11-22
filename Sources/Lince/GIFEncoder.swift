import Accelerate
import AVFoundation

/// Paleta común a todo el GIF: 255 colores sacados de la grabación y uno reservado como transparente.
struct GIFPalette {
    static let transparentIndex: UInt8 = 255
    /// Cada color se agrupa por sus 6 bits altos por canal.
    private static let bins = 1 << 18

    /// 256 entradas RGB.
    private(set) var colors = [UInt8](repeating: 0, count: 768)
    private var count = 0
    /// Por cada color ya visto: su color de paleta, el segundo con el que se trama y en qué proporción.
    private var lookup = [UInt32](repeating: .max, count: GIFPalette.bins)
    /// Matriz de Bayer 4×4: reparte los dos colores en un patrón fijo, que no parpadea entre fotogramas.
    private static let bayer: [UInt32] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    @inline(__always)
    private static func bin(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (Int(r) >> 2) << 12 | (Int(g) >> 2) << 6 | Int(b) >> 2
    }

    /// Recuento de colores de los fotogramas de muestra, de donde sale la paleta.
    final class Histogram {
        fileprivate var counts = [UInt32](repeating: 0, count: GIFPalette.bins)
        fileprivate var red = [UInt64](repeating: 0, count: GIFPalette.bins)
        fileprivate var green = [UInt64](repeating: 0, count: GIFPalette.bins)
        fileprivate var blue = [UInt64](repeating: 0, count: GIFPalette.bins)

        /// Suma un fotograma BGRA, mirando un píxel de cada `step` en cada dirección.
        func add(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int) {
            var y = 0
            while y < height {
                let row = pixels + y * bytesPerRow
                var x = 0
                while x < width {
                    let p = row + x * 4
                    let b = p[0], g = p[1], r = p[2]
                    let key = GIFPalette.bin(r, g, b)
                    counts[key] &+= 1
                    red[key] &+= UInt64(r)
                    green[key] &+= UInt64(g)
                    blue[key] &+= UInt64(b)
                    x += step
                }
                y += step
            }
        }
    }

    /// Corte por la mediana: se parte una y otra vez la caja de colores más dispersa hasta tener 255.
    init(histogram: Histogram) {
        struct Entry {
            var r: UInt8, g: UInt8, b: UInt8
            var count: UInt32
            var key: Int32
        }
        struct Box {
            var range: Range<Int>
            var spread: Int
            var axis: Int
            var weight: UInt64
        }
        var entries: [Entry] = []
        for key in 0..<Self.bins where histogram.counts[key] > 0 {
            let n = UInt64(histogram.counts[key])
            entries.append(Entry(r: UInt8(histogram.red[key] / n), g: UInt8(histogram.green[key] / n),
                                 b: UInt8(histogram.blue[key] / n), count: histogram.counts[key], key: Int32(key)))
        }
        guard !entries.isEmpty else {
            count = 1
            return
        }

        func measure(_ range: Range<Int>) -> Box {
            var lo = (255, 255, 255), hi = (0, 0, 0)
            var weight: UInt64 = 0
            for entry in entries[range] {
                lo = (min(lo.0, Int(entry.r)), min(lo.1, Int(entry.g)), min(lo.2, Int(entry.b)))
                hi = (max(hi.0, Int(entry.r)), max(hi.1, Int(entry.g)), max(hi.2, Int(entry.b)))
                weight += UInt64(entry.count)
            }
            // El verde pesa más: es donde el ojo distingue mejor.
            let spans = [(hi.0 - lo.0) * 3, (hi.1 - lo.1) * 4, (hi.2 - lo.2) * 2]
            let axis = spans.indices.max { spans[$0] < spans[$1] } ?? 0
            return Box(range: range, spread: spans[axis], axis: axis, weight: weight)
        }

        let limit = Int(Self.transparentIndex)
        var boxes = [measure(0..<entries.count)]
        while boxes.count < limit {
            // Se parte la caja que más error reparte: mucha dispersión y muchos píxeles.
            var best = -1
            var bestScore = 0.0
            for (index, box) in boxes.enumerated() where box.range.count > 1 && box.spread > 0 {
                let score = Double(box.spread) * Double(box.weight).squareRoot()
                if score > bestScore {
                    bestScore = score
                    best = index
                }
            }
            guard best >= 0 else { break }
            let box = boxes[best]
            switch box.axis {
            case 0: entries[box.range].sort { $0.r < $1.r }
            case 1: entries[box.range].sort { $0.g < $1.g }
            default: entries[box.range].sort { $0.b < $1.b }
            }
            var half: UInt64 = 0
            var cut = box.range.lowerBound
            while cut < box.range.upperBound - 1 {
                half += UInt64(entries[cut].count)
                cut += 1
                if half * 2 >= box.weight { break }
            }
            boxes[best] = measure(box.range.lowerBound..<cut)
            boxes.append(measure(cut..<box.range.upperBound))
        }

        count = boxes.count
        for (index, box) in boxes.enumerated() {
            var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0
            for entry in entries[box.range] {
                let n = UInt64(entry.count)
                r += UInt64(entry.r) * n
                g += UInt64(entry.g) * n
                b += UInt64(entry.b) * n
            }
            let weight = max(box.weight, 1)
            colors[index * 3] = UInt8(r / weight)
            colors[index * 3 + 1] = UInt8(g / weight)
            colors[index * 3 + 2] = UInt8(b / weight)
        }
    }

    /// El índice de paleta para un píxel. Los colores que la paleta tiene tal cual salen exactos; los que
    /// caen entre dos (degradados, sombras) se traman con un patrón fijo según su posición.
    @inline(__always)
    mutating func index(r: UInt8, g: UInt8, b: UInt8, x: Int, y: Int) -> UInt8 {
        let key = Self.bin(r, g, b)
        var entry = lookup[key]
        if entry == .max {
            entry = resolve(r: Int(r), g: Int(g), b: Int(b))
            lookup[key] = entry
        }
        let threshold = entry >> 16
        if threshold != 0, Self.bayer[(y & 3) << 2 | (x & 3)] < threshold {
            return UInt8((entry >> 8) & 0xFF)
        }
        return UInt8(entry & 0xFF)
    }

    /// Busca el color más cercano y el mejor compañero para mezclar con él. Cada color se resuelve una sola vez.
    private func resolve(r: Int, g: Int, b: Int) -> UInt32 {
        colors.withUnsafeBufferPointer { palette in
            var best = 0
            var bestDistance = Int.max
            for index in 0..<count {
                let dr = palette[index * 3].distance(r), dg = palette[index * 3 + 1].distance(g)
                let db = palette[index * 3 + 2].distance(b)
                let distance = dr * dr * 3 + dg * dg * 4 + db * db * 2
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            // Ya es prácticamente exacto: no hay nada que tramar.
            guard bestDistance > 12 else { return UInt32(best) }
            let r1 = Int(palette[best * 3]), g1 = Int(palette[best * 3 + 1]), b1 = Int(palette[best * 3 + 2])
            let wr = Double(r - r1), wg = Double(g - g1), wb = Double(b - b1)
            var partner = best
            var mix = 0.0
            var bestScore = Double(bestDistance)
            for index in 0..<count where index != best {
                let vr = Double(Int(palette[index * 3]) - r1), vg = Double(Int(palette[index * 3 + 1]) - g1)
                let vb = Double(Int(palette[index * 3 + 2]) - b1)
                let length = vr * vr * 3 + vg * vg * 4 + vb * vb * 2
                // Dos colores muy distintos tramados se ven como ruido: solo se mezclan vecinos.
                guard length > 0, length < 36_000 else { continue }
                let t = min(max((wr * vr * 3 + wg * vg * 4 + wb * vb * 2) / length, 0), 0.5)
                guard t >= 1.0 / 16 else { continue }
                let er = wr - vr * t, eg = wg - vg * t, eb = wb - vb * t
                let score = er * er * 3 + eg * eg * 4 + eb * eb * 2 + length * t * 0.05
                if score < bestScore {
                    bestScore = score
                    partner = index
                    mix = t
                }
            }
            return UInt32(best) | UInt32(partner) << 8 | UInt32((mix * 16).rounded()) << 16
        }
    }
}

/// Escribe un GIF animado fotograma a fotograma. De cada uno solo guarda el rectángulo que ha cambiado,
/// y dentro de él marca como transparente lo que sigue igual: así una grabación de pantalla pesa muy poco.
final class GIFEncoder {
    let width: Int
    let height: Int
    private(set) var frameCount = 0

    private let handle: FileHandle
    private var palette: GIFPalette
    private var canvas: [UInt8]
    private var current: [UInt8]
    private var hasCanvas = false
    /// El último fotograma espera sin escribirse hasta saber cuánto dura.
    private var pending: (data: Data, delayOffset: Int, start: Double)?
    private var lzw = LZW()

    init(url: URL, width: Int, height: Int, palette: GIFPalette) throws {
        self.width = width
        self.height = height
        self.palette = palette
        canvas = [UInt8](repeating: 0, count: width * height)
        current = canvas
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var header = Data("GIF89a".utf8)
        header.append(le16(width))
        header.append(le16(height))
        // Paleta global de 256 colores a 8 bits, fondo 0, sin relación de aspecto.
        header.append(contentsOf: [0xF7, 0, 0])
        header.append(contentsOf: palette.colors)
        // Extensión de Netscape: se repite sin fin.
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        try handle.write(contentsOf: header)
    }

    private func le16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    /// Añade el fotograma BGRA que se ve a partir de `time` (en segundos).
    func add(_ pixels: UnsafePointer<UInt8>, bytesPerRow: Int, at time: Double) throws {
        let width = width, height = height
        current.withUnsafeMutableBufferPointer { indices in
            for y in 0..<height {
                var source = pixels + y * bytesPerRow
                var target = indices.baseAddress! + y * width
                for x in 0..<width {
                    target.pointee = palette.index(r: source[2], g: source[1], b: source[0], x: x, y: y)
                    source += 4
                    target += 1
                }
            }
        }

        var box = (minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
        if hasCanvas {
            // Rectángulo mínimo que contiene todo lo que ha cambiado.
            var minX = width, minY = height, maxX = -1, maxY = -1
            current.withUnsafeBufferPointer { now in
                canvas.withUnsafeBufferPointer { before in
                    for y in 0..<height {
                        let row = y * width
                        if memcmp(now.baseAddress! + row, before.baseAddress! + row, width) == 0 { continue }
                        var first = 0
                        while now[row + first] == before[row + first] { first += 1 }
                        var last = width - 1
                        while now[row + last] == before[row + last] { last -= 1 }
                        minX = min(minX, first)
                        maxX = max(maxX, last)
                        if minY == height { minY = y }
                        maxY = y
                    }
                }
            }
            // Nada ha cambiado: el fotograma anterior simplemente dura más.
            guard maxX >= 0 else { return }
            box = (minX, minY, maxX, maxY)
        }

        let boxWidth = box.maxX - box.minX + 1, boxHeight = box.maxY - box.minY + 1
        var region = [UInt8](repeating: 0, count: boxWidth * boxHeight)
        let differential = hasCanvas
        region.withUnsafeMutableBufferPointer { out in
            current.withUnsafeBufferPointer { now in
                canvas.withUnsafeBufferPointer { before in
                    for y in 0..<boxHeight {
                        let row = (box.minY + y) * width + box.minX
                        for x in 0..<boxWidth {
                            let value = now[row + x]
                            out[y * boxWidth + x] = differential && value == before[row + x]
                                ? GIFPalette.transparentIndex : value
                        }
                    }
                }
            }
        }
        swap(&canvas, &current)
        hasCanvas = true

        try flush(until: time)
        var data = Data()
        // Control gráfico: no borrar al acabar (el siguiente se pinta encima) y, si procede, transparencia.
        data.append(contentsOf: [0x21, 0xF9, 0x04, differential ? 0x05 : 0x04])
        let delayOffset = data.count
        data.append(contentsOf: [0, 0, GIFPalette.transparentIndex, 0])
        data.append(0x2C)
        data.append(le16(box.minX))
        data.append(le16(box.minY))
        data.append(le16(boxWidth))
        data.append(le16(boxHeight))
        data.append(0)
        data.append(8)
        let compressed = lzw.encode(region)
        var offset = 0
        while offset < compressed.count {
            let length = min(255, compressed.count - offset)
            data.append(UInt8(length))
            data.append(contentsOf: compressed[offset..<offset + length])
            offset += length
        }
        data.append(0)
        pending = (data, delayOffset, time)
        frameCount += 1
    }

    /// Escribe el fotograma pendiente, que dura hasta `time`.
    private func flush(until time: Double) throws {
        guard var frame = pending else { return }
        pending = nil
        // El GIF mide en centésimas; por debajo de 2 muchos visores lo reproducen lento.
        let delay = min(65_535, max(2, Int((time * 100).rounded()) - Int((frame.start * 100).rounded())))
        frame.data[frame.delayOffset] = UInt8(delay & 0xFF)
        frame.data[frame.delayOffset + 1] = UInt8(delay >> 8)
        try handle.write(contentsOf: frame.data)
    }

    func finish(at end: Double) throws {
        try flush(until: end)
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    func cancel() {
        try? handle.close()
    }
}

private extension UInt8 {
    @inline(__always)
    func distance(_ other: Int) -> Int { Int(self) - other }
}

/// Compresión LZW con códigos de tamaño variable, tal y como la pide el formato GIF.
private struct LZW {
    private static let tableSize = 1 << 13
    private var keys = [Int32](repeating: -1, count: LZW.tableSize)
    private var values = [UInt16](repeating: 0, count: LZW.tableSize)

    mutating func encode(_ pixels: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(pixels.count / 4 + 16)
        guard !pixels.isEmpty else { return output }
        let clearCode = 256
        var codeSize = 9
        var maxCode = clearCode + 1
        var bits: UInt32 = 0
        var bitCount: UInt32 = 0

        func emit(_ code: Int, _ size: Int, _ bits: inout UInt32, _ bitCount: inout UInt32, _ output: inout [UInt8]) {
            bits |= UInt32(code) << bitCount
            bitCount += UInt32(size)
            while bitCount >= 8 {
                output.append(UInt8(bits & 0xFF))
                bits >>= 8
                bitCount -= 8
            }
        }

        let mask = Self.tableSize - 1
        keys.withUnsafeMutableBufferPointer { keys in
            values.withUnsafeMutableBufferPointer { values in
                pixels.withUnsafeBufferPointer { pixels in
                    func reset() {
                        for index in 0..<Self.tableSize { keys[index] = -1 }
                    }
                    reset()
                    emit(clearCode, codeSize, &bits, &bitCount, &output)
                    var prefix = Int(pixels[0])
                    for index in 1..<pixels.count {
                        let value = Int(pixels[index])
                        let key = Int32(prefix << 8 | value)
                        var slot = Int((UInt32(bitPattern: key) &* 2_654_435_761) >> 19) & mask
                        var found = -1
                        while keys[slot] != -1 {
                            if keys[slot] == key {
                                found = Int(values[slot])
                                break
                            }
                            slot = (slot + 1) & mask
                        }
                        if found >= 0 {
                            prefix = found
                            continue
                        }
                        emit(prefix, codeSize, &bits, &bitCount, &output)
                        maxCode += 1
                        keys[slot] = key
                        values[slot] = UInt16(maxCode)
                        if maxCode >= 1 << codeSize { codeSize += 1 }
                        if maxCode == 4095 {
                            // Diccionario lleno: se avisa al decodificador y se empieza de cero.
                            emit(clearCode, codeSize, &bits, &bitCount, &output)
                            reset()
                            codeSize = 9
                            maxCode = clearCode + 1
                        }
                        prefix = value
                    }
                    emit(prefix, codeSize, &bits, &bitCount, &output)
                    emit(clearCode, codeSize, &bits, &bitCount, &output)
                    emit(clearCode + 1, 9, &bits, &bitCount, &output)
                }
            }
        }
        if bitCount > 0 { output.append(UInt8(bits & 0xFF)) }
        return output
    }
}

/// Convierte una grabación en GIF: una pasada para elegir la paleta y otra para codificar.
enum GIFConverter {
    struct Cancelled: Error {}

    /// `progress` va de 0 a 1 y se llama desde un hilo secundario. Devuelve el número de fotogramas escritos.
    @discardableResult
    static func convert(movie: URL, to output: URL, width: Int, height: Int, fps: Int,
                        progress: @escaping (Double) -> Void,
                        isCancelled: @escaping () -> Bool) async throws -> Int {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let duration = max(try await asset.load(.duration).seconds, 0.05)

        // Primera pasada: unas decenas de fotogramas repartidos por toda la grabación deciden la paleta.
        let histogram = GIFPalette.Histogram()
        let sampleGap = duration / 48
        var nextSample = 0.0
        try read(asset: asset, track: track) { buffer, time in
            if isCancelled() { throw Cancelled() }
            guard time >= nextSample else { return }
            nextSample = time + sampleGap
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
            let step = max(1, Int((Double(sourceWidth * sourceHeight) / 160_000).squareRoot()))
            histogram.add(base.assumingMemoryBound(to: UInt8.self), width: sourceWidth, height: sourceHeight,
                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), step: step)
            progress(min(time / duration, 1) * 0.25)
        }

        let encoder = try GIFEncoder(url: output, width: width, height: height, palette: GIFPalette(histogram: histogram))
        var scaled = [UInt8](repeating: 0, count: width * height * 4)
        // Los fotogramas se reparten en casillas de 1/fps; de cada casilla se queda el último.
        var held: (buffer: CVPixelBuffer, tick: Int)?

        func emit(_ buffer: CVPixelBuffer, tick: Int) throws {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let time = Double(tick) / Double(fps)
            if sourceWidth == width, sourceHeight == height {
                try encoder.add(base.assumingMemoryBound(to: UInt8.self), bytesPerRow: rowBytes, at: time)
                return
            }
            try scaled.withUnsafeMutableBytes { target in
                var source = vImage_Buffer(data: base, height: vImagePixelCount(sourceHeight),
                                           width: vImagePixelCount(sourceWidth), rowBytes: rowBytes)
                var destination = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width * 4)
                vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
                try encoder.add(target.baseAddress!.assumingMemoryBound(to: UInt8.self), bytesPerRow: width * 4, at: time)
            }
        }

        do {
            try read(asset: asset, track: track) { buffer, time in
                if isCancelled() { throw Cancelled() }
                let tick = Int((time * Double(fps)).rounded(.down))
                if let previous = held, previous.tick != tick {
                    try emit(previous.buffer, tick: previous.tick)
                    progress(0.25 + min(time / duration, 1) * 0.75)
                }
                held = (buffer, tick)
            }
            if let last = held { try emit(last.buffer, tick: last.tick) }
            try encoder.finish(at: duration)
        } catch {
            encoder.cancel()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return encoder.frameCount
    }

    /// Recorre los fotogramas del vídeo en BGRA, con su instante en segundos.
    private static func read(asset: AVAsset, track: AVAssetTrack,
                             body: (CVPixelBuffer, Double) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            try autoreleasepool {
                try body(buffer, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds))
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    }
}
