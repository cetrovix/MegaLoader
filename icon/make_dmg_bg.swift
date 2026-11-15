// Фон окна установщика DMG: тёмный, стрелка «перетащи в Программы» (640×400, @2x)
import AppKit
let W: CGFloat = 640, H: CGFloat = 400, k: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * k), pixelsHigh: Int(H * k), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(red: 0.965, green: 0.95, blue: 0.935, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W * k, height: H * k).fill()
let orange = NSColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1)
// стрелка между иконками (иконки в Finder по центрам x=170 и x=470, y=190 от верха)
let y = (H - 190) * k
let p = NSBezierPath(); p.lineWidth = 6 * k; p.lineCapStyle = .round
p.move(to: NSPoint(x: 255 * k, y: y)); p.line(to: NSPoint(x: 380 * k, y: y)); orange.setStroke(); p.stroke()
let head = NSBezierPath(); head.move(to: NSPoint(x: 395 * k, y: y)); head.line(to: NSPoint(x: 370 * k, y: y + 18 * k)); head.line(to: NSPoint(x: 370 * k, y: y - 18 * k)); head.close(); orange.setFill(); head.fill()
let style = NSMutableParagraphStyle(); style.alignment = .center
let t1: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22 * k, weight: .semibold), .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: style]
let t2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * k), .foregroundColor: NSColor(white: 0.42, alpha: 1), .paragraphStyle: style]
("Перетащи DiskLoader в «Программы»" as NSString).draw(in: NSRect(x: 0, y: (H - 70) * k, width: W * k, height: 34 * k), withAttributes: t1)
("Если DiskLoader уже установлен — нажми «Заменить», загрузки и история сохранятся" as NSString).draw(in: NSRect(x: 40 * k, y: 40 * k, width: (W - 80) * k, height: 40 * k), withAttributes: t2)
NSGraphicsContext.restoreGraphicsState(); rep.size = NSSize(width: W, height: H)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
