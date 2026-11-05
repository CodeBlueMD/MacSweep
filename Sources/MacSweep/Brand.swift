import AppKit

/// MacSweep's own mark: a sweeping crescent with two sparkles, drawn in code so the
/// menu bar glyph and the app icon always match.
enum Brand {
    /// Draws "MS" centred in `rect`, sized to fill its height, in the heavy rounded system font.
    static func drawMonogram(in rect: CGRect, color: NSColor, shadow: NSShadow? = nil) {
        let base = NSFont.systemFont(ofSize: rect.height, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: rect.height) } ?? base
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: -rect.height * 0.04]
        if let shadow { attrs[.shadow] = shadow }
        let text = NSAttributedString(string: "MS", attributes: attrs)
        let size = text.size()
        // Centre the capitals, not the line box. In an unflipped context the drawing point sits
        // one descender below the baseline.
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - font.capHeight / 2 + font.descender))
    }

    /// Template image for the menu bar: a small display with "MS" on its screen,
    /// so macOS tints it for light and dark menus.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: CGRect(x: 1.5, y: 5.5, width: 17, height: 11.5), xRadius: 2.5, yRadius: 2.5)
            screen.lineWidth = 1.6
            screen.stroke()
            NSBezierPath(roundedRect: CGRect(x: 8, y: 2.2, width: 4, height: 3.4), xRadius: 0.6, yRadius: 0.6).fill() // neck
            NSBezierPath(roundedRect: CGRect(x: 5.5, y: 0.8, width: 9, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill() // foot
            drawMonogram(in: CGRect(x: 1.5, y: 7.6, width: 17, height: 7.4), color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The app icon at `pixels` square: a desktop display with "MS" on a freshly wiped screen.
    static func iconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels) / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
        func shadowed(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
            sh.shadowBlurRadius = blur * s
            sh.shadowOffset = NSSize(width: 0, height: -dy * s)
            sh.set()
            draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        let aluminium = NSGradient(colors: [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.80, alpha: 1)])!

        // Stand: a tapered neck on a flat foot.
        let neck = NSBezierPath()
        neck.move(to: CGPoint(x: 430 * s, y: 330 * s))
        neck.line(to: CGPoint(x: 594 * s, y: 330 * s))
        neck.line(to: CGPoint(x: 624 * s, y: 170 * s))
        neck.line(to: CGPoint(x: 400 * s, y: 170 * s))
        neck.close()
        let foot = NSBezierPath(roundedRect: r(330, 140, 364, 44), xRadius: 22 * s, yRadius: 22 * s)
        shadowed(26, 12, 0.35) { NSColor(white: 0.85, alpha: 1).setFill(); foot.fill() }
        aluminium.draw(in: neck, angle: 0)
        aluminium.draw(in: foot, angle: -90)

        // Body: a coloured chin below a dark-bezelled screen.
        let bodyRect = r(96, 300, 832, 600)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 64 * s, yRadius: 64 * s)
        shadowed(30, 14, 0.4) { NSColor.black.setFill(); body.fill() }
        NSGradient(colors: [NSColor(red: 0.98, green: 0.52, blue: 0.80, alpha: 1),
                            NSColor(red: 0.62, green: 0.34, blue: 0.98, alpha: 1)])!.draw(in: body, angle: 0)
        let bezel = NSBezierPath(roundedRect: r(96, 420, 832, 480), xRadius: 64 * s, yRadius: 64 * s)
        bezel.append(NSBezierPath(rect: r(96, 420, 832, 70))) // square off the bottom corners where the chin joins
        NSColor(red: 0.08, green: 0.06, blue: 0.16, alpha: 1).setFill()
        bezel.fill()

        // Screen with a deep gradient and a soft glow behind the mark.
        let screenRect = r(130, 452, 764, 414)
        let screen = NSBezierPath(roundedRect: screenRect, xRadius: 30 * s, yRadius: 30 * s)
        NSGradient(colors: [NSColor(red: 0.42, green: 0.22, blue: 0.92, alpha: 1),
                            NSColor(red: 0.10, green: 0.22, blue: 0.70, alpha: 1)])!.draw(in: screen, angle: -70)
        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        NSGradient(colors: [NSColor(red: 1, green: 0.75, blue: 1, alpha: 0.55), NSColor(red: 1, green: 0.75, blue: 1, alpha: 0)])!
            .draw(fromCenter: CGPoint(x: 512 * s, y: 659 * s), radius: 0,
                  toCenter: CGPoint(x: 512 * s, y: 659 * s), radius: 300 * s, options: [])
        NSGraphicsContext.restoreGraphicsState()

        // A wiped-clean streak: a crisp-edged band of brighter glass running corner to corner.
        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        let streak = NSBezierPath()
        streak.move(to: CGPoint(x: 250 * s, y: 452 * s))
        streak.line(to: CGPoint(x: 470 * s, y: 452 * s))
        streak.line(to: CGPoint(x: 820 * s, y: 866 * s))
        streak.line(to: CGPoint(x: 600 * s, y: 866 * s))
        streak.close()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0.04)])!.draw(in: streak, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        let letterShadow = NSShadow()
        letterShadow.shadowColor = NSColor(red: 0.10, green: 0.02, blue: 0.30, alpha: 0.5)
        letterShadow.shadowBlurRadius = 20 * s
        letterShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        drawMonogram(in: r(130, 540, 764, 238), color: .white, shadow: letterShadow)

        // Glass highlight across the upper screen.
        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        let glare = NSBezierPath()
        glare.move(to: CGPoint(x: 130 * s, y: 866 * s))
        glare.line(to: CGPoint(x: 560 * s, y: 866 * s))
        glare.line(to: CGPoint(x: 130 * s, y: 600 * s))
        glare.close()
        NSColor.white.withAlphaComponent(0.08).setFill()
        glare.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes a complete `.iconset` folder for `iconutil`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try iconPNG(pixels: points * scale)?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
