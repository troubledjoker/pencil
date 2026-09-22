// Renders Pencil's app icon with Core Graphics.
//
// The artwork itself lives in Sources/PencilCore/IconArt.swift (shared with the
// app's dock tab). This file is compiled together with it, so run it through
// scripts/make-icon.sh (bundle.sh does that for you):
//
//   swiftc -parse-as-library -O scripts/make-icon.swift Sources/PencilCore/IconArt.swift -o .build/make-icon
//   .build/make-icon Resources
//
// Output: Resources/AppIcon.iconset/*, Resources/AppIcon.icns, Resources/icon-preview.png

import AppKit
import CoreGraphics

@main
struct MakeIcon {
    static func render(_ px: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("no bitmap context") }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        IconArt.drawAppIcon(in: ctx, size: CGFloat(px))
        guard let image = ctx.makeImage() else { fatalError("no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
        return png
    }

    static func main() throws {
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources", isDirectory: true)
        let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

        for pt in [16, 32, 128, 256, 512] {
            try render(pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
            try render(pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
        }
        try render(1024).write(to: out.appendingPathComponent("icon-preview.png"))

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else {
            FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
            exit(1)
        }
        print("Wrote \(out.path)/AppIcon.icns and icon-preview.png")
    }
}
