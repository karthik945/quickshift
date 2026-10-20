import AppKit
import ImageIO

@main struct DesignTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTangerine-design-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func rgba(_ image: CGImage) -> [UInt8] {
            let c = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
        }

        // A PDF-compatible Illustrator file is a PDF with an .ai extension: 200 × 100 pt, one vector shape.
        let ai = root.appendingPathComponent("logo.ai")
        var box = CGRect(x:0,y:0,width:200,height:100)
        let pdf = CGContext(ai as CFURL, mediaBox:&box, nil)!
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(red:0.9,green:0.4,blue:0.1,alpha:1)); pdf.fillEllipse(in:CGRect(x:20,y:10,width:80,height:80))
        pdf.endPDFPage(); pdf.closePDF()
        precondition(DesignFiles.isPDF(ai))

        var sources: [(FileFormat, URL)] = [(.ai, ai)]
        if ExternalTool.ghostscript.isAvailable {
            let eps = root.appendingPathComponent("logo.eps")
            try await ExternalTool.ghostscript.run(["-dSAFER","-dBATCH","-dNOPAUSE","-dQUIET","-sDEVICE=eps2write","-o",eps.path,ai.path], purpose:"EPS fixture")
            sources.append((.eps, eps))
        } else { print("SKIP EPS: ghostscript unavailable") }

        for (format, source) in sources {
            // EPS crops to its bounding box (the circle); the AI keeps its 200 × 100 artboard.
            let expected = format == .eps ? CGSize(width: 80, height: 80) : CGSize(width: 200, height: 100)
            for target in ConversionMatrix.targets(for: format) {
                if target == .svg && !ExternalTool.pdftocairo.isAvailable { print("SKIP \(format) -> SVG: pdftocairo unavailable"); continue }
                if target == .heic && !ImageIOBridge.canEncodeNatively(.heic) { continue }
                let output = root.appendingPathComponent("\(format)-to-\(target).\(target.fileExtension)")
                try await Engines.convert(ConversionRequest(source:source,sourceFormat:format,target:target,destination:output,progress:{_ in}))
                switch target {
                case .svg:
                    let svg = try String(contentsOf: output, encoding: .utf8)
                    precondition(svg.contains("<svg") && svg.contains("<path"), "\(format) SVG has vector paths")
                case .eps:
                    let header = try Data(contentsOf: output).prefix(11)
                    precondition(header == Data("%!PS-Adobe-".utf8), "\(format) EPS header")
                case .pdf:
                    let page = CGPDFDocument(output as CFURL)!.page(at: 1)!.getBoxRect(.mediaBox)
                    precondition(abs(page.width - expected.width) < 2 && abs(page.height - expected.height) < 2, "\(format) PDF keeps artboard size, got \(page)")
                default:
                    let image = try ImageIOBridge.load(output)
                    precondition(abs(Double(image.width) / Double(image.height) - expected.width / expected.height) < 0.05, "\(format) -> \(target) aspect ratio")
                }
                count += 1
                print("PASS \(format) -> \(target)")
            }
        }

        // Minimal uncompressed 3-channel RGB Photoshop file: left half red, right half blue.
        let psd = root.appendingPathComponent("art.psd")
        let (pw, ph) = (40, 20)
        var data = Data("8BPS".utf8)
        func be16(_ v: Int) { data.append(contentsOf: [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        func be32(_ v: Int) { be16(v >> 16); be16(v & 0xffff) }
        be16(1); data.append(contentsOf: [UInt8](repeating: 0, count: 6)); be16(3); be32(ph); be32(pw); be16(8); be16(3)
        be32(0); be32(0); be32(0); be16(0)
        for channel in 0..<3 {
            for _ in 0..<ph { for x in 0..<pw { data.append((channel == 0 && x < pw/2) || (channel == 2 && x >= pw/2) ? 255 : 0) } }
        }
        try data.write(to: psd)
        for target in ConversionMatrix.targets(for: .psd) {
            if target == .heic && !ImageIOBridge.canEncodeNatively(.heic) { continue }
            if target == .avif && !ImageIOBridge.canEncodeNatively(.avif) && !FFmpeg.isAvailable { continue }
            let output = root.appendingPathComponent("psd-to-\(target).\(target.fileExtension)")
            try await Engines.convert(ConversionRequest(source:psd,sourceFormat:.psd,target:target,destination:output,progress:{_ in}))
            if target != .pdf {
                let image = try ImageIOBridge.load(output)
                precondition(image.width == pw && image.height == ph, "PSD -> \(target) dimensions")
                if target == .png {
                    let px = rgba(image)
                    precondition(px[0] > 240 && px[2] < 15 && px[(pw-1)*4+2] > 240, "PSD colors survive")
                }
            }
            count += 1
            print("PASS psd -> \(target)")
        }

        // Lossless compression keeps pixels and pages identical and never grows the file.
        let noisy = CGContext(data:nil,width:120,height:90,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<12 { noisy.setFillColor(CGColor(red:Double(i)/12,green:0.5,blue:1-Double(i)/12,alpha:1)); noisy.fill(CGRect(x:i*10,y:0,width:10,height:90)) }
        let image = noisy.makeImage()!
        let png = root.appendingPathComponent("plain.png"), jpg = root.appendingPathComponent("photo.jpg")
        try ImageIOBridge.write(image, to: png, format: .png)
        try ImageIOBridge.write(image, to: jpg, format: .jpg, quality: 0.9)
        let plainPDF = root.appendingPathComponent("plain.pdf")
        try FileManager.default.copyItem(at: ai, to: plainPDF)
        for (source, tool) in [(png, ExternalTool.oxipng), (jpg, .jpegtran), (plainPDF, .qpdf)] {
            guard tool.isAvailable else { print("SKIP lossless \(source.pathExtension): \(tool.executable) unavailable"); continue }
            let format = FileFormat.detect(source)!
            let output = root.appendingPathComponent("lossless-\(source.lastPathComponent).\(Compressor.outputFormat(for: source, preset: .lossless).fileExtension)")
            try await Compressor.compress(source, preset: .lossless, resizeLongEdge: 0, targetBytes: nil, to: output) { _ in }
            precondition(FileSizeFormatter.size(of: output) <= FileSizeFormatter.size(of: source), "lossless never grows")
            if format == .pdf {
                precondition(CGPDFDocument(output as CFURL)?.numberOfPages == 1, "PDF pages kept")
            } else {
                let before = try ImageIOBridge.load(source), after = try ImageIOBridge.load(output)
                precondition(rgba(before) == rgba(after), "\(format) pixels identical")
            }
            count += 1
            print("PASS lossless \(source.pathExtension) \(FileSizeFormatter.size(of: source)) -> \(FileSizeFormatter.size(of: output)) bytes")
        }
        precondition(Compressor.supportsLossless([png, jpg]) && !Compressor.supportsLossless([png, root.appendingPathComponent("a.mp4")]))
        precondition(Compressor.outputFormat(for: png, preset: .lossless) == .png && Compressor.outputFormat(for: jpg, preset: .lossless) == .jpg)
        // Target size: a photo-heavy PDF must land under the target with its page intact.
        if ExternalTool.ghostscript.isAvailable {
            let w = 1400, h = 1000
            let photo = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            var seed: UInt64 = 42
            for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                photo.setFillColor(CGColor(red: Double(seed >> 56) / 255, green: Double(x) / Double(w), blue: Double(y) / Double(h), alpha: 1))
                photo.fill(CGRect(x: x, y: y, width: 4, height: 4))
            } }
            let heavy = root.appendingPathComponent("scan.pdf")
            try ImageIOBridge.writePDF(images: [photo.makeImage()!], to: heavy)
            let original = FileSizeFormatter.size(of: heavy), target = original / 5
            let output = root.appendingPathComponent("scan-target.pdf")
            try await Compressor.compress(heavy, preset: .balanced, resizeLongEdge: 0, targetBytes: target, to: output) { _ in }
            precondition(FileSizeFormatter.size(of: output) <= target, "PDF target \(target) reached, got \(FileSizeFormatter.size(of: output))")
            precondition(CGPDFDocument(output as CFURL)?.numberOfPages == 1, "PDF target keeps pages")
            count += 1
            print("PASS pdf target \(original) -> \(FileSizeFormatter.size(of: output)) bytes (target \(target))")
        }
        // Text-only PDFs have no images to shrink; a target below their floor falls back to page images.
        if ExternalTool.ghostscript.isAvailable {
            let text = root.appendingPathComponent("letter.pdf")
            var page = CGRect(x: 0, y: 0, width: 595, height: 842)
            let context = CGContext(text as CFURL, mediaBox: &page, nil)!
            for _ in 0..<2 {
                context.beginPDFPage(nil)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                // Like a Word export: little ink, but many embedded font subsets carry the weight.
                let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 .,;:!?()&%$#@ "
                let fonts = ["Georgia", "Times New Roman", "Helvetica Neue", "Menlo", "Avenir Next", "Baskerville", "Futura", "Didot", "Palatino", "Courier New"]
                for (index, name) in fonts.enumerated() {
                    let font = NSFont(name: name, size: 9) ?? NSFont.systemFont(ofSize: 9)
                    NSAttributedString(string: alphabet + alphabet.uppercased(), attributes: [.font: font]).draw(in: CGRect(x: 40, y: 780 - index * 70, width: 515, height: 60))
                }
                NSGraphicsContext.current = nil
                context.endPDFPage()
            }
            context.closePDF()
            let floor = try await Compressor.smallestPDFSize(text, in: root)
            let target = floor / 2
            let output = root.appendingPathComponent("letter-target.pdf")
            try await Compressor.compress(text, preset: .balanced, resizeLongEdge: 0, targetBytes: target, to: output) { _ in }
            precondition(FileSizeFormatter.size(of: output) <= target, "text PDF reaches target \(target), got \(FileSizeFormatter.size(of: output))")
            precondition(CGPDFDocument(output as CFURL)?.numberOfPages == 2, "text PDF keeps both pages")
            count += 1
            print("PASS text pdf target floor \(floor) -> \(FileSizeFormatter.size(of: output)) bytes (target \(target))")
        }
        print("DESIGN RESULT: \(count) passed")
    }
}
