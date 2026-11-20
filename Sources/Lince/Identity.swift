import AppKit

/// El sonido de captura: el propio de Lince, el de macOS o ninguno.
enum ShutterSound: String, CaseIterable {
    case lince, system, none

    var label: String {
        switch self {
        case .lince: return "Lince"
        case .system: return "macOS"
        case .none: return "Ninguno"
        }
    }
}

enum Shutter {
    private static let systemPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
    private static var cache: [ShutterSound: NSSound] = [:]

    static func play(_ kind: ShutterSound = Settings.shutterSound) {
        guard kind != .none else { return }
        let sound: NSSound?
        if let cached = cache[kind] {
            sound = cached
        } else {
            sound = kind == .system ? NSSound(contentsOfFile: systemPath, byReference: true) : NSSound(data: linceWAV())
            cache[kind] = sound
        }
        sound?.stop()
        sound?.play()
    }

    /// Dos chasquidos secos y breves, como un obturador de láminas, sobre un golpe grave muy corto.
    /// Se sintetiza al vuelo: no hay ningún archivo de audio en la app.
    static func linceWAV() -> Data {
        let rate = 44_100.0
        let count = Int(rate * 0.2)
        var samples = [Double](repeating: 0, count: count)
        var seed: UInt32 = 0x4C49_4E43
        func noise() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed >> 8) / Double(1 << 23) - 1
        }
        func click(at start: Double, gain: Double, tone: Double) {
            let first = Int(start * rate)
            var previous = 0.0
            for index in 0..<Int(rate * 0.05) where first + index < count {
                let t = Double(index) / rate
                // El ruido se deriva para quitarle graves y que suene a chasquido, no a soplido.
                let raw = noise()
                let crisp = raw - previous * 0.86
                previous = raw
                let body = crisp * exp(-t / 0.0035) * 0.55
                let ring = sin(2 * .pi * tone * t) * exp(-t / 0.007) * 0.3
                samples[first + index] += (body + ring) * gain
            }
        }
        click(at: 0.004, gain: 1, tone: 2_300)
        click(at: 0.072, gain: 0.62, tone: 1_750)
        for index in 0..<count {
            let t = Double(index) / rate
            samples[index] += sin(2 * .pi * 165 * t) * exp(-t / 0.028) * 0.22
        }
        let peak = max(samples.map(abs).max() ?? 1, 0.001)
        let pcm = samples.map { Int16(max(-1, min(1, $0 / peak * 0.5)) * Double(Int16.max)) }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        pcm.forEach { append($0) }
        return data
    }
}

extension NSStatusItem {
    /// El icono de la barra de menús parpadea como un ojo al hacer una captura.
    func blink() {
        guard !Theme.reduceMotion, let button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let half = button.bounds.height / 2
        func squash(_ scale: CGFloat) -> CATransform3D {
            var transform = CATransform3DMakeTranslation(0, half, 0)
            transform = CATransform3DScale(transform, 1, scale, 1)
            return CATransform3DTranslate(transform, 0, -half, 0)
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [squash(1), squash(0.1), squash(1)]
        animation.keyTimes = [0, 0.42, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        animation.duration = 0.26
        layer.add(animation, forKey: "blink")
    }
}
