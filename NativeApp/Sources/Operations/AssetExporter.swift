import AppKit
import CoreGraphics
import Foundation

/// Exports artwork at several scales (@1x, @2x, @3x…) and as app icon / favicon packs.
/// Vector sources (AI, EPS, PDF, SVG) are re-rendered at every size so each output stays sharp.
enum AssetExporter {
    enum IconPlatform: String, CaseIterable, Identifiable {
        case web, iOS, android, macOS

        var id: String { rawValue }

        var title: String {
            switch self {
            case .web: return "Web favicon"
            case .iOS: return "iOS"
            case .android: return "Android"
            case .macOS: return "macOS"
            }
        }

        var detail: String {
            switch self {
            case .web: return "favicon.ico, 16–512 px PNGs, Apple touch icon, web manifest"
            case .iOS: return "AppIcon.appiconset for Xcode (1024 px)"
            case .android: return "mipmap launcher icons and a 512 px Play Store icon"
            case .macOS: return "AppIcon.icns with every size from 16 to 1024 px"
            }
        }
    }

    struct Options {
        var scales: [Int] = [1, 2, 3]
        var format: FileFormat = .png
        /// For pixel images: which scale the original file already is, so @1x is derived by shrinking.
        var sourceScale: Int = 1
        var icons: Set<IconPlatform> = []
    }

    /// Artwork that can be drawn at any pixel size.
    struct Artwork {
        /// Size of @1x in points (vector) or pixels (raster, before applying the source scale).
        let size: CGSize
        let isVector: Bool
        let render: (Int, Int) -> CGImage?
    }

    static func load(_ url: URL) async throws -> Artwork {
        guard let format = FileFormat.detect(url) else { throw OpenTangerineError.unreadable(url) }
        switch format {
        case .ai, .eps, .pdf:
            let source = format == .pdf ? DesignFiles.PDFSource(url: url, isTemporary: false) : try await DesignFiles.pdfSource(for: url, format: format)
            defer { source.cleanup() }
            // Keep the bytes in memory so a temporary PDF from Ghostscript can be removed right away.
            guard let provider = CGDataProvider(data: try Data(contentsOf: source.url) as CFData),
                  let document = CGPDFDocument(provider), let page = document.page(at: 1) else { throw OpenTangerineError.unreadable(url) }
            return Artwork(size: DesignFiles.displaySize(page), isVector: true) { width, height in
                DesignFiles.pageImage(page, width: width, height: height)
            }
        case .svg:
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { throw OpenTangerineError.unreadable(url) }
            return Artwork(size: image.size, isVector: true) { width, height in
                drawSVG(image, width: width, height: height)
            }
        default:
            let image = try ImageIOBridge.load(url)
            return Artwork(size: CGSize(width: image.width, height: image.height), isVector: false) { width, height in
                ImageIOBridge.scaled(image, to: CGSize(width: width, height: height))
            }
        }
    }

