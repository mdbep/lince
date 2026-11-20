import AppKit

struct BackdropStyle {
    let name: String
    /// Color de la esquina superior izquierda y de la inferior derecha.
    let start: NSColor
    let end: NSColor

    var cgColors: [CGColor] { [start.cgColor, end.cgColor] }
}

struct BackdropChoice: Equatable {
    var style: Int
    /// 0 pequeño, 1 medio, 2 grande.
    var padding: Int
}

/// Fondos degradados para presentar una captura, y la sombra de las capturas de ventana.
enum Backdrop {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let styles: [BackdropStyle] = [
        BackdropStyle(name: "Lince", start: rgb(255, 170, 84), end: rgb(232, 76, 61)),
        BackdropStyle(name: "Atardecer", start: rgb(255, 128, 140), end: rgb(140, 82, 220)),
        BackdropStyle(name: "Océano", start: rgb(64, 186, 255), end: rgb(52, 84, 209)),
        BackdropStyle(name: "Menta", start: rgb(120, 230, 180), end: rgb(28, 152, 168)),
        BackdropStyle(name: "Uva", start: rgb(168, 120, 255), end: rgb(66, 44, 150)),
        BackdropStyle(name: "Niebla", start: rgb(244, 246, 250), end: rgb(206, 212, 224)),
        BackdropStyle(name: "Grafito", start: rgb(72, 78, 92), end: rgb(24, 26, 32)),
    ]

    private static let paddingFractions: [CGFloat] = [0.045, 0.08, 0.13]

    /// Margen en píxeles alrededor de la imagen.
    static func padding(for size: CGSize, level: Int) -> CGFloat {
        let fraction = paddingFractions[min(max(level, 0), paddingFractions.count - 1)]
        return ((size.width + size.height) / 2 * fraction).rounded()
    }

    static func cornerRadius(unit: CGFloat) -> CGFloat { 10 * unit }
    static func shadowBlur(unit: CGFloat) -> CGFloat { 36 * unit }
    static func shadowOffset(unit: CGFloat) -> CGFloat { -12 * unit }
    static let shadowOpacity: CGFloat = 0.38

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: info)
    }

    /// Coloca la imagen sobre un degradado, con esquinas redondeadas y sombra.
    /// Si la imagen ya trae transparencia (una ventana con su sombra), se respeta tal cual.
    static func compose(_ image: CGImage, choice: BackdropChoice, unit: CGFloat, hasTransparency: Bool) -> CGImage? {
        let style = styles[min(max(choice.style, 0), styles.count - 1)]
        let size = CGSize(width: image.width, height: image.height)
        let pad = padding(for: size, level: choice.padding)
        let width = image.width + Int(pad) * 2, height = image.height + Int(pad) * 2
        guard let context = makeContext(width: width, height: height, like: image),
              let gradient = CGGradient(colorsSpace: context.colorSpace, colors: style.cgColors as CFArray,
                                        locations: [0, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let rect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        if hasTransparency {
            context.draw(image, in: rect)
            return context.makeImage()
        }
        let radius = min(cornerRadius(unit: unit), min(size.width, size.height) / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: shadowOffset(unit: unit)), blur: shadowBlur(unit: unit),
                          color: NSColor.black.withAlphaComponent(shadowOpacity).cgColor)
        context.addPath(shape)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
        context.addPath(shape)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Añade a una ventana capturada (con esquinas transparentes) una sombra como la del sistema.
    static func addWindowShadow(to image: CGImage, unit: CGFloat) -> CGImage? {
        let margin = Int((56 * unit).rounded())
        let width = image.width + margin * 2, height = image.height + margin * 2
        guard let context = makeContext(width: width, height: height, like: image) else { return nil }
        context.setShadow(offset: CGSize(width: 0, height: -18 * unit), blur: 44 * unit,
                          color: NSColor.black.withAlphaComponent(0.42).cgColor)
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// Muestra de un fondo en el selector del editor.
final class BackdropSwatch: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { refresh() } }
    private let fill = CAGradientLayer()
    private let ring = CALayer()

    /// `style == nil` es la opción "sin fondo".
    init(style: BackdropStyle?) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 46),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        toolTip = style?.name ?? "Sin fondo"
        fill.cornerRadius = 7
        fill.cornerCurve = .continuous
        fill.startPoint = CGPoint(x: 0, y: 1)
        fill.endPoint = CGPoint(x: 1, y: 0)
        fill.borderWidth = 0.5
        fill.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        if let style {
            fill.colors = style.cgColors
        } else {
            fill.colors = [NSColor(white: 0.2, alpha: 1).cgColor, NSColor(white: 0.2, alpha: 1).cgColor]
            let icon = NSImageView()
            icon.image = Theme.symbol("circle.slash", size: 13, weight: .medium)
            icon.contentTintColor = NSColor.white.withAlphaComponent(0.6)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        ring.cornerRadius = 10
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        ring.borderColor = Theme.accent.cgColor
        layer?.addSublayer(ring)
        layer?.insertSublayer(fill, at: 0)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    override func layout() {
        super.layout()
        withoutActions {
            ring.frame = bounds
            fill.frame = bounds.insetBy(dx: 4, dy: 4)
        }
    }

    private func refresh() {
        withLayerAnimation(0.15) { ring.opacity = isSelected ? 1 : 0 }
    }

    override func mouseDown(with event: NSEvent) { springScale(to: 0.9) }
    override func mouseUp(with event: NSEvent) {
        springScale(to: 1, stiffness: 380, damping: 14)
        onClick?()
    }
}
