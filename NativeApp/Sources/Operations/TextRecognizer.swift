import AppKit
import PDFKit
import Vision

/// Reads text from images and PDFs and copies it to the clipboard. PDF pages that already contain
/// text are read directly; scans and images use Apple's on-device Vision OCR.
enum TextRecognizer {
    static func text(in url: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> String {
        if FileFormat.detect(url) == .pdf {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw OpenTangerineError.unreadable(url) }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !embedded.isEmpty {
                    pages.append(embedded)
                } else if let image = PDFRenderer.render(page: page, dpi: 200) {
                    pages.append(try recognize(image))
                }
                progress(Double(index + 1) / Double(document.pageCount))
            }
            return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let text = try recognize(try ImageIOBridge.load(url))
        progress(1)
        return text
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Runs straight from the wheel: all selected files become one clipboard copy, in selection order.
    @MainActor static func run(_ files: [URL]) {
        let result = TextBox()
        JobRunner.shared.run(
            title: ToolID.copyText.progressTitle,
            detail: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files",
            symbol: ToolID.copyText.symbol,
            summary: { result.summary }
        ) { progress in
            var parts: [String] = []
            for (index, url) in files.enumerated() {
                let text = try await text(in: url) { fraction in progress((Double(index) + fraction) / Double(files.count)) }
                if !text.isEmpty { parts.append(text) }
            }
            let combined = parts.joined(separator: "\n\n")
            guard !combined.isEmpty else {
                throw OpenTangerineError.invalidInput("No text found. Copy text works on screenshots, photos of documents and PDFs.")
            }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(combined, forType: .string)
            }
            let words = combined.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            result.summary = "Copied \(words) word\(words == 1 ? "" : "s") to the clipboard"
            return []
        }
    }

    private final class TextBox: @unchecked Sendable {
        var summary: String?
    }
}
