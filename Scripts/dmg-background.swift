import AppKit

// A 640 × 420 point canvas. With Finder's toolbar and path bar hidden,
// create-dmg.sh places the icons at (170, 200)/(470, 200); the arrow sits at y=210.
// Render at 2x for Retina displays and embed the logical size in the PNG.
let size = NSSize(width: 640, height: 420)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 840,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.98, blue: 1, alpha: 1),
           ending: NSColor(calibratedRed: 0.86, green: 0.92, blue: 0.98, alpha: 1))!
    .draw(in: canvas, angle: -90)

func text(_ value: String, top: CGFloat, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 40, y: size.height - top - 40, width: 560, height: 40),
                            withAttributes: [.font: font, .foregroundColor: color,
                                             .paragraphStyle: paragraph])
}
let ink = NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.28, alpha: 1)
text("BeatSnap", top: 42, font: .systemFont(ofSize: 32, weight: .bold), color: ink)
text("Your next beat starts here.", top: 88, font: .systemFont(ofSize: 15), color: ink.withAlphaComponent(0.65))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 282, y: 210))
arrow.line(to: NSPoint(x: 356, y: 210))
arrow.move(to: NSPoint(x: 343, y: 223))
arrow.line(to: NSPoint(x: 356, y: 210))
arrow.line(to: NSPoint(x: 343, y: 197))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.07, green: 0.53, blue: 0.84, alpha: 1).setStroke()
arrow.stroke()

text("Drag BeatSnap to Applications", top: 310, font: .systemFont(ofSize: 17, weight: .semibold), color: ink)
text("Then open BeatSnap from your Applications folder.", top: 343,
     font: .systemFont(ofSize: 13), color: ink.withAlphaComponent(0.65))
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
