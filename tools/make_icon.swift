// Draws the ReTerm app icon. Usage: swift tools/make_icon.swift <output.png>
// The icon is a dark terminal tile with a prompt, wrapped by a "bring it back" arrow.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// macOS icon grid: an 824 pt rounded tile centred on a 1024 pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x1a2233))
ctx.fillPath()
ctx.restoreGState()

// Background gradient.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x34405e), color(0x151b2b)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Thin inner highlight along the edge.
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setStrokeColor(color(0xffffff, 0.10))
ctx.setLineWidth(6)
ctx.strokePath()

let centre = CGPoint(x: 512, y: 500)

// The return arrow: an open ring that ends in an arrowhead at the upper left.
let radius: CGFloat = 268
let lineWidth: CGFloat = 64
let startAngle = CGFloat.pi * 0.36      // upper right, where the gap begins
let endAngle = CGFloat.pi * 0.80        // upper left, where the arc stops and the arrowhead begins
ctx.setLineCap(.round)
ctx.setLineWidth(lineWidth)
ctx.setStrokeColor(color(0xffffff))
// Clockwise the long way round: from the upper right, down, and back up to the upper left.
ctx.addArc(center: centre, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.strokePath()

// Arrowhead, pointing along the direction of travel at the end of the arc.
let base = CGPoint(x: centre.x + radius * cos(endAngle), y: centre.y + radius * sin(endAngle))
let heading = endAngle - .pi / 2        // tangent for clockwise travel
let headLength: CGFloat = 150
let headHalfWidth: CGFloat = 92
let forward = CGPoint(x: cos(heading), y: sin(heading))
let side = CGPoint(x: -sin(heading), y: cos(heading))
let nose = CGPoint(x: base.x + forward.x * headLength, y: base.y + forward.y * headLength)
ctx.move(to: nose)
ctx.addLine(to: CGPoint(x: base.x + side.x * headHalfWidth, y: base.y + side.y * headHalfWidth))
ctx.addLine(to: CGPoint(x: base.x - side.x * headHalfWidth, y: base.y - side.y * headHalfWidth))
ctx.closePath()
ctx.setFillColor(color(0xffffff))
ctx.setLineJoin(.round)
ctx.setLineWidth(22)
ctx.drawPath(using: .fillStroke)

// Prompt in the middle: a chevron and a cursor bar.
let accent = color(0x5fd38a)
ctx.setStrokeColor(accent)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(48)
let prompt = CGPoint(x: centre.x + 6, y: centre.y - 28)
ctx.move(to: CGPoint(x: prompt.x - 112, y: prompt.y + 78))
ctx.addLine(to: CGPoint(x: prompt.x - 22, y: prompt.y))
ctx.addLine(to: CGPoint(x: prompt.x - 112, y: prompt.y - 78))
ctx.strokePath()
ctx.move(to: CGPoint(x: prompt.x + 30, y: prompt.y - 78))
ctx.addLine(to: CGPoint(x: prompt.x + 124, y: prompt.y - 78))
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
