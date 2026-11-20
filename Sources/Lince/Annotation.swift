import AppKit

enum EditorTool: Int, CaseIterable {
    case select, arrow, rectangle, ellipse, line, pen, highlighter, text, counter, pixelate

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        }
    }

    var label: String {
        switch self {
        case .select: return "Seleccionar"
        case .arrow: return "Flecha"
        case .rectangle: return "Rectángulo"
        case .ellipse: return "Elipse"
        case .line: return "Línea"
        case .pen: return "Lápiz"
        case .highlighter: return "Resaltador"
        case .text: return "Texto"
        case .counter: return "Numeración"
        case .pixelate: return "Pixelar"
        }
    }

    /// Tecla (sin modificadores) que selecciona la herramienta.
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "b"
        }
    }

    var isFreehand: Bool { self == .pen || self == .highlighter }
    /// Formas definidas por dos puntos, que se pueden redimensionar con tiradores.
    var isTwoPoint: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .line, .pixelate: return true
        default: return false
        }
    }
}

/// Una anotación en coordenadas de píxel de la imagen (origen abajo a la izquierda).
struct Annotation {
    var tool: EditorTool
    var points: [CGPoint]
    var color: NSColor
    /// Grosor del trazo en píxeles de imagen.
    var width: CGFloat
    /// Píxeles por punto de la captura: escala sombras, cabezas de flecha, etc.
    var unit: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 0
    /// Resultado ya pixelado, para no recalcularlo en cada repintado.
    var cache: CGImage?

    var frame: CGRect {
        guard let first = points.first else { return .zero }
        let last = points.last ?? first
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    var counterRadius: CGFloat { max(11 * unit, width * 3.2) }

    private var textSize: CGSize {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
    }

    /// Caja que envuelve la anotación, en píxeles de imagen.
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        switch tool {
        case .text:
            return CGRect(origin: first, size: textSize)
        case .counter:
            let r = counterRadius
            return CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)
        case .pen, .highlighter:
            var box = CGRect(origin: first, size: .zero)
            for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
            let pad = (tool == .highlighter ? width * 2.5 : width / 2)
            return box.insetBy(dx: -pad, dy: -pad)
        default:
            return frame
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard let first = points.first else { return false }
        let last = points.last ?? first
        switch tool {
        case .select:
            return false
        case .arrow, .line:
            let reach = tolerance + (tool == .arrow ? width * 1.5 : width / 2)
            return Annotation.distance(point, toSegment: first, last) <= reach
        case .rectangle:
            let outer = frame.insetBy(dx: -tolerance - width / 2, dy: -tolerance - width / 2)
            let inner = frame.insetBy(dx: tolerance + width / 2, dy: tolerance + width / 2)
            return outer.contains(point) && (inner.isNull || !inner.contains(point))
        case .ellipse:
            let rx = frame.width / 2, ry = frame.height / 2
            guard rx > 0, ry > 0 else { return false }
            let nx = (point.x - frame.midX) / rx, ny = (point.y - frame.midY) / ry
            return abs(sqrt(nx * nx + ny * ny) - 1) * min(rx, ry) <= tolerance + width
        case .pixelate:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .pen, .highlighter:
            let reach = tolerance + (tool == .highlighter ? width * 2.5 : width / 2)
            if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= reach }
            for index in 1..<points.count
            where Annotation.distance(point, toSegment: points[index - 1], points[index]) <= reach {
                return true
            }
            return false
        case .text, .counter:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        for index in points.indices {
            points[index].x += dx
            points[index].y += dy
        }
        cache = nil
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    func draw(in context: CGContext, base: CGImage?) {
        guard let first = points.first else { return }
        let last = points.last ?? first
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(width)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        if tool != .highlighter && tool != .pixelate {
            // Una sombra suave separa la anotación de cualquier fondo.
            context.setShadow(offset: CGSize(width: 0, height: -1 * unit), blur: 3.5 * unit,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }

        switch tool {
        case .select:
            break
        case .arrow:
            drawArrow(from: first, to: last, in: context)
        case .rectangle:
            let radius = min(width * 1.2, min(frame.width, frame.height) / 2)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .ellipse:
            context.strokeEllipse(in: frame)
        case .line:
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
        case .pen, .highlighter:
            if tool == .highlighter {
                context.setLineCap(.butt)
                context.setLineWidth(width * 5)
                context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            }
            addSmoothedPath(to: context)
            context.strokePath()
        case .text:
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
            ])
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            attributed.draw(at: first)
            NSGraphicsContext.current = previous
        case .counter:
            drawCounter(at: first, in: context)
        case .pixelate:
            let image = cache ?? base.flatMap { Annotation.pixelated($0, rect: frame, block: 9 * unit) }
            guard let image else { return }
            context.interpolationQuality = .none
            context.draw(image, in: Annotation.pixelRect(frame, in: base))
        }
    }

    /// Flecha afilada: cola fina que engorda hasta la cabeza.
    private func drawArrow(from tail: CGPoint, to tip: CGPoint, in context: CGContext) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let head = min(max(width * 4.6, 12 * unit), length * 0.55)
        let headHalf = head * 0.48
        let shaftHalf = width * 0.55
        let tailHalf = width * 0.16
        let neck = CGPoint(x: tip.x - ux * head * 0.82, y: tip.y - uy * head * 0.82)
        let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)

        func offset(_ point: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + nx * amount, y: point.y + ny * amount)
        }
        let path = CGMutablePath()
        path.move(to: offset(tail, tailHalf))
        path.addLine(to: offset(neck, shaftHalf))
        path.addLine(to: offset(base, headHalf))
        path.addLine(to: tip)
        path.addLine(to: offset(base, -headHalf))
        path.addLine(to: offset(neck, -shaftHalf))
        path.addLine(to: offset(tail, -tailHalf))
        path.closeSubpath()
        context.setLineWidth(width * 0.35)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
    }

    private func drawCounter(at center: CGPoint, in context: CGContext) {
        let radius = counterRadius
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(max(1.5 * unit, radius * 0.13))
        context.strokeEllipse(in: circle.insetBy(dx: radius * 0.06, dy: radius * 0.06))

        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold),
            .foregroundColor: luminance > 0.72 ? NSColor.black : NSColor.white,
        ])
        let size = attributed.size()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        NSGraphicsContext.current = previous
    }

    /// Suaviza el trazo a mano alzada uniendo los puntos medios con curvas.
    private func addSmoothedPath(to context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        guard points.count > 2 else {
            context.addLine(to: points.last ?? first)
            return
        }
        for index in 1..<points.count - 1 {
            let current = points[index], next = points[index + 1]
            context.addQuadCurve(to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2),
                                 control: current)
        }
        context.addLine(to: points[points.count - 1])
    }

    // MARK: - Pixelado

    static func pixelRect(_ rect: CGRect, in base: CGImage?) -> CGRect {
        guard let base else { return rect.integral }
        return rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
    }

    static func pixelated(_ base: CGImage, rect: CGRect, block: CGFloat) -> CGImage? {
        let area = pixelRect(rect, in: base)
        guard area.width >= 1, area.height >= 1 else { return nil }
        let crop = CGRect(x: area.minX, y: CGFloat(base.height) - area.maxY, width: area.width, height: area.height)
        guard let piece = base.cropping(to: crop) else { return nil }
        let columns = max(1, Int((area.width / block).rounded(.up)))
        let rows = max(1, Int((area.height / block).rounded(.up)))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .medium
        context.draw(piece, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return context.makeImage()
    }
}
