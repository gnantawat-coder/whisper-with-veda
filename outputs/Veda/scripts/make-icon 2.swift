import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/1024); transform.concat()
    NSColor(calibratedWhite: 0.065, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 52,y:52,width:920,height:920),xRadius:220,yRadius:220).fill()
    NSColor(calibratedWhite: 0.65, alpha: 1).setFill()
    for (i,height) in [220.0,500.0,350.0,160.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 282 + Double(i)*130, y: 512-height/2, width: 54, height: height), xRadius: 27,yRadius:27).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using:.png,properties:[:])!
    if [16,32,128,256,512].contains(size) { try data.write(to: URL(fileURLWithPath: output + "/icon_\(size)x\(size).png")) }
    if size >= 32 && size != 128 { let half=size/2; try data.write(to: URL(fileURLWithPath: output + "/icon_\(half)x\(half)@2x.png")) }
}