    private static func drawSVG(_ image: NSImage, width: Int, height: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Writes all requested outputs into one new folder and returns it.
    static func export(_ url: URL, options: Options, into parent: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let artwork = try await load(url)
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        let folder = ConversionMatrix.uniqueDirectory(directory: parent, name: "\(base) assets")
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let pointSize = artwork.isVector ? artwork.size : CGSize(width: artwork.size.width / CGFloat(options.sourceScale), height: artwork.size.height / CGFloat(options.sourceScale))
            let steps = Double(options.scales.count + options.icons.count)
            var done = 0.0
            for scale in options.scales {
                let width = max(1, Int((pointSize.width * CGFloat(scale)).rounded()))
                let height = max(1, Int((pointSize.height * CGFloat(scale)).rounded()))
                guard let image = artwork.render(width, height) else { throw OpenTangerineError.encodeFailed("\(base)@\(scale)x") }
                let name = scale == 1 ? base : "\(base)@\(scale)x"
                try await ImageIOBridge.writeAnyFormat(image, to: folder.appendingPathComponent("\(name).\(options.format.fileExtension)"), format: options.format, quality: 0.92)
                done += 1
                progress(done / steps)
            }
            for platform in IconPlatform.allCases where options.icons.contains(platform) {
                try await writeIcons(platform, artwork: artwork, into: folder)
                done += 1
                progress(done / steps)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Square icon at a pixel size; non-square artwork is centred on a transparent square.
    static func icon(_ artwork: Artwork, size: Int) -> CGImage? {
        let fit = min(CGFloat(size) / artwork.size.width, CGFloat(size) / artwork.size.height)
        let width = max(1, Int((artwork.size.width * fit).rounded())), height = max(1, Int((artwork.size.height * fit).rounded()))
        guard let drawn = artwork.render(width, height) else { return nil }
        if width == size && height == size { return drawn }
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(drawn, in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    private static func writePNG(_ artwork: Artwork, size: Int, to url: URL) throws {
        guard let image = icon(artwork, size: size) else { throw OpenTangerineError.encodeFailed(url.lastPathComponent) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ImageIOBridge.write(image, to: url, format: .png)
    }

    private static func writeIcons(_ platform: IconPlatform, artwork: Artwork, into folder: URL) async throws {
        switch platform {
        case .web:
            let web = folder.appendingPathComponent("favicon")
            for size in [16, 32, 48, 192, 512] {
                try writePNG(artwork, size: size, to: web.appendingPathComponent(size >= 192 ? "android-chrome-\(size)x\(size).png" : "favicon-\(size)x\(size).png"))
            }
            try writePNG(artwork, size: 180, to: web.appendingPathComponent("apple-touch-icon.png"))
            try writeICO([16, 32, 48].compactMap { icon(artwork, size: $0) }, to: web.appendingPathComponent("favicon.ico"))
            let manifest = """
            {
              "icons": [
                { "src": "/android-chrome-192x192.png", "sizes": "192x192", "type": "image/png" },
                { "src": "/android-chrome-512x512.png", "sizes": "512x512", "type": "image/png" }
              ]
            }

            """
            try Data(manifest.utf8).write(to: web.appendingPathComponent("site.webmanifest"))
        case .iOS:
            let set = folder.appendingPathComponent("AppIcon.appiconset")
            // App icons must be opaque; transparent areas would turn black on device.
            guard let image = icon(artwork, size: 1024) else { throw OpenTangerineError.encodeFailed("AppIcon") }
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            try ImageIOBridge.write(ImageIOBridge.flatten(image, background: .white), to: set.appendingPathComponent("AppIcon-1024.png"), format: .png)
            let contents = """
            {
              "images" : [
                { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
              ],
              "info" : { "author" : "xcode", "version" : 1 }
            }

            """
            try Data(contents.utf8).write(to: set.appendingPathComponent("Contents.json"))
        case .android:
            let android = folder.appendingPathComponent("android")
            for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
                try writePNG(artwork, size: size, to: android.appendingPathComponent("mipmap-\(density)/ic_launcher.png"))
            }
            try writePNG(artwork, size: 512, to: android.appendingPathComponent("play-store-512.png"))
        case .macOS:
            let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-\(UUID().uuidString).iconset")
            defer { try? FileManager.default.removeItem(at: iconset) }
            for size in [16, 32, 128, 256, 512] {
                try writePNG(artwork, size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
                try writePNG(artwork, size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
            }
            let output = folder.appendingPathComponent("AppIcon.icns")
            let result = try await Shell.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("iconutil", result.stderr) }
        }
    }

    /// ICO with PNG-compressed entries, supported by every current browser and Windows since Vista.
    static func writeICO(_ images: [CGImage], to url: URL) throws {
        var entries: [(size: Int, data: Data)] = []
        for image in images {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try ImageIOBridge.write(image, to: temp, format: .png)
            entries.append((image.width, try Data(contentsOf: temp)))
        }
        var data = Data()
        func le16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)]) }
        func le32(_ value: Int) { le16(value & 0xffff); le16(value >> 16) }
        le16(0); le16(1); le16(entries.count)
        var offset = 6 + 16 * entries.count
        for entry in entries {
            data.append(UInt8(entry.size >= 256 ? 0 : entry.size)); data.append(UInt8(entry.size >= 256 ? 0 : entry.size))
            data.append(0); data.append(0)
            le16(1); le16(32); le32(entry.data.count); le32(offset)
            offset += entry.data.count
        }
        for entry in entries { data.append(entry.data) }
        try data.write(to: url)
    }
}
