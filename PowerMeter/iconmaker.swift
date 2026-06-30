import AppKit
import UniformTypeIdentifiers

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// rounded-rect (squircle-ish) background with green gradient
let inset: CGFloat = 64
let rect = CGRect(x: inset, y: inset, width: CGFloat(S) - 2*inset, height: CGFloat(S) - 2*inset)
let bg = CGPath(roundedRect: rect, cornerWidth: 205, cornerHeight: 205, transform: nil)
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let colors = [CGColor(red: 0.22, green: 0.80, blue: 0.38, alpha: 1),
              CGColor(red: 0.08, green: 0.50, blue: 0.30, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// white bolt (SF Symbol) tinted, centered
let cfg = NSImage.SymbolConfiguration(pointSize: 540, weight: .bold)
if let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: base.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r0 = NSRect(origin: .zero, size: base.size)
    base.draw(in: r0)
    r0.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsctx
    let target: CGFloat = 470
    let scale = target / tinted.size.height
    let w = tinted.size.width * scale, h = tinted.size.height * scale
    // shadow for depth
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
    sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    tinted.draw(in: NSRect(x: (CGFloat(S)-w)/2, y: (CGFloat(S)-h)/2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

guard let img = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: "icon_1024.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote icon_1024.png")
