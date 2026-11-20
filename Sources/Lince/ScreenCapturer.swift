import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main ?? screens[0]
    }

    /// La pantalla que contiene la mayor parte del rectángulo (coordenadas globales).
    static func containing(_ rect: CGRect) -> NSScreen {
        screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        } ?? underMouse
    }
}

struct ScreenShot {
    let image: CGImage
    let screen: NSScreen
    let scale: CGFloat
}

/// Una ventana de otra app que se puede capturar entera.
struct WindowInfo {
    let id: CGWindowID
    /// Marco en coordenadas globales de AppKit (origen abajo a la izquierda).
    let frame: CGRect
    let appName: String
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captura las pantallas indicadas a resolución nativa, sin cursor y sin las ventanas de Lince.
    @MainActor
    static func capture(screens: [NSScreen]) async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hideIcons = Settings.hidesDesktopIcons
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        // Fuera las ventanas propias y, si se pide, los iconos del escritorio (son ventanas del Finder).
        let excluded = content.windows.filter { window in
            if window.owningApplication?.processID == ownPID { return true }
            return hideIcons && window.windowLayer == iconLevel
                && window.owningApplication?.bundleIdentifier == "com.apple.finder"
        }

        var shots: [ScreenShot] = []
        for screen in screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(image: image, screen: screen, scale: scale))
        }
        return shots
    }

    /// Captura en vivo un rectángulo (coordenadas globales) de una pantalla.
    @MainActor
    static func captureArea(_ rect: CGRect, on screen: NSScreen) async throws -> ScreenShot? {
        guard let shot = try await capture(screens: [screen]).first else { return nil }
        return crop(shot, to: rect)
    }

    static func crop(_ shot: ScreenShot, to globalRect: CGRect) -> ScreenShot? {
        let frame = shot.screen.frame
        let local = globalRect.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
        guard local.width >= 1, local.height >= 1 else { return nil }
        let factor = CGFloat(shot.image.width) / frame.width
        let pixels = CGRect(x: local.minX * factor, y: (frame.height - local.maxY) * factor,
                            width: local.width * factor, height: local.height * factor).integral
        guard let cropped = shot.image.cropping(to: pixels) else { return nil }
        return ScreenShot(image: cropped, screen: shot.screen, scale: shot.scale)
    }

    /// Ventanas normales en pantalla, de delante hacia atrás. No necesita capturar nada.
    static func windowList() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[CFString: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { entry in
            guard (entry[kCGWindowLayer] as? Int) == 0,
                  (entry[kCGWindowOwnerPID] as? pid_t) != ownPID,
                  (entry[kCGWindowAlpha] as? Double ?? 1) > 0.05,
                  let id = entry[kCGWindowNumber] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80, bounds.height >= 50 else { return nil }
            // Quartz mide desde arriba; AppKit, desde abajo.
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                               width: bounds.width, height: bounds.height)
            return WindowInfo(id: id, frame: frame, appName: entry[kCGWindowOwnerName] as? String ?? "")
        }
    }

    /// Captura una ventana completa con sus esquinas transparentes, aunque esté tapada.
    @MainActor
    static func captureWindow(_ info: WindowInfo) async throws -> ScreenShot? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == info.id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenShot(image: image, screen: NSScreen.containing(info.frame), scale: scale)
    }
}
