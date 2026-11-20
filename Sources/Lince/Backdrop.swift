import AppKit

struct BackdropStyle {
    let name: String
    /// Colores repartidos de la esquina superior izquierda a la inferior derecha; uno solo es un color liso.
    let colors: [NSColor]

    var cgColors: [CGColor] {
        let list = colors.count == 1 ? [colors[0], colors[0]] : colors
        return list.map(\.cgColor)
    }
}

struct BackdropChoice: Equatable {
    static let paddingRange: ClosedRange<CGFloat> = 0.02...0.2
    static let radiusRange: ClosedRange<CGFloat> = 0...40

    var style: Int
    /// Degradado generado a partir de la captura; si existe, sustituye a `style`.
    var auto: [NSColor]?
    /// Margen alrededor de la captura, como fracción de su tamaño medio.
    var padding: CGFloat = 0.08
    /// Radio de las esquinas de la captura, en puntos.
    var radius: CGFloat = 10
    /// Intensidad de la sombra, de 0 a 1.
    var shadow: CGFloat = 0.65

    var shadowOpacity: CGFloat { min(max(shadow, 0), 1) * 0.6 }
}

/// Fondos para presentar una captura, y la sombra de las capturas de ventana.
enum Backdrop {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    private static func style(_ name: String, _ colors: NSColor...) -> BackdropStyle {
        BackdropStyle(name: name, colors: colors)
    }

    static let styles: [BackdropStyle] = [
        style("Lince", rgb(255, 170, 84), rgb(232, 76, 61)),
        style("Amanecer", rgb(255, 214, 102), rgb(255, 140, 92), rgb(246, 84, 140)),
        style("Melocotón", rgb(255, 220, 186), rgb(255, 142, 150)),
        style("Rosa", rgb(255, 158, 204), rgb(212, 66, 138)),
        style("Atardecer", rgb(255, 128, 140), rgb(140, 82, 220)),
        style("Uva", rgb(168, 120, 255), rgb(66, 44, 150)),
        style("Aurora", rgb(96, 226, 192), rgb(82, 142, 255), rgb(164, 92, 242)),
        style("Océano", rgb(64, 186, 255), rgb(52, 84, 209)),
        style("Cielo", rgb(176, 228, 255), rgb(92, 150, 250)),
        style("Menta", rgb(120, 230, 180), rgb(28, 152, 168)),
        style("Bosque", rgb(152, 212, 112), rgb(22, 108, 84)),
        style("Medianoche", rgb(46, 58, 124), rgb(12, 14, 36)),
        style("Grafito", rgb(72, 78, 92), rgb(24, 26, 32)),
        style("Niebla", rgb(244, 246, 250), rgb(206, 212, 224)),
        style("Blanco", rgb(255, 255, 255)),
        style("Negro", rgb(0, 0, 0)),
    ]

    static func colors(for choice: BackdropChoice) -> [CGColor] {
        if let auto = choice.auto, !auto.isEmpty {
            return (auto.count == 1 ? [auto[0], auto[0]] : auto).map(\.cgColor)
        }
        return styles[min(max(choice.style, 0), styles.count - 1)].cgColors
    }

