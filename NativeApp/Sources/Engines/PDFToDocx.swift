import AppKit
import PDFKit

/// PDF to Word. pdf2docx, when installed, rebuilds the layout: columns, tables, images and text styling.
/// Without it the built-in writer keeps the text styling, the page size and the images on each page,
/// though not columns or tables. Pages with no text layer (scans) become full-page pictures.
enum PDFToDocx {
    /// Tests turn this off to exercise the built-in writer on machines that have pdf2docx.
    nonisolated(unsafe) static var allowExternalTool = true

    static func convert(_ document: PDFDocument, source: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        if allowExternalTool, ExternalTool.pdf2docx.isAvailable {
            do {
                try await viaPdf2docx(source, to: destination)
                progress(1)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DiagnosticLog.log("pdf2docx failed, using the built-in writer: \(error)")
            }
        }
        try await builtIn(document, to: destination, progress: progress)
    }

    private static func viaPdf2docx(_ source: URL, to destination: URL) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-pdf2docx-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await ExternalTool.pdf2docx.run(["convert", source.path, temp.path], purpose: "Converting a PDF to Word")
        // pdf2docx can exit 0 after logging a failure, so check that a real DOCX (a zip) came out.
        let handle = try FileHandle(forReadingFrom: temp)
        let magic = try handle.read(upToCount: 2)
        try? handle.close()
        guard magic == Data([0x50, 0x4B]) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: Built-in writer

    private static func builtIn(_ document: PDFDocument, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let pageCount = document.pageCount
        var blocks: [DocxWriter.Block] = []
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-pdfdocx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var imageCount = 0
        for index in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw OpenTangerineError.encodeFailed("PDF page \(index + 1)") }
            if index > 0 { blocks.append(.pageBreak) }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                blocks += styledParagraphs(page)
                for image in embeddedImages(page) {
                    imageCount += 1
                    let url = temp.appendingPathComponent("image\(imageCount).\(image.ext)")
                    try image.data.write(to: url)
                    blocks.append(.image(url))
                }
            } else if let image = PDFRenderer.render(page: page, dpi: 150) {
                imageCount += 1
                let pageImage = temp.appendingPathComponent("page\(index + 1).png")
                try ImageIOBridge.write(image, to: pageImage, format: .png)
                blocks.append(.image(pageImage))
            }
            progress(Double(index + 1) / Double(pageCount) * 0.8)
        }
        try await DocxWriter.write(blocks: blocks, page: pageLayout(document), to: destination)
    }

    /// Word page size from the first page, with margins scaled to the page.
    static func pageLayout(_ document: PDFDocument) -> DocxWriter.Page {
        guard let page = document.page(at: 0) else { return DocxWriter.Page() }
        var size = page.bounds(for: .mediaBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard size.width >= 72, size.height >= 72 else { return DocxWriter.Page() }
        return DocxWriter.Page(size: size, margin: min(54, min(size.width, size.height) * 0.08))
    }

    /// One Word paragraph per line of the page's text layer, keeping font, size, weight, slant, underline and colour.
    static func styledParagraphs(_ page: PDFPage) -> [DocxWriter.Block] {
        guard let attributed = page.attributedString else {
            return (page.string ?? "").components(separatedBy: "\n").map { .paragraph($0) }
        }
        let string = attributed.string as NSString
        var blocks: [DocxWriter.Block] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            var runs: [DocxWriter.Run] = []
            attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
                let text = string.substring(with: runRange)
                guard !text.isEmpty else { return }
                var run = DocxWriter.Run(text: text)
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    run.font = font.familyName
                    run.size = font.pointSize
                    run.bold = traits.contains(.bold)
                    run.italic = traits.contains(.italic)
                }
                if let style = attributes[.underlineStyle] as? Int, style != 0 { run.underline = true }
                if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                    let hex = String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
                    if hex != "000000" { run.color = hex }
                }
                runs.append(run)
            }
            blocks.append(runs.isEmpty ? .paragraph("") : .styled(runs))
        }
        return blocks
    }

    struct ExtractedImage {
        let data: Data
        let ext: String
    }

    /// Image XObjects on the page, including those nested in form XObjects. JPEGs are copied as they are;
    /// 8-bit RGB and grey images are re-encoded as PNG. Other encodings are skipped.
    static func embeddedImages(_ page: PDFPage) -> [ExtractedImage] {
        guard let cgPage = page.pageRef, let resources = dictionary(cgPage.dictionary, "Resources") else { return [] }
        var images: [ExtractedImage] = []
        var seen = Set<CGPDFStreamRef>()
        collectImages(resources, depth: 0, into: &images, seen: &seen)
        return images
    }

    private static func collectImages(_ resources: CGPDFDictionaryRef, depth: Int, into images: inout [ExtractedImage], seen: inout Set<CGPDFStreamRef>) {
        guard depth < 4, let xObjects = dictionary(resources, "XObject") else { return }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        for stream in streams {
            guard seen.insert(stream).inserted, let info = CGPDFStreamGetDictionary(stream) else { continue }
            switch name(info, "Subtype") {
            case "Image":
                if let image = decode(stream, info) { images.append(image) }
            case "Form":
                if let nested = dictionary(info, "Resources") { collectImages(nested, depth: depth + 1, into: &images, seen: &seen) }
            default:
                break
            }
        }
    }

    private static func decode(_ stream: CGPDFStreamRef, _ info: CGPDFDictionaryRef) -> ExtractedImage? {
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(info, "Width", &width), CGPDFDictionaryGetInteger(info, "Height", &height),
              width >= 16, height >= 16 else { return nil }
        // Soft masks and stencil masks are part of another image, not pictures of their own.
        var isMask = false
        if CGPDFDictionaryGetBoolean(info, "ImageMask", &isMask), isMask { return nil }
        CGPDFDictionaryGetInteger(info, "BitsPerComponent", &bits)
        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        switch format {
        case .jpegEncoded: return ExtractedImage(data: data, ext: "jpg")
        case .JPEG2000: return nil
        case .raw: break
        @unknown default: return nil
        }
        guard bits == 8, let components = colorComponents(info) else { return nil }
        let rowBytes = Int(width) * components
        guard data.count >= rowBytes * Int(height), let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = components == 3 ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
        guard let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = pngData(image) else { return nil }
        return ExtractedImage(data: png, ext: "png")
    }

    /// Components per pixel for DeviceRGB, DeviceGray and ICC-based colour spaces; nil for anything else.
    private static func colorComponents(_ info: CGPDFDictionaryRef) -> Int? {
        switch name(info, "ColorSpace") {
        case "DeviceRGB": return 3
        case "DeviceGray": return 1
        default: break
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(info, "ColorSpace", &array), let array else { return nil }
        var family: UnsafePointer<CChar>?
        var iccStream: CGPDFStreamRef?
        guard CGPDFArrayGetName(array, 0, &family), let family, String(cString: family) == "ICCBased",
              CGPDFArrayGetStream(array, 1, &iccStream), let iccStream, let iccInfo = CGPDFStreamGetDictionary(iccStream) else { return nil }
        var n: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(iccInfo, "N", &n)
        return n == 3 || n == 1 ? Int(n) : nil
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func dictionary(_ parent: CGPDFDictionaryRef?, _ key: String) -> CGPDFDictionaryRef? {
        guard let parent else { return nil }
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(parent, key, &value) ? value : nil
    }

    private static func name(_ parent: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(parent, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
