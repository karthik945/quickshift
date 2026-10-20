import CoreGraphics
import Foundation

/// Illustrator (.ai), EPS and Photoshop (.psd) conversions, processed locally.
/// Vector routes follow the Illustrator-to-SVG-Converter approach: Ghostscript turns
/// PostScript into PDF, then Poppler's pdftocairo writes SVG (in place of Inkscape).
struct DesignEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .design && ConversionMatrix.targets(for: from).contains(to)
    }

    func convert(_ request: ConversionRequest) async throws {
        if request.sourceFormat == .psd {
            try await convertPSD(request)
        } else {
            try await convertVector(request)
        }
    }

    private func convertVector(_ request: ConversionRequest) async throws {
        let pdf = try await DesignFiles.pdfSource(for: request.source, format: request.sourceFormat)
        defer { pdf.cleanup() }
        request.progress(0.4)
        switch request.target {
        case .svg:
            // SVG holds a single page, so only the first artboard is exported.
            try await ExternalTool.pdftocairo.run(["-svg", "-f", "1", "-l", "1", pdf.url.path, request.destination.path], purpose: "Converting \(request.sourceFormat.displayName) to SVG")
        case .pdf:
            try DesignFiles.redrawPDF(pdf.url, to: request.destination)
        case .eps:
            try await ExternalTool.ghostscript.run(
                ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=eps2write", "-dFirstPage=1", "-dLastPage=1", "-o", request.destination.path, pdf.url.path],
                purpose: "Converting \(request.sourceFormat.displayName) to EPS"
            )
        default:
            let image = try DesignFiles.renderFirstPage(pdf.url)
            request.progress(0.7)
            try await ImageIOBridge.writeAnyFormat(image, to: request.destination, format: request.target, quality: AppSettings.shared.jpegQuality)
        }
        request.progress(1)
    }

    private func convertPSD(_ request: ConversionRequest) async throws {
        // ImageIO reads the flattened composite that Photoshop stores with the layers.
        let image = try ImageIOBridge.load(request.source)
        request.progress(0.4)
        switch request.target {
        case .pdf:
            try ImageIOBridge.writePDF(images: [image], to: request.destination)
        default:
            try await ImageIOBridge.writeAnyFormat(image, to: request.destination, format: request.target, quality: AppSettings.shared.jpegQuality)
        }
        request.progress(1)
    }
}

enum DesignFiles {
    struct PDFSource {
        let url: URL
        let isTemporary: Bool

        func cleanup() {
            if isTemporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Illustrator files saved with PDF compatibility are PDFs; EPS and legacy AI files are PostScript.
    static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 1024)) ?? Data()
        return header.range(of: Data("%PDF-".utf8)) != nil
    }

    static func pdfSource(for url: URL, format: FileFormat) async throws -> PDFSource {
        if format == .ai, isPDF(url) { return PDFSource(url: url, isTemporary: false) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-\(UUID().uuidString).pdf")
        try await ExternalTool.ghostscript.run(
            ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=pdfwrite", "-dEPSCrop", "-o", temp.path, url.path],
            purpose: "Reading \(format.displayName) files"
        )
        guard FileManager.default.fileExists(atPath: temp.path) else { throw OpenTangerineError.unreadable(url) }
        return PDFSource(url: temp, isTemporary: true)
    }

    private static func document(_ url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { throw OpenTangerineError.unreadable(url) }
        guard !document.isEncrypted || document.unlockWithPassword("") else {
            throw OpenTangerineError.invalidInput("\(url.lastPathComponent) is password protected.")
        }
        return document
    }

    /// Re-draws every page into a fresh PDF, dropping Illustrator's private editing data.
    static func redrawPDF(_ source: URL, to destination: URL) throws {
        let document = try document(source)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            var box = CGRect(origin: .zero, size: page.getBoxRect(.cropBox).size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Renders the first artboard with a transparent background at up to 300 DPI, within the 40 MP image limit.
    static func renderFirstPage(_ source: URL, maxLongEdge: CGFloat = 6000) throws -> CGImage {
        let document = try document(source)
        guard let page = document.page(at: 1) else { throw OpenTangerineError.unreadable(source) }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { throw OpenTangerineError.unreadable(source) }
        var scale = min(300 / 72, maxLongEdge / max(size.width, size.height))
        scale = min(scale, (40_000_000 / (size.width * size.height)).squareRoot())
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OpenTangerineError.encodeFailed(source.lastPathComponent) }
        context.interpolationQuality = .high
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw OpenTangerineError.encodeFailed(source.lastPathComponent) }
        return image
    }
}