    /// El tono más presente en una imagen, con su saturación media, y la luminosidad general.
    /// `hue` es `nil` cuando la imagen apenas tiene color.
    private static func dominantColor(of image: CGImage) -> (hue: CGFloat?, saturation: CGFloat, luminance: CGFloat) {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (nil, 0, 0.5)
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Histograma de tonos, ponderado por lo vivo que es cada píxel.
        let bins = 24
        var weights = [CGFloat](repeating: 0, count: bins)
        var saturations = [CGFloat](repeating: 0, count: bins)
        var luminance: CGFloat = 0, counted: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let r = CGFloat(pixels[index]) / 255, g = CGFloat(pixels[index + 1]) / 255, b = CGFloat(pixels[index + 2]) / 255
            let top = max(r, g, b), bottom = min(r, g, b), delta = top - bottom
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
            counted += 1
            guard delta > 0.12, top > 0.2 else { continue }
            var hue: CGFloat
            if top == r { hue = (g - b) / delta } else if top == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let saturation = delta / top
            let weight = saturation * top
            let bin = min(bins - 1, Int(hue * CGFloat(bins)))
            weights[bin] += weight
            saturations[bin] += saturation * weight
        }
        let brightness = counted > 0 ? luminance / counted : 0.5
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] > counted * 0.012 else { return (nil, 0, brightness) }
        return ((CGFloat(best) + 0.5) / CGFloat(bins), saturations[best] / weights[best], brightness)
    }

    private static func wrap(_ value: CGFloat) -> CGFloat { value - floor(value) }

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> NSColor {
        let color = NSColor(hue: wrap(hue), saturation: saturation, brightness: brightness, alpha: 1)
        return color.usingColorSpace(.sRGB) ?? color
    }

    /// Un degradado a juego con la captura: parte de su color más vivo y lo abre hacia un tono vecino.
    /// Si la captura apenas tiene color, se queda en un gris que contrasta con ella.
    static func autoColors(for image: CGImage) -> [NSColor] {
        let dominant = dominantColor(of: image)
        guard let hue = dominant.hue else {
            return dominant.luminance < 0.5
                ? [rgb(236, 239, 245), rgb(188, 196, 212)]
                : [rgb(84, 92, 110), rgb(30, 33, 42)]
        }
        let saturation = min(0.82, max(0.5, dominant.saturation))
        return [hsb(hue - 0.05, saturation * 0.78, 0.98), hsb(hue + 0.07, min(0.9, saturation + 0.08), 0.66)]
    }

    /// Dos colores para anotar: uno que combina con la captura y su complementario, que destaca sobre ella.
    /// Vacío si la captura no tiene un color dominante.
    static func suggestedColors(for image: CGImage) -> [NSColor] {
        guard let hue = dominantColor(of: image).hue else { return [] }
        return [hsb(hue, 0.78, 0.95), hsb(hue + 0.5, 0.82, 0.95)]
    }

    /// Margen en píxeles alrededor de la imagen.
    static func padding(for size: CGSize, fraction: CGFloat) -> CGFloat {
        let range = BackdropChoice.paddingRange
        return ((size.width + size.height) / 2 * min(max(fraction, range.lowerBound), range.upperBound)).rounded()
    }

    static func shadowBlur(unit: CGFloat) -> CGFloat { 36 * unit }
    static func shadowOffset(unit: CGFloat) -> CGFloat { -12 * unit }

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: info)
    }

    /// Coloca la imagen sobre un fondo, con el margen, las esquinas y la sombra elegidos.
    /// Si la imagen ya trae transparencia (una ventana con su sombra), se respeta tal cual.
    static func compose(_ image: CGImage, choice: BackdropChoice, unit: CGFloat, hasTransparency: Bool) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let pad = padding(for: size, fraction: choice.padding)
        let width = image.width + Int(pad) * 2, height = image.height + Int(pad) * 2
        guard let context = makeContext(width: width, height: height, like: image),
              let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colors(for: choice) as CFArray,
                                        locations: nil) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let rect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        if hasTransparency {
            context.draw(image, in: rect)
            return context.makeImage()
        }
        let radius = min(max(choice.radius, 0) * unit, min(size.width, size.height) / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if choice.shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadowOffset(unit: unit)), blur: shadowBlur(unit: unit),
                              color: NSColor.black.withAlphaComponent(choice.shadowOpacity).cgColor)
            context.addPath(shape)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }
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
    static let size = CGSize(width: 44, height: 34)

    var onClick: (() -> Void)?
    var isSelected = false { didSet { refresh() } }
    private let fill = CAGradientLayer()
    private let ring = CALayer()

    /// Muestra del fondo automático: el degradado calculado para esta captura, con una varita.
    convenience init(auto colors: [NSColor]) {
        self.init(style: BackdropStyle(name: "Automático, a juego con la captura", colors: colors))
        addIcon("wand.and.stars", tint: .white)
    }

    private func addIcon(_ symbol: String, tint: NSColor) {
        let icon = NSImageView()
        icon.image = Theme.symbol(symbol, size: 12, weight: .semibold)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            return shadow
        }()
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `style == nil` es la opción "sin fondo".
    init(style: BackdropStyle?) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        toolTip = style?.name ?? "Sin fondo"
        fill.cornerRadius = 6
        fill.cornerCurve = .continuous
        fill.startPoint = CGPoint(x: 0, y: 1)
        fill.endPoint = CGPoint(x: 1, y: 0)
        fill.borderWidth = 0.5
        fill.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        if let style {
            fill.colors = style.cgColors
        } else {
            let gray = NSColor(white: 1, alpha: 0.08).cgColor
            fill.colors = [gray, gray]
            addIcon("circle.slash", tint: NSColor.white.withAlphaComponent(0.55))
        }
        ring.cornerRadius = 9
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        ring.borderColor = Theme.accent.cgColor
        ring.opacity = 0
        layer?.addSublayer(ring)
        layer?.insertSublayer(fill, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    override func layout() {
        super.layout()
        withoutActions {
            ring.frame = bounds
            fill.frame = bounds.insetBy(dx: 3.5, dy: 3.5)
        }
    }

    private func refresh() {
        withLayerAnimation(0.15) { ring.opacity = isSelected ? 1 : 0 }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { springScale(to: 0.9) }
    override func mouseUp(with event: NSEvent) {
        springScale(to: 1, stiffness: 380, damping: 14)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Una fila del selector: etiqueta, deslizador y su valor.
final class BackdropSlider: NSView {
    var onChange: ((CGFloat) -> Void)?
    var isEnabled = true {
        didSet {
            slider.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.35
        }
    }
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (CGFloat) -> String

    var value: CGFloat { CGFloat(slider.doubleValue) }

    init(title: String, range: ClosedRange<CGFloat>, value: CGFloat, format: @escaping (CGFloat) -> String) {
        self.format = format
        slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound),
                          target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.78)

        slider.controlSize = .small
        slider.isContinuous = true
        slider.trackFillColor = Theme.accent
        slider.target = self
        slider.action = #selector(changed)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        valueLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        valueLabel.alignment = .right
        valueLabel.stringValue = format(value)

        for view in [label, slider, valueLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 64),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    @objc private func changed() {
        valueLabel.stringValue = format(value)
        onChange?(value)
    }
}

/// Contenido del selector de fondo: muestras, margen, esquinas y sombra.
final class BackdropPanel: NSView {
    /// Se llama con cada cambio; `nil` es "sin fondo".
    var onChange: ((BackdropChoice?) -> Void)?

    private var options: BackdropChoice
    private var isOn: Bool
    private let ownsShape: Bool
    private let autoColors: [NSColor]
    private var swatches: [BackdropSwatch] = []
    private let nameLabel = NSTextField(labelWithString: "")
    private var paddingSlider: BackdropSlider!
    private var radiusSlider: BackdropSlider!
    private var shadowSlider: BackdropSlider!

    private static let inset: CGFloat = 16
    private static let gap: CGFloat = 6
    private static let columns = 6

    /// `ownsShape`: la captura ya trae sus esquinas y su sombra (una ventana), así que no se ajustan.
    init(current: BackdropChoice?, options: BackdropChoice, ownsShape: Bool, autoColors: [NSColor]) {
        self.autoColors = autoColors
        self.options = current ?? options
        self.isOn = current != nil
        self.ownsShape = ownsShape
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "Fondo")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        nameLabel.alignment = .right
        let header = NSStackView(views: [title, NSView(), nameLabel])
        header.orientation = .horizontal

        // Sin fondo, automático y después los estilos fijos.
        swatches = [BackdropSwatch(style: nil), BackdropSwatch(auto: autoColors)]
            + Backdrop.styles.map { BackdropSwatch(style: $0) }
        for (index, swatch) in swatches.enumerated() {
            swatch.onClick = { [weak self] in
                switch index {
                case 0: self?.select(nil)
                case 1: self?.selectAuto()
                default: self?.select(index - 2)
                }
            }
        }
        let rows = stride(from: 0, to: swatches.count, by: Self.columns).map { start -> NSStackView in
            let row = NSStackView(views: Array(swatches[start..<min(start + Self.columns, swatches.count)]))
            row.orientation = .horizontal
            row.spacing = Self.gap
            return row
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = Self.gap

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.hairline.cgColor

        paddingSlider = BackdropSlider(title: "Margen", range: BackdropChoice.paddingRange,
                                       value: self.options.padding) { "\(Int(($0 * 100).rounded())) %" }
        radiusSlider = BackdropSlider(title: "Esquinas", range: BackdropChoice.radiusRange,
                                      value: self.options.radius) { "\(Int($0.rounded())) pt" }
        shadowSlider = BackdropSlider(title: "Sombra", range: 0...1,
                                      value: self.options.shadow) { "\(Int(($0 * 100).rounded())) %" }
        paddingSlider.onChange = { [weak self] in self?.options.padding = $0; self?.notify() }
        radiusSlider.onChange = { [weak self] in self?.options.radius = $0.rounded(); self?.notify() }
        shadowSlider.onChange = { [weak self] in self?.options.shadow = $0; self?.notify() }
        if ownsShape {
            let reason = "La ventana ya trae sus esquinas y su sombra"
            radiusSlider.toolTip = reason
            shadowSlider.toolTip = reason
        }
        let sliders = NSStackView(views: [paddingSlider, radiusSlider, shadowSlider])
        sliders.orientation = .vertical
        sliders.spacing = 8

        let width = CGFloat(Self.columns) * BackdropSwatch.size.width + CGFloat(Self.columns - 1) * Self.gap
        let stack = NSStackView(views: [header, grid, separator, sliders])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(12, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            stack.widthAnchor.constraint(equalToConstant: width),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            sliders.widthAnchor.constraint(equalTo: stack.widthAnchor),
            paddingSlider.widthAnchor.constraint(equalTo: sliders.widthAnchor),
            radiusSlider.widthAnchor.constraint(equalTo: sliders.widthAnchor),
            shadowSlider.widthAnchor.constraint(equalTo: sliders.widthAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    private func selectAuto() {
        options.auto = autoColors
        isOn = true
        refresh()
        notify()
    }

    private func select(_ style: Int?) {
        if let style {
            options.style = style
            options.auto = nil
        }
        isOn = style != nil
        refresh()
        notify()
    }

    private func notify() { onChange?(isOn ? options : nil) }

    private func refresh() {
        let selected = !isOn ? 0 : (options.auto != nil ? 1 : options.style + 2)
        for (index, swatch) in swatches.enumerated() { swatch.isSelected = index == selected }
        nameLabel.stringValue = !isOn ? "Sin fondo" : (options.auto != nil ? "Automático" : Backdrop.styles[options.style].name)
        paddingSlider.isEnabled = isOn
        radiusSlider.isEnabled = isOn && !ownsShape
        shadowSlider.isEnabled = isOn && !ownsShape
    }
}
