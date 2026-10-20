// Run from the repository root: swift scripts/generate_brand.swift
// Native vector and bitmap exports; no third-party dependencies.
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("assets/brand")
let catalog = root.appendingPathComponent("app/Resources/Assets.xcassets")
let icons = catalog.appendingPathComponent("AppIcon.appiconset")
let ink = "193E32", paper = "FAF9F5", sage = "DCEBD1"
func color(_ hex: String) -> NSColor {
    let n = Int(hex, radix: 16)!
    return NSColor(srgbRed: CGFloat(n >> 16)/255, green: CGFloat((n >> 8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1)
}
let left = CGMutablePath()
left.move(to: CGPoint(x: 12, y: 15))
left.addCurve(to: CGPoint(x: 30, y: 25), control1: CGPoint(x: 20, y: 15), control2: CGPoint(x: 26, y: 19))
left.addLine(to: CGPoint(x: 30, y: 49))
left.addCurve(to: CGPoint(x: 12, y: 40), control1: CGPoint(x: 24, y: 43), control2: CGPoint(x: 19, y: 40))
left.closeSubpath()
let right = CGMutablePath()
right.move(to: CGPoint(x: 34, y: 25))
right.addCurve(to: CGPoint(x: 52, y: 15), control1: CGPoint(x: 40, y: 19), control2: CGPoint(x: 45, y: 15))
right.addLine(to: CGPoint(x: 52, y: 40))
right.addCurve(to: CGPoint(x: 34, y: 49), control1: CGPoint(x: 45, y: 40), control2: CGPoint(x: 40, y: 43))
right.closeSubpath()
// The narrow cut is the margin: a quiet detail that survives at launcher sizes.
let margin = CGMutablePath()
margin.move(to: CGPoint(x: 18, y: 22))
margin.addLine(to: CGPoint(x: 18, y: 34))
let leftSVG = "M12 15C20 15 26 19 30 25V49C24 43 19 40 12 40Z"
let rightSVG = "M34 25C40 19 45 15 52 15V40C45 40 40 43 34 49Z"
func markSVG(_ fg: String) -> String {
    "<path fill=\"#\(fg)\" fill-rule=\"evenodd\" d=\"\(leftSVG) M17 21H19V35H17Z \(rightSVG)\"/>"
}
func svg(_ w: Int, _ h: Int, _ body: String, title: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\" role=\"img\" aria-label=\"\(title)\">\(body)</svg>\n"
}
func write(_ name: String, _ value: String) throws {
    try value.write(to: brand.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
// Outlined system serif: exported logos require no installed font.
let descriptor = NSFont.systemFont(ofSize: 92, weight: .bold).fontDescriptor.withDesign(.serif)!
let font = NSFont(descriptor: descriptor, size: 92)!
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "margin", attributes: [.font: font]))
let word = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let n = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: n)
    var positions = [CGPoint](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    for i in 0..<n {
        if let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
            word.addPath(path, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
        }
    }
}
func pathSVG(_ path: CGPath) -> String {
    var d = ""
    func p(_ point: CGPoint) -> String { String(format: "%.3f %.3f", Double(point.x), Double(point.y)) }
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        switch e.type {
        case .moveToPoint: d += "M" + p(e.points[0])
        case .addLineToPoint: d += "L" + p(e.points[0])
        case .addQuadCurveToPoint: d += "Q" + p(e.points[0]) + " " + p(e.points[1])
        case .addCurveToPoint: d += "C" + p(e.points[0]) + " " + p(e.points[1]) + " " + p(e.points[2])
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}
func logoSVG(_ fg: String) -> String {
    svg(440, 120, "<g transform=\"translate(0 12) scale(1.5)\">\(markSVG(fg))</g><path fill=\"#\(fg)\" transform=\"translate(111 84) scale(1 -1)\" d=\"\(pathSVG(word))\"/>", title: "Margin logo")
}
func bitmap(_ width: Int, _ height: Int, opaque: Bool = false, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    if opaque {
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
        draw(cg)
        return NSBitmapImageRep(cgImage: cg.makeImage()!)
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func png(_ rep: NSBitmapImageRep, _ url: URL) throws { try rep.representation(using: .png, properties: [:])!.write(to: url) }
func mark(_ c: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, fg: String) {
    c.saveGState(); c.translateBy(x: x, y: y); c.scaleBy(x: size/64, y: size/64)
    let path = CGMutablePath(); path.addPath(left); path.addRect(CGRect(x: 17, y: 21, width: 2, height: 14)); path.addPath(right)
    c.setFillColor(color(fg).cgColor); c.addPath(path); c.drawPath(using: .eoFill)
    c.restoreGState()
}
func icon(_ c: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, rounded: Bool = true) {
    c.saveGState()
    let rect = CGRect(x: x, y: y, width: size, height: size)
    c.setFillColor(color(ink).cgColor)
    c.addPath(CGPath(roundedRect: rect, cornerWidth: rounded ? size*0.225 : 0, cornerHeight: rounded ? size*0.225 : 0, transform: nil)); c.fillPath()
    mark(c, x: x, y: y, size: size, fg: paper)
    c.restoreGState()
}
func text(_ c: CGContext, _ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, fg: String = ink, serif: Bool = false, bold: Bool = false) {
    let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    let f = serif ? NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: size)! : base
    let l = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: f, .foregroundColor: color(fg)]))
    c.saveGState(); c.translateBy(x: x, y: y); c.scaleBy(x: 1, y: -1); c.textPosition = .zero; CTLineDraw(l, c); c.restoreGState()
}
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
try write("mark.svg", svg(64,64,markSVG(ink),title: "Margin open-book monogram"))
try write("mark-reversed.svg", svg(64,64,markSVG(paper),title: "Margin reversed monogram"))
try write("logo.svg", logoSVG(ink)); try write("logo-reversed.svg", logoSVG(paper))
let iconSource = svg(1024,1024,"<rect width=\"1024\" height=\"1024\" fill=\"#\(ink)\"/><g transform=\"scale(16)\">\(markSVG(paper))</g>",title: "Margin app icon")
try write("app-icon.svg", iconSource)
try svg(64,64,"<rect width=\"64\" height=\"64\" rx=\"14.4\" fill=\"#\(ink)\"/>"+markSVG(paper),title: "Margin app icon").write(to: root.appendingPathComponent("assets/icon.svg"), atomically: true, encoding: .utf8)
try png(bitmap(1024,1024,opaque:true) { icon($0,x:0,y:0,size:1024,rounded:false) }, brand.appendingPathComponent("app-icon-1024.png"))
var images: [[String: Any]] = [["filename":"ios-1024.png", "idiom":"universal", "platform":"ios", "size":"1024x1024"]]
try png(bitmap(1024,1024,opaque:true) { icon($0,x:0,y:0,size:1024,rounded:false) }, icons.appendingPathComponent("ios-1024.png"))
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale, name = "mac-\(size)@\(scale)x.png"
        // The macOS tile has an inset, leaving the outer canvas transparent.
        try png(bitmap(pixels,pixels) { c in
            let s = CGFloat(pixels); icon(c,x:s*0.09,y:s*0.09,size:s*0.82)
        }, icons.appendingPathComponent(name))
        images.append(["filename":name,"idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x"])
    }
}
let info: [String: Any] = ["info":["author":"xcode","version":1],"images":images]
try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted,.sortedKeys]).write(to: icons.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}\n".utf8).write(to: catalog.appendingPathComponent("Contents.json"))
try png(bitmap(1600,1080) { c in
    c.setFillColor(color(paper).cgColor); c.fill(CGRect(x:0,y:0,width:1600,height:1080))
    text(c,"MARGIN  /  VISUAL IDENTITY",80,66,size:14,bold:true)
    text(c,"Space for a little wisdom.",80,154,size:48,serif:true)
    text(c,"An open book. A quiet M. A place to make an idea your own.",82,197,size:21,fg:"63746A")
    c.setFillColor(color("E7EDDF").cgColor); c.fill(CGRect(x:80,y:247,width:900,height:420))
    mark(c,x:145,y:342,size:200,fg:ink)
    c.saveGState(); c.translateBy(x:380,y:488); c.scaleBy(x:1.7,y:-1.7); c.addPath(word); c.setFillColor(color(ink).cgColor); c.fillPath(); c.restoreGState()
    text(c,"PRIMARY LOGO",112,632,size:12,fg:"63746A",bold:true)
    icon(c,x:1054,y:247,size:340)
    text(c,"APP ICON",1054,632,size:12,fg:"63746A",bold:true)
    c.setFillColor(color(ink).cgColor); c.fill(CGRect(x:80,y:703,width:900,height:215))
    mark(c,x:118,y:735,size:136,fg:paper)
    c.saveGState(); c.translateBy(x:280,y:835); c.scaleBy(x:1.14,y:-1.14); c.addPath(word); c.setFillColor(color(paper).cgColor); c.fillPath(); c.restoreGState()
    text(c,"SMALL-SIZE STUDY",1054,737,size:12,fg:"63746A",bold:true)
    var x: CGFloat = 1054
    for s: CGFloat in [64,48,32,24,16] { icon(c,x:x,y:777+(64-s)/2,size:s); text(c,"\(Int(s))",x,875,size:12,fg:"63746A"); x += s+26 }
    for (i, hex) in [ink,paper,sage].enumerated() {
        let x = CGFloat(80+i*310)
        c.setFillColor(color(hex).cgColor); c.fill(CGRect(x:x,y:974,width:40,height:40))
        c.setStrokeColor(color("C8D0C5").cgColor); c.stroke(CGRect(x:x,y:974,width:40,height:40))
        text(c,["FOREST","PAPER","SAGE"][i],x+56,989,size:11,bold:true)
        text(c,"#\(hex)",x+56,1010,size:13,fg:"63746A")
    }
    text(c,"READ. REFLECT. KEEP.",1162,1002,size:13,bold:true)
}, brand.appendingPathComponent("identity-preview.png"))
print("Exported Margin vectors, identity preview, and iOS/macOS app icons.")
