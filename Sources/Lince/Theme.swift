import AppKit

enum Theme {
    /// El naranja del icono, usado como color de acento en toda la app.
    static let accent = NSColor(srgbRed: 0.96, green: 0.49, blue: 0.13, alpha: 1)
    static let canvas = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.086, alpha: 1)
    static let chrome = NSColor(srgbRed: 0.125, green: 0.128, blue: 0.14, alpha: 1)
    static let hairline = NSColor.white.withAlphaComponent(0.09)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Icono de la barra de menús: el visor con pupila de lince, como plantilla monocroma.
    static func menuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
           let glyph = NSImage(contentsOf: url) {
            glyph.size = NSSize(width: 18, height: 18)
            glyph.isTemplate = true
            return glyph
        }
        // Sin el recurso (p. ej. al ejecutar fuera del .app) se dibuja un visor sencillo.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            let inset = rect.insetBy(dx: 2.3, dy: 2.3)
            let arm: CGFloat = 4
            for (x, y, dx, dy) in [(inset.minX, inset.minY, 1.0, 1.0), (inset.maxX, inset.minY, -1.0, 1.0),
                                   (inset.minX, inset.maxY, 1.0, -1.0), (inset.maxX, inset.maxY, -1.0, -1.0)] {
                corners.move(to: CGPoint(x: x + arm * dx, y: y))
                corners.line(to: CGPoint(x: x, y: y))
                corners.line(to: CGPoint(x: x, y: y + arm * dy))
            }
            corners.stroke()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - 1.5, y: rect.midY - 3.6, width: 3, height: 7.2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

func withoutActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

func withLayerAnimation(_ duration: CFTimeInterval, _ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(Theme.reduceMotion ? 0 : duration)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    body()
    CATransaction.commit()
}

extension NSView {
    /// Transformación de escala respecto al centro (la capa de una vista ancla en la esquina).
    func centerScale(_ scale: CGFloat) -> CATransform3D {
        let w = bounds.width / 2, h = bounds.height / 2
        var transform = CATransform3DMakeTranslation(w, h, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -w, -h, 0)
    }

    func springScale(to scale: CGFloat, from start: CGFloat? = nil, stiffness: CGFloat = 420, damping: CGFloat = 22) {
        guard let layer else { return }
        let target = centerScale(scale)
        if Theme.reduceMotion {
            layer.transform = target
            return
        }
        let animation = CASpringAnimation(keyPath: "transform")
        if let start {
            animation.fromValue = centerScale(start)
        } else {
            animation.fromValue = layer.presentation()?.transform ?? layer.transform
        }
        animation.toValue = target
        animation.stiffness = stiffness
        animation.damping = damping
        animation.duration = animation.settlingDuration
        layer.transform = target
        layer.add(animation, forKey: "springScale")
    }
}

/// Botón con capa propia: resalta al pasar el ratón, se encoge al pulsar y puede quedar seleccionado.
class HoverButton: NSView {
    var onClick: (() -> Void)?

    var normalColor = NSColor.clear { didSet { refresh(animated: false) } }
    var hoverColor = NSColor.white.withAlphaComponent(0.1)
    var selectedColor = Theme.accent
    var normalTint = NSColor.white.withAlphaComponent(0.82) { didSet { refresh(animated: false) } }
    var hoverTint = NSColor.white
    var selectedTint = NSColor.white
    /// `nil` dibuja una cápsula.
    var cornerRadius: CGFloat? = 8 { didSet { needsLayout = true } }
    var isSelected = false { didSet { refresh(animated: true) } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.35 } }

    let background = CALayer()
    private let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    private(set) var isHovering = false

    init(symbol: String? = nil, title: String? = nil, symbolSize: CGFloat = 13,
         fontSize: CGFloat = 12, size: CGSize? = nil, tooltip: String? = nil,
         padding: CGFloat = 12, height: CGFloat = 28) {
        super.init(frame: .zero)
        wantsLayer = true
        background.cornerCurve = .continuous
        layer?.addSublayer(background)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip

        var views: [NSView] = []
        if let symbol {
            iconView.image = Theme.symbol(symbol, size: symbolSize)
            iconView.imageScaling = .scaleNone
            views.append(iconView)
        }
        if let title {
            titleLabel.stringValue = title
            titleLabel.font = .systemFont(ofSize: fontSize, weight: .medium)
            views.append(titleLabel)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let size {
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: size.width),
                heightAnchor.constraint(equalToConstant: size.height),
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
                heightAnchor.constraint(equalToConstant: height),
            ])
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no está soportado") }

    func setTitle(_ title: String) { titleLabel.stringValue = title }
    func setSymbol(_ name: String, size: CGFloat = 13) { iconView.image = Theme.symbol(name, size: size) }

    override func layout() {
        super.layout()
        withoutActions {
            background.frame = bounds
            background.cornerRadius = cornerRadius ?? bounds.height / 2
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refresh(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refresh(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        springScale(to: 0.92)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        springScale(to: 1, stiffness: 380, damping: 16)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    func refresh(animated: Bool) {
        let fill = isSelected ? selectedColor : (isHovering ? hoverColor : normalColor)
        let tint = isSelected ? selectedTint : (isHovering ? hoverTint : normalTint)
        let apply = {
            self.background.backgroundColor = fill.cgColor
        }
        if animated { withLayerAnimation(0.14, apply) } else { withoutActions(apply) }
        iconView.contentTintColor = tint
        titleLabel.textColor = tint
    }
}
