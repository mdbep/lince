// Compone una hoja con las propuestas de icono: swift scripts/icon-sheet.swift <carpeta> <salida.png>
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let count = 5
let cell: CGFloat = 300, big: CGFloat = 220
let size = NSSize(width: cell * CGFloat(count), height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
// Mitad clara y mitad oscura, para ver cada icono sobre ambos fondos del Dock.
NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 150, width: size.width, height: 250).fill()
NSColor(white: 0.13, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size.width, height: 150).fill()

for index in 1...count {
    let x = CGFloat(index - 1) * cell
    guard let icon = NSImage(contentsOf: dir.appendingPathComponent("icon-\(index).svg")) else { continue }
    icon.draw(in: NSRect(x: x + (cell - big) / 2, y: 165, width: big, height: big))
    icon.draw(in: NSRect(x: x + 40, y: 62, width: 64, height: 64))
    icon.draw(in: NSRect(x: x + 124, y: 78, width: 32, height: 32))
    icon.draw(in: NSRect(x: x + 176, y: 86, width: 16, height: 16))
    if let glyph = NSImage(contentsOf: dir.appendingPathComponent("menubar-\(index).svg")) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 214, y: 76, width: 44, height: 36), xRadius: 8, yRadius: 8).fill()
        glyph.draw(in: NSRect(x: x + 218, y: 76, width: 36, height: 36))
    }
    let label = NSAttributedString(string: "Propuesta \(index)", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
    label.draw(at: NSPoint(x: x + (cell - label.size().width) / 2, y: 20))
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
