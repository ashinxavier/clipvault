import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = NSSize(width: 1024, height: 1024)
let icon = NSImage(size: canvas)
icon.lockFocus()

let background = NSBezierPath(
    roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960),
    xRadius: 220,
    yRadius: 220
)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.24, green: 0.72, blue: 0.93, alpha: 1)
])!
gradient.draw(in: background, angle: 42)

NSColor.white.withAlphaComponent(0.11).setFill()
NSBezierPath(ovalIn: NSRect(x: 570, y: 570, width: 420, height: 420)).fill()

let page = NSBezierPath(roundedRect: NSRect(x: 270, y: 190, width: 484, height: 650), xRadius: 38, yRadius: 38)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
page.fill()
NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
page.lineWidth = 8
page.stroke()

let clip = NSBezierPath(roundedRect: NSRect(x: 415, y: 760, width: 195, height: 108), xRadius: 28, yRadius: 28)
NSColor(calibratedRed: 0.10, green: 0.23, blue: 0.52, alpha: 1).setFill()
clip.fill()

for (y, width) in [(650.0, 320.0), (545.0, 320.0), (440.0, 230.0)] {
    let line = NSBezierPath(roundedRect: NSRect(x: 350, y: y, width: width, height: 24), xRadius: 12, yRadius: 12)
    NSColor(calibratedRed: 0.26, green: 0.39, blue: 0.59, alpha: 0.82).setFill()
    line.fill()
}

let badge = NSBezierPath(ovalIn: NSRect(x: 594, y: 235, width: 205, height: 205))
NSColor(calibratedRed: 0.13, green: 0.72, blue: 0.57, alpha: 1).setFill()
badge.fill()
let shackle = NSBezierPath(roundedRect: NSRect(x: 651, y: 324, width: 92, height: 78), xRadius: 42, yRadius: 42)
shackle.lineWidth = 18
NSColor.white.setStroke()
shackle.stroke()
let lockBody = NSBezierPath(roundedRect: NSRect(x: 633, y: 268, width: 128, height: 102), xRadius: 24, yRadius: 24)
NSColor.white.setFill()
lockBody.fill()
let keyhole = NSBezierPath(ovalIn: NSRect(x: 686, y: 307, width: 22, height: 22))
NSColor(calibratedRed: 0.13, green: 0.50, blue: 0.46, alpha: 1).setFill()
keyhole.fill()

icon.unlockFocus()
guard let tiff = icon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render ClipVault icon")
}
try png.write(to: outputURL, options: .atomic)
