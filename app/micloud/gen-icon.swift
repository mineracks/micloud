import AppKit
import ImageIO

// Generates micloud.iconset (then build via iconutil): an orange-gradient cloud on a dark-navy squircle —
// the brand mark from web/dashboard-mockup.html.

// squircle=false → full-bleed opaque square (iOS masks the corners itself and rejects any alpha channel: ITMS-90717)
func render(_ px: Int, squircle: Bool = true) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    let P = CGFloat(px)

    // navy squircle background
    let corner = squircle ? P * 0.2237 : 0
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: P, height: P), cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0x0B/255.0, green: 0x11/255.0, blue: 0x1E/255.0, alpha: 1))
    ctx.fillPath()

    // orange-gradient cloud (SF Symbol as an alpha mask over a vertical gradient)
    let cfg = NSImage.SymbolConfiguration(pointSize: P * 0.46, weight: .semibold)
    if let cloud = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let cs = cloud.size
        let targetW = P * 0.60
        let scale = targetW / cs.width
        let w = cs.width * scale, h = cs.height * scale
        let r = CGRect(x: (P - w) / 2, y: (P - h) / 2 + P * 0.015, width: w, height: h)

        // full-canvas alpha mask: the cloud at r, transparent everywhere else — so destinationIn clips the
        // gradient to the cloud shape across the WHOLE canvas (no clip-rect edge, no full-bleed leak).
        let mask = NSImage(size: NSSize(width: P, height: P))
        mask.lockFocus(); cloud.draw(in: r); mask.unlockFocus()

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let cols = [CGColor(srgbRed: 1.0, green: 0.807, blue: 0.451, alpha: 1),
                    CGColor(srgbRed: 0.968, green: 0.576, blue: 0.102, alpha: 1),
                    CGColor(srgbRed: 0.878, green: 0.490, blue: 0.047, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.minX, y: r.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        mask.draw(in: CGRect(x: 0, y: 0, width: P, height: P), from: .zero, operation: .destinationIn, fraction: 1.0)
        ctx.endTransparencyLayer()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
// re-encode without an alpha channel (AppKit cannot draw into a 24-bit rep, so strip it after rendering)
func stripAlpha(_ png: Data) -> Data {
    let src = NSBitmapImageRep(data: png)!.cgImage!
    let ctx = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return out as Data
}
if CommandLine.arguments.dropFirst().first == "ios" {
    try! stripAlpha(render(1024, squircle: false)).write(to: URL(fileURLWithPath: "icon-ios-1024.png"))
    print("wrote icon-ios-1024.png (opaque, full-bleed)"); exit(0)
}
let dir = "micloud.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for s in sizes { try! render(s.px).write(to: URL(fileURLWithPath: "\(dir)/\(s.name).png")) }
print("wrote \(dir) (\(sizes.count) pngs)")
