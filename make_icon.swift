import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
func render(_ pixels:Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size = NSSize(width:pixels,height:pixels)
    let graphics = NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext; ctx.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    // An inset macOS tile, with the transparent margin preserved at every size.
    let tile = NSBezierPath(roundedRect:NSRect(x:80,y:80,width:864,height:864),xRadius:194,yRadius:194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width:0,height:-12); shadow.set()
    NSColor.white.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    let configuration = NSImage.SymbolConfiguration(pointSize:512,weight:.light)
        .applying(NSImage.SymbolConfiguration(paletteColors:[NSColor(calibratedRed:0.0,green:0.48,blue:1.0,alpha:1)]))
    let symbol = NSImage(systemSymbolName:"character.magnify.zh",accessibilityDescription:"GlyphCheck")!.withSymbolConfiguration(configuration)!
    let scale = min(650/symbol.size.width,650/symbol.size.height)
    let w = symbol.size.width*scale, h = symbol.size.height*scale
    NSGraphicsContext.current = graphics
    symbol.draw(in:NSRect(x:512-w/2,y:512-h/2,width:w,height:h),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:false,hints:nil)
    ctx.saveGState(); ctx.setBlendMode(.destinationOver); ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect:CGRect(x:80,y:80,width:864,height:864),cornerWidth:194,cornerHeight:194,transform:nil)); ctx.fillPath(); ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
for point in [16,32,128,256,512] {
    for scale in [1,2] {
        let name = "icon_\(point)x\(point)" + (scale==2 ? "@2x" : "") + ".png"
        try render(point*scale).write(to:output.appendingPathComponent(name))
    }
}
