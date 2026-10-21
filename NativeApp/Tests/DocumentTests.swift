import AppKit
import Foundation
import PDFKit

@main struct DocumentTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTangerine-documents-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func convert(_ source: URL, _ from: FileFormat, _ to: FileFormat, _ name: String) async throws -> URL {
            let output = url(name)
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: from, target: to, destination: output, progress: { _ in }))
            return output
        }
        let text = "Open Tangerine document test\nCafé & <content>\n\nSecond paragraph."
        try text.write(to: url("input.txt"), atomically: true, encoding: .utf8)
        let pdf = try await convert(url("input.txt"), .txt, .pdf, "text.pdf")
        // The checks below describe the built-in DOCX writer; pdf2docx is covered at the end.
        PDFToDocx.allowExternalTool = false
        precondition(PDFDocument(url: pdf)!.string!.contains("Open Tangerine"))
        for target: FileFormat in [.png, .jpg, .srt, .vtt] {
            let out = try await convert(url("input.txt"), .txt, target, "text.\(target.fileExtension)")
            if target == .png || target == .jpg { precondition(try! ImageIOBridge.load(out).width == 1275) }
            else { precondition(try! String(contentsOf: out, encoding: .utf8).contains("Second paragraph")) }
            print("PASS TXT -> \(target)")
        }
        for target: FileFormat in [.png, .jpg, .txt, .docx] {
            let out = try await convert(pdf, .pdf, target, "pdf.\(target.fileExtension)")
            switch target {
            case .png, .jpg: precondition(try! ImageIOBridge.load(out).width == 2550)
            case .txt: precondition(try! String(contentsOf: out, encoding: .utf8).contains("Open Tangerine"))
            case .docx:
                let result = try await Shell.run("/usr/bin/unzip", ["-p", out.path, "word/document.xml"])
                precondition(result.succeeded && result.stdout.contains("Open Tangerine") && result.stdout.contains("&amp;"))
            default: break
            }
            print("PASS PDF -> \(target)")
        }
        let second = url("second.pdf")
        try TextRenderer.writePDF("Second page marker", to: second)
        let merged = url("merged.pdf")
        try PDFOps.merge([pdf, second], to: merged)
        let mergedDoc = try PDFOps.document(merged)
        precondition(mergedDoc.pageCount == 2 && mergedDoc.page(at: 1)!.string!.contains("Second page"))
        for mode: PDFOps.SplitMode in [.everyPage, .everyN, .ranges] {
            let outputs = try PDFOps.split(merged, mode: mode, every: 2, ranges: "2", into: url("split-\(mode.rawValue)"))
            precondition(outputs.count == (mode == .everyPage ? 2 : 1))
            precondition(try! PDFOps.document(outputs[0]).pageCount == (mode == .everyN ? 2 : 1))
            print("PASS PDF split \(mode)")
        }
        try PDFOps.assemble(pages: [PDFPageRef(sourceIndex: 1, rotation: 90, sourceURL: merged), PDFPageRef(sourceIndex: 0, rotation: 0, sourceURL: merged)], to: url("reordered.pdf"))
        let reordered = try PDFOps.document(url("reordered.pdf"))
        precondition(reordered.page(at: 0)!.rotation == 90 && reordered.page(at: 0)!.string!.contains("Second page"))
        for strong in [false, true] {
            let out = url("compressed-\(strong).pdf")
            try PDFOps.compress(merged, strong: strong, to: out)
            precondition(try! PDFOps.document(out).pageCount == 2)
            print("PASS PDF compression strong=\(strong), preserves page count (size reduction not guaranteed)")
        }
        let imagePDF = url("images.pdf")
        try PDFOps.fromImages([url("text.png"), url("text.jpg")], to: imagePDF, progress: { _ in })
        precondition(try! PDFOps.document(imagePDF).pageCount == 2)
        let multiImages = try await convert(merged, .pdf, .png, "pages.png")
        let pages = try fm.contentsOfDirectory(at: multiImages, includingPropertiesForKeys: nil)
        precondition(pages.count == 2)
        for page in pages { precondition(try! ImageIOBridge.load(page).width == 2550) }
        let scanDOCX = try await convert(imagePDF, .pdf, .docx, "scanned.docx")
        let listing = try await Shell.run("/usr/bin/unzip", ["-l", scanDOCX.path])
        precondition(listing.stdout.contains("image1.png") && listing.stdout.contains("image2.png"))
        do { _ = try await convert(imagePDF, .pdf, .txt, "scan.txt"); fatalError("Empty scanned text reported as success") } catch { }
        let protected = url("protected.pdf")
        precondition(mergedDoc.write(to: protected, withOptions: [.userPasswordOption: "test-password", .ownerPasswordOption: "owner-password"]))
        do { _ = try await convert(protected, .pdf, .png, "locked.png"); fatalError("Locked PDF accepted") } catch { }
        let mixed = url("mixed.pdf")
        try PDFOps.merge([imagePDF, pdf], to: mixed)
        let mixedDocx = try await convert(mixed, .pdf, .docx, "mixed.docx")
        let mixedXML = try await Shell.run("/usr/bin/unzip", ["-p", mixedDocx.path, "word/document.xml"])
        precondition(mixedXML.stdout.range(of: "<w:drawing>")!.lowerBound < mixedXML.stdout.range(of: "Open Tangerine")!.lowerBound)
        precondition(mixedXML.stdout.contains("w:type=\"page\""))
        print("PASS mixed scanned/text PDF -> DOCX preserves page order and breaks")
        print("PASS PDF merge/reorder/rotate, images-to-PDF, multipage export, scanned DOCX, scanned/locked rejection")
        let srt = "1\n00:00:01,250 --> 00:00:03,000\nHello <i>world</i>\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond cue\n"
        try srt.write(to: url("captions.srt"), atomically: true, encoding: .utf8)
        let vtt = try await convert(url("captions.srt"), .srt, .vtt, "captions.vtt")
        let roundtrip = try await convert(vtt, .vtt, .srt, "roundtrip.srt")
        let cues = SubtitleParser.parse(try String(contentsOf: roundtrip, encoding: .utf8), hint: .srt)
        precondition(cues.count == 2 && cues[0].start == 1.25 && cues[1].end == 5)
        for (source, format) in [(url("captions.srt"), FileFormat.srt), (vtt, .vtt)] {
            let out = try await convert(source, format, .txt, "\(format).txt")
            precondition(try! String(contentsOf: out, encoding: .utf8).contains("Hello world"))
        }
        precondition(SubtitleParser.format(59.9999, separator: ",") == "00:01:00,000")
        precondition(SubtitleParser.parseTimestamp("nan") == nil)
        print("PASS SRT/VTT round trip + both TXT exports; millisecond carry and invalid timestamp")

        // A styled A4 page with a photo on it, like a typical report. Named fonts, as real PDFs embed them;
        // the system UI font cannot be mapped back from a PDF.
        let styled = url("styled.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(styled as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(try ImageIOBridge.load(url("text.jpg")), in: CGRect(x: 60, y: 300, width: 300, height: 200))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "Quarterly Report", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 28)!, .foregroundColor: NSColor(srgbRed: 0.82, green: 0.27, blue: 0.12, alpha: 1)]).draw(at: CGPoint(x: 60, y: 760))
        NSAttributedString(string: "Plain body text", attributes: [.font: NSFont(name: "Georgia", size: 12)!]).draw(at: CGPoint(x: 60, y: 720))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let builtIn = try await convert(styled, .pdf, .docx, "styled-builtin.docx")
        let builtInXML = try await Shell.run("/usr/bin/unzip", ["-p", builtIn.path, "word/document.xml"]).stdout
        let builtInFiles = try await Shell.run("/usr/bin/unzip", ["-l", builtIn.path]).stdout
        precondition(builtInXML.contains("Quarterly Report") && builtInXML.contains("Plain body text"), "text kept")
        precondition(builtInXML.contains("<w:b/>") && builtInXML.contains("<w:color w:val=") && builtInXML.contains("<w:sz w:val=\"56\"/>"), "bold, colour and 28pt size kept")
        precondition(builtInXML.contains("w:w=\"11900\" w:h=\"16840\""), "A4 page size kept")
        precondition(builtInXML.contains("<w:drawing>") && builtInFiles.contains("word/media/image1."), "photo on a text page kept")
        print("PASS built-in PDF -> DOCX keeps styling, page size and images on text pages")

        if ExternalTool.pdf2docx.isAvailable {
            PDFToDocx.allowExternalTool = true
            let viaTool = try await convert(styled, .pdf, .docx, "styled-pdf2docx.docx")
            let toolXML = try await Shell.run("/usr/bin/unzip", ["-p", viaTool.path, "word/document.xml"]).stdout
            precondition(toolXML.contains("Quarterly Report") && toolXML.contains("<w:drawing>") && toolXML.contains("<w:b/>"), "pdf2docx layout")
            print("PASS pdf2docx PDF -> DOCX keeps text, styling and images")
        } else {
            print("SKIP pdf2docx not installed")
        }
    }
}
