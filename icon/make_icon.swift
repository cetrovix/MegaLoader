// Рисует иконку MegaLoader (оранжевый квадрат-скругление + стрелка загрузки) → icon/AppIcon.iconset
import AppKit
let sizes: [(Int, String)] = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
let dir = URL(fileURLWithPath: CommandLine.arguments[1]); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (px, name) in sizes {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1), NSColor(red: 0.93, green: 0.42, blue: 0.12, alpha: 1)])!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .bold)
    if let sym = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size); tinted.lockFocus(); sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set(); NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop); tinted.unlockFocus()
        let w = sym.size.width, h = sym.size.height
        tinted.draw(in: NSRect(x: (s - w)/2, y: (s - h)/2 + s*0.04, width: w, height: h))
    }
    let bar = NSBezierPath(roundedRect: NSRect(x: s*0.32, y: s*0.24, width: s*0.36, height: s*0.055), xRadius: s*0.03, yRadius: s*0.03)
    NSColor.white.setFill(); bar.fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_\(name).png"))
}
