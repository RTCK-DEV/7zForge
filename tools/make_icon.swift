import AppKit

// Renders the SevenZ app icon at 1024x1024 and writes /tmp/sevenz_icon.png.
// Rounded-rect gradient + "7z" glyphs + a stylized archive seam.

let S = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: S, height: S)
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 24, dy: 24), xRadius: 220, yRadius: 220)

// Background gradient: deep blue -> teal
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.45, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.65, alpha: 1),
])!
grad.draw(in: path, angle: -60)

// Subtle inner highlight
NSGraphicsContext.current?.saveGraphicsState()
path.addClip()
let gloss = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.18),
    NSColor.white.withAlphaComponent(0.0),
])!
gloss.draw(in: NSBezierPath(rect: NSRect(x: 24, y: 640, width: 976, height: 360)), angle: -90)

// Vertical "compression seam" stripes on the right
NSColor.white.withAlphaComponent(0.12).setFill()
for i in 0..<4 {
    let w = 34 - CGFloat(i) * 5
    NSBezierPath(rect: NSRect(x: 640 + CGFloat(i) * 78, y: 120, width: w, height: 784)).fill()
}
NSGraphicsContext.current?.restoreGraphicsState()

// "7z" text
let font = NSFont.systemFont(ofSize: 560, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .shadow: {
        let s = NSShadow(); s.shadowBlurRadius = 22
        s.shadowOffset = NSSize(width: 0, height: -14)
        s.shadowColor = NSColor.black.withAlphaComponent(0.35)
        return s
    }(),
]
let str = NSAttributedString(string: "7z", attributes: attrs)
let sz = str.size()
str.draw(at: NSPoint(x: (1024 - sz.width) / 2 - 90, y: (1024 - sz.height) / 2 + 14))

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/sevenz_icon.png"))
print("wrote /tmp/sevenz_icon.png")
