// Draws the app icons from the official Paseo mark in a Liquid Glass style:
//   swift scripts/make-icon.swift <logo.svg> <out.png> <mac|ios> [palette] [mark scale, default 0.74]
// Source: https://github.com/getpaseo/paseo packages/website/public/logo.svg;
// outputs go to App/Resources/Assets.xcassets/AppIcon.appiconset.
// The native client keeps the official coil but on its own palette, so it never looks like the official app in the Dock.
import AppKit

let args = CommandLine.arguments
let logo = NSImage(contentsOf: URL(fileURLWithPath: args[1]))!
let mac = args[3] == "mac"
let style = args.count > 4 ? args[4] : "ink"
/// Mark size as a share of the icon plate.
let markScale = CGFloat(Double(args.count > 5 ? args[5] : "0.74")!)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

struct Palette {
    var background: [CGColor]   // top-left → bottom-right
    var glow: CGColor           // soft light behind the mark
    var mark: [CGColor]         // top → bottom
    var markShadow: CGFloat
}

let palettes: [String: Palette] = [
    // Pure black with a white coil (minimal).
    "noir": Palette(background: [c(0x2A2A2C), c(0x111112), c(0x000000)], glow: c(0xFFFFFF, 0.10),
                    mark: [c(0xFFFFFF), c(0xF2F2F2), c(0xD6D6D6)], markShadow: 0.5),
    // White with a black coil (inverse minimal).
    "paper": Palette(background: [c(0xFFFFFF), c(0xF4F4F5), c(0xE2E2E5)], glow: c(0x000000, 0.0),
                     mark: [c(0x3A3A3C), c(0x1C1C1E), c(0x000000)], markShadow: 0.2),
    // Deep ink blue-black with a warm cream coil.
    "ink": Palette(background: [c(0x23304A), c(0x121A2B), c(0x070B14)], glow: c(0xFFE7B8, 0.14),
                   mark: [c(0xFFF6E2), c(0xF6DFAE), c(0xE2BC78)], markShadow: 0.45),
    // Forest green with a white coil.
    "forest": Palette(background: [c(0x2F8A5B), c(0x17603D), c(0x0B3A25)], glow: c(0xFFFFFF, 0.14),
                      mark: [c(0xFFFFFF), c(0xF0FFF6), c(0xCFEBDD)], markShadow: 0.35),
    // Terracotta clay with a cream coil.
    "clay": Palette(background: [c(0xE08A62), c(0xC4613F), c(0x8E3C25)], glow: c(0xFFFFFF, 0.14),
                    mark: [c(0xFFFFFF), c(0xFFF4EA), c(0xF5DCC8)], markShadow: 0.3),
    // Brushed silver with a graphite coil.
    "silver": Palette(background: [c(0xF2F3F5), c(0xC9CDD3), c(0x9097A1)], glow: c(0xFFFFFF, 0.35),
                      mark: [c(0x4A4F57), c(0x2A2E34), c(0x111317)], markShadow: 0.25),
    // Near-black graphite with a mint-to-teal glass coil.
    "graphite": Palette(background: [c(0x3A3F47), c(0x1C1F24), c(0x0B0C0E)], glow: c(0x3CE0B4, 0.28),
                        mark: [c(0xC9FFEC), c(0x5BE3C0), c(0x1FA8A0)], markShadow: 0.45),
    // Frosted white with an indigo-violet coil.
    "frost": Palette(background: [c(0xFFFFFF), c(0xEEF0F6), c(0xD3D8E4)], glow: c(0x8B7CFF, 0.22),
                     mark: [c(0x8E7BFF), c(0x5B4BE0), c(0x2E2A8F)], markShadow: 0.18),
    // Warm coral-to-amber with a white glass coil.
    "ember": Palette(background: [c(0xFFB25B), c(0xFF6A3D), c(0xC2305A)], glow: c(0xFFFFFF, 0.25),
                     mark: [c(0xFFFFFF), c(0xFFF1E6), c(0xFFD9C7)], markShadow: 0.3),
]
let p = palettes[style]!

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
let rect = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: S, height: S)
let shape = mac ? CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil) : CGPath(rect: rect, transform: nil)

// Drop shadow under the macOS squircle.
if mac {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
}

// Background: diagonal gradient, a soft glow behind the mark, and a glass sheen on the upper part.
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: p.background as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [p.glow, p.glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                       endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.48, options: [])
let sheen = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.16), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.05), options: [])
ctx.restoreGState()

// Glass rim: bright on the top edge, fading toward the bottom.
if mac {
    ctx.saveGState()
    ctx.addPath(shape); ctx.setLineWidth(4); ctx.replacePathWithStrokedPath(); ctx.clip()
    let rim = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.55), c(0xFFFFFF, 0.08), c(0xFFFFFF, 0.2)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

// The coil: vertical gradient fill through the logo mask, a soft shadow, and a specular highlight on its top half.
let side = rect.width * markScale
let lr = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
logo.size = NSSize(width: 1400, height: 1400)  // rasterize the SVG large enough for a sharp mask
let mask = logo.cgImage(forProposedRect: nil, context: nil, hints: nil)!
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor.black.withAlphaComponent(p.markShadow).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.clip(to: lr, mask: mask)
let fg = CGGradient(colorsSpace: cs, colors: p.mark as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(fg, start: CGPoint(x: lr.midX, y: lr.maxY), end: CGPoint(x: lr.midX, y: lr.minY), options: [])
let spec = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.55), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(spec, start: CGPoint(x: lr.midX, y: lr.maxY), end: CGPoint(x: lr.midX, y: lr.midY + side * 0.1), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

var data = rep.representation(using: .png, properties: [:])!
if !mac {
    // iOS icons must be opaque.
    let ctx2 = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx2.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    data = NSBitmapImageRep(cgImage: ctx2.makeImage()!).representation(using: .png, properties: [:])!
}
try! data.write(to: URL(fileURLWithPath: args[2]))
