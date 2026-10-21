import AppKit
import ImageIO

// Generates micloud.iconset (then build via iconutil): the micloud mark — two upright pages on an evergreen
// squircle (brand/micloud-logo.svg, "The Personal Archive" identity, 2026-10-21).

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

    // evergreen squircle background (brand/micloud-logo.svg: #183E34 tile, rx 12/48)
    let corner = squircle ? P * 0.2237 : 0
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: P, height: P), cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0x18/255.0, green: 0x3E/255.0, blue: 0x34/255.0, alpha: 1))
    ctx.fillPath()

    // the mark: two upright pages, related but independent — paper (12,15 12×20) and leaf (25,11 11×24) on a
    // 48-unit grid. The SVG is y-down; CoreGraphics is y-up, so y = 48 - (top + height).
    let u = P / 48.0
    func page(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ gg: CGFloat, _ b: CGFloat) {
        ctx.setFillColor(CGColor(srgbRed: r/255.0, green: gg/255.0, blue: b/255.0, alpha: 1))
        ctx.fill(CGRect(x: x * u, y: (48 - top - h) * u, width: w * u, height: h * u))
    }
    page(12, 15, 12, 20, 0xF4, 0xF2, 0xE9)
    page(25, 11, 11, 24, 0xC2, 0xDB, 0x9B)
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
