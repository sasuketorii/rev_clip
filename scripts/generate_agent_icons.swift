import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let catalog = root.appendingPathComponent("src/Revclip/Revclip/Resources/Assets.xcassets")
for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("src/Revclip/Revclip/Resources/AgentIcons"), includingPropertiesForKeys: nil) where url.pathExtension == "svg" {
    guard let source = NSImage(contentsOf: url) else { fatalError("Cannot decode \(url.lastPathComponent)") }
    let name = "Agent-" + url.deletingPathExtension().lastPathComponent
    let folder = catalog.appendingPathComponent(name + ".imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:72,pixelsHigh:72,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let context = NSGraphicsContext(bitmapImageRep:bitmap) else { fatalError() }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    source.draw(in:NSRect(x:0,y:0,width:72,height:72)); context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name + ".png"))
    let json: [String:Any] = ["images":[["filename":name+".png","idiom":"universal"]],"info":["author":"xcode","version":1],"properties":["template-rendering-intent":"template"]]
    try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("Contents.json"))
    print(name)
}
