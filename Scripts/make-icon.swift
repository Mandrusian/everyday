import AppKit
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSColor(srgbRed: 0.11, green: 0.105, blue: 0.098, alpha: 1).setFill()
NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 220, yRadius: 220).fill()
let font = NSFont(name: "NewYork-Medium", size: 560) ?? NSFont.systemFont(ofSize: 560, weight: .medium)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.925, green: 0.91, blue: 0.875, alpha: 1)]
let e = NSAttributedString(string: "e", attributes: attrs)
let es = e.size()
e.draw(at: NSPoint(x: 512 - es.width / 2 - 40, y: 512 - es.height / 2 + 10))
let dot = NSAttributedString(string: ".", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)])
dot.draw(at: NSPoint(x: 512 + es.width / 2 - 70, y: 512 - es.height / 2 + 10))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
