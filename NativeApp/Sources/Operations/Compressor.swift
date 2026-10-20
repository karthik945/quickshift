import AVFoundation
import Foundation
import ImageIO

enum Compressor {
    /// Set while the Compress window measures each level; tools then run at low priority with quicker settings.
    @TaskLocal static var isEstimating = false

    static func compress(_ url: URL, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let format = FileFormat.detect(url) else { throw OpenTangerineError.unreadable(url) }
        if preset == .lossless && targetBytes == nil {
            try await compressLossless(url, format: format, to: destination)
            progress(1)
            return
        }
        switch format.category {
        case .image:
            try await compressImage(url, format: format, preset: preset, resizeLongEdge: resizeLongEdge, targetBytes: targetBytes, to: destination, progress: progress)
        case .video:
            try await VideoOps.compress(url, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .audio:
            try await compressAudio(url, format: format, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .document where format == .pdf:
            try await compressPDF(url, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
            progress(1)
        default:
            throw OpenTangerineError.invalidInput("\(format.displayName) files can't be compressed. Convert to ZIP instead.")
        }
    }

    static let losslessFormats: Set<FileFormat> = [.png, .jpg, .pdf]

    static func supportsLossless(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { FileFormat.detect($0).map(losslessFormats.contains) ?? false }
    }

    static func outputFormat(for url: URL, preset: CompressionPreset) -> FileFormat {
        if preset == .lossless, let format = FileFormat.detect(url), losslessFormats.contains(format) { return format }
        return outputFormat(for: url)
    }

    /// Re-packs the file without touching pixels or page content. The result is never larger than the original.
    static func compressLossless(_ url: URL, format: FileFormat, to destination: URL) async throws {
        switch format {
        case .png:
            try await ExternalTool.oxipng.run(["-o", isEstimating ? "2" : "4", "--strip", "safe", "--out", destination.path, url.path], purpose: "Lossless PNG compression")
        case .jpg:
            // Strip metadata only when nothing visible depends on it: no EXIF rotation and no non-sRGB color profile.
            let properties = ImageIOBridge.properties(url)
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let profile = properties[kCGImagePropertyProfileName] as? String
            let strip = orientation == 1 && (profile == nil || profile!.contains("sRGB"))
            try await ExternalTool.jpegtran.run(["-copy", strip ? "none" : "all", "-optimize", "-progressive", "-outfile", destination.path, url.path], purpose: "Lossless JPEG compression")
        case .pdf:
            // qpdf exits with 3 when it succeeded but repaired warnings in the source.
            try await ExternalTool.qpdf.run(
                ["--object-streams=generate", "--compress-streams=y", "--recompress-flate", "--compression-level=9", "--remove-unreferenced-resources=yes", url.path, destination.path],
                purpose: "Lossless PDF compression", acceptedStatuses: [0, 3]
            )
        default:
            throw OpenTangerineError.invalidInput("Lossless compression supports PNG, JPEG and PDF files.")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) || FileSizeFormatter.size(of: destination) >= FileSizeFormatter.size(of: url) {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: url, to: destination)
        }
    }

    static func outputFormat(for url: URL) -> FileFormat {
        guard let format = FileFormat.detect(url) else { return .jpg }
        switch format.category {
        case .image:
            switch format {
            case .png:
                if let image = try? ImageIOBridge.load(url), image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst { return .png }
                return .jpg
            case .bmp, .tiff, .svg: return .jpg
            case .avif, .webp: return ImageIOBridge.canEncodeNatively(format) || FFmpeg.isAvailable ? format : .jpg
            default: return format
            }
        case .video:
            return VideoEngine.nativeTargets.contains(format) ? format : .mp4
        case .audio:
            return format == .mp3 && FFmpeg.isAvailable ? .mp3 : .m4a
        default:
            return format
        }
    }

    static func compressImage(_ url: URL, format: FileFormat, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        var image = try ImageIOBridge.load(url)
        if resizeLongEdge > 0 { image = ImageIOBridge.resized(image, longEdge: resizeLongEdge) }
        let output = outputFormat(for: url)
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst
        let finalFormat: FileFormat = (output == .jpg && hasAlpha && format == .png) ? .png : output
        progress(0.2)

        guard let targetBytes else {
            if finalFormat == .png {
                let scaled = preset == .strong ? ImageIOBridge.resized(image, longEdge: Int(Double(max(image.width, image.height)) * 0.7)) : image
                try ImageIOBridge.write(scaled, to: destination, format: .png)
            } else {
                try await ImageIOBridge.writeAnyFormat(image, to: destination, format: finalFormat, quality: preset.imageQuality)
            }
            progress(1)
            return
        }

        guard targetBytes > 0 else { throw OpenTangerineError.invalidInput("Target size must be greater than zero.") }
        // Prefer a lossless re-pack when it already fits, so quality is only reduced when needed.
        if resizeLongEdge == 0, finalFormat == format, losslessFormats.contains(format), (try? await compressLossless(url, format: format, to: destination)) != nil {
            if FileSizeFormatter.size(of: destination) <= targetBytes { progress(1); return }
            try? FileManager.default.removeItem(at: destination)
        }
        if resizeLongEdge == 0, finalFormat == format, FileSizeFormatter.size(of: url) <= targetBytes {
            try FileManager.default.copyItem(at: url, to: destination)
            progress(1)
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-fit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fitted = finalFormat == .png
            ? try await fitPNG(image, targetBytes: targetBytes, in: directory, progress: progress)
            : try await fitLossyImage(image, format: finalFormat, targetBytes: targetBytes, in: directory, progress: progress)
        try FileManager.default.moveItem(at: fitted, to: destination)
        progress(1)
    }

    /// Lowest JPEG/WebP/HEIC quality used before resizing instead: below this, blocking looks worse than fewer pixels.
    static let imageQualityFloor = 0.5

    /// Best-quality encode at or under the target. Quality is searched first; when even the floor
    /// quality is too large, the image is resized in one estimated jump (size scales with pixel area).
    static func fitLossyImage(_ image: CGImage, format: FileFormat, targetBytes: Int64, in directory: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        var candidate = image
        var smallest: (url: URL, size: Int64)?
        var encodes = 0
        func encode(_ quality: Double) async throws -> (url: URL, size: Int64) {
            try Task.checkCancellation()
            encodes += 1
            let url = directory.appendingPathComponent("q\(encodes).\(format.fileExtension)")
            try await ImageIOBridge.writeAnyFormat(candidate, to: url, format: format, quality: quality)
            let size = FileSizeFormatter.size(of: url)
            if smallest == nil || size < smallest!.size { smallest = (url, size) }
            progress(min(0.95, 0.2 + 0.05 * Double(encodes)))
            return (url, size)
        }
        for _ in 0..<6 {
            let top = try await encode(0.95)
            if top.size <= targetBytes { return top.url }
            let floor = try await encode(imageQualityFloor)
            guard floor.size <= targetBytes else {
                let ratio = min(0.95, (Double(targetBytes) * 0.9 / Double(floor.size)).squareRoot())
                let width = Double(candidate.width) * ratio, height = Double(candidate.height) * ratio
                guard width >= 16, height >= 16 else { break }
                candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: width, height: height))
                continue
            }
            var best = floor
            var low = imageQualityFloor, high = 0.95
            for _ in 0..<7 where Double(best.size) < Double(targetBytes) * 0.92 {
                let attempt = try await encode((low + high) / 2)
                if attempt.size <= targetBytes { best = attempt; low = (low + high) / 2 } else { high = (low + high) / 2 }
            }
            return best.url
        }
        guard let smallest else { throw OpenTangerineError.encodeFailed("image") }
        return smallest.url
    }

    /// PNG has no quality setting, so transparent images reach the target by resizing alone.
    static func fitPNG(_ image: CGImage, targetBytes: Int64, in directory: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        var candidate = image
        var smallest: (url: URL, size: Int64)?
        for pass in 0..<8 {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("png\(pass).png")
            try ImageIOBridge.write(candidate, to: url, format: .png)
            if ExternalTool.oxipng.isAvailable {
                try? await ExternalTool.oxipng.run(["-o", "2", "--strip", "safe", url.path], purpose: "PNG optimization")
            }
            let size = FileSizeFormatter.size(of: url)
            if smallest == nil || size < smallest!.size { smallest = (url, size) }
            progress(min(0.95, 0.2 + 0.1 * Double(pass + 1)))
            if size <= targetBytes { return url }
            let ratio = min(0.95, (Double(targetBytes) * 0.92 / Double(size)).squareRoot())
            let width = Double(candidate.width) * ratio, height = Double(candidate.height) * ratio
            guard width >= 16, height >= 16 else { break }
            candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: width, height: height))
        }
        guard let smallest else { throw OpenTangerineError.encodeFailed("PNG") }
        return smallest.url
    }

    static func compressPDF(_ url: URL, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        guard ExternalTool.ghostscript.isAvailable else {
            if targetBytes != nil { throw OpenTangerineError.toolMissing(tool: "gs", package: "ghostscript", purpose: "Compressing a PDF to a target size") }
            try PDFOps.compress(url, strong: preset == .strong, to: destination)
            return
        }
        guard let targetBytes else {
            try await ghostscriptPDF(url, step: preset == .strong ? (96, 0.76) : (150, 0.4), to: destination)
            if FileSizeFormatter.size(of: destination) >= FileSizeFormatter.size(of: url) {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: url, to: destination)
            }
            return
        }
        guard targetBytes > 0 else { throw OpenTangerineError.invalidInput("Target size must be greater than zero.") }
        if ExternalTool.qpdf.isAvailable {
            try await compressLossless(url, format: .pdf, to: destination)
        } else {
            try fm.copyItem(at: url, to: destination)
        }
        if FileSizeFormatter.size(of: destination) <= targetBytes { return }
        try? fm.removeItem(at: destination)
        progress(0.1)

        let directory = fm.temporaryDirectory.appendingPathComponent("opentangerine-pdf-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        var attempts = 0
        let report: () -> Void = { attempts += 1; progress(min(0.98, 0.1 + 0.06 * Double(attempts))) }

        // Stage 1 keeps text and vectors sharp and only shrinks embedded images.
        let vector = try await fitPDF(targetBytes: targetBytes, in: directory, name: "vector", attempt: report) { loss, output in
            try await ghostscriptPDF(url, step: vectorStep(loss), to: output)
            try await repackPDF(output)
        }
        if let fit = vector.fit {
            try fm.moveItem(at: fit, to: destination)
            return
        }
        // Stage 2: text-heavy PDFs have no images left to shrink. A target is a promise, so pages are
        // saved as images. Lossless (Flate) page images keep letter edges clean and stay small for text.
        let flate = try await fitPDF(targetBytes: targetBytes, in: directory, name: "flate", attempt: report) { loss, output in
            try await rasterizedPDF(url, dpi: flateDPI(loss), jpegQuality: nil, to: output)
            try await repackPDF(output)
        }
        if let fit = flate.fit {
            try fm.moveItem(at: fit, to: destination)
            return
        }
        // Stage 3: photo-heavy pages compress better as JPEG.
        let jpeg = try await fitPDF(targetBytes: targetBytes, in: directory, name: "jpeg", attempt: report) { loss, output in
            let step = rasterStep(loss)
            try await rasterizedPDF(url, dpi: step.dpi, jpegQuality: step.jpegQuality, to: output)
        }
        let chosen = jpeg.fit ?? [vector.smallest, flate.smallest, jpeg.smallest].min { $0.size < $1.size }!.url
        try fm.moveItem(at: chosen, to: destination)
    }

    /// qpdf object streams squeeze a few more percent out of Ghostscript output; kept only when smaller.
    static func repackPDF(_ url: URL) async throws {
        guard ExternalTool.qpdf.isAvailable else { return }
        let packed = url.deletingLastPathComponent().appendingPathComponent("packed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: packed) }
        guard (try? await compressLossless(url, format: .pdf, to: packed)) != nil,
              FileSizeFormatter.size(of: packed) < FileSizeFormatter.size(of: url) else { return }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: packed)
    }

    static func flateDPI(_ loss: Double) -> Int {
        Int((200 * pow(50.0 / 200, loss)).rounded())
    }

    /// Continuous loss scale from 0 (gentlest) to 1 (strongest), so a search can land just under the target.
    static func vectorStep(_ loss: Double) -> (dpi: Int, qFactor: Double) {
        (Int((300 * pow(45.0 / 300, loss)).rounded()), 0.15 + 1.65 * loss)
    }

    static func rasterStep(_ loss: Double) -> (dpi: Int, jpegQuality: Int) {
        (Int((150 * pow(36.0 / 150, loss)).rounded()), Int((75 - 50 * loss).rounded()))
    }

    /// Finds the least loss that fits: checks the strongest setting first, then bisects and stops
    /// once a fitting result is within 90% of the target.
    static func fitPDF(targetBytes: Int64, in directory: URL, name: String, attempt: () -> Void,
                       render: (Double, URL) async throws -> Void) async throws -> (fit: URL?, smallest: (url: URL, size: Int64)) {
        var index = 0
        func run(_ loss: Double) async throws -> (url: URL, size: Int64) {
            try Task.checkCancellation()
            index += 1
            let output = directory.appendingPathComponent("\(name)-\(index).pdf")
            try await render(loss, output)
            attempt()
            return (output, FileSizeFormatter.size(of: output))
        }
        let strongest = try await run(1)
        guard strongest.size <= targetBytes else { return (nil, strongest) }
        var best = strongest
        var low = 0.0, high = 1.0
        for _ in 0..<6 where Double(best.size) < Double(targetBytes) * 0.9 {
            let mid = (low + high) / 2
            let result = try await run(mid)
            if result.size <= targetBytes { best = result; high = mid } else { low = mid }
        }
        return (best.url, strongest)
    }

    /// Saves each page as one image: JPEG at the given quality, or lossless Flate when quality is nil.
    static func rasterizedPDF(_ url: URL, dpi: Int, jpegQuality: Int?, to destination: URL) async throws {
        let encoding = jpegQuality.map { ["-sCompression=JPEG", "-dJPEGQ=\($0)"] } ?? ["-sCompression=Flate"]
        try await ExternalTool.ghostscript.run(
            ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=pdfimage24", "-r\(dpi)"] + encoding + ["-o", destination.path, url.path],
            purpose: "Compressing PDF"
        )
    }

    /// The smallest a PDF can get without rasterizing pages: lossless re-pack or the most aggressive image step.
    static func smallestPDFSize(_ url: URL, in directory: URL) async throws -> Int64 {
        var smallest = FileSizeFormatter.size(of: url)
        if ExternalTool.qpdf.isAvailable {
            let lossless = directory.appendingPathComponent("min-lossless-\(UUID().uuidString).pdf")
            try await compressLossless(url, format: .pdf, to: lossless)
            smallest = min(smallest, FileSizeFormatter.size(of: lossless))
            try? FileManager.default.removeItem(at: lossless)
        }
        let strongest = directory.appendingPathComponent("min-step-\(UUID().uuidString).pdf")
        try await ghostscriptPDF(url, step: vectorStep(1), to: strongest)
        try await repackPDF(strongest)
        smallest = min(smallest, FileSizeFormatter.size(of: strongest))
        try? FileManager.default.removeItem(at: strongest)
        return smallest
    }

    static func ghostscriptPDF(_ url: URL, step: (dpi: Int, qFactor: Double), to destination: URL) async throws {
        let sampling = "/QFactor \(step.qFactor) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2]"
        try await ExternalTool.ghostscript.run([
            "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6",
            "-dDetectDuplicateImages=true", "-dCompressFonts=true", "-dSubsetFonts=true",
            "-dDownsampleColorImages=true", "-dDownsampleGrayImages=true", "-dDownsampleMonoImages=true",
            "-dColorImageDownsampleType=/Bicubic", "-dGrayImageDownsampleType=/Bicubic",
            "-dColorImageDownsampleThreshold=1.0", "-dGrayImageDownsampleThreshold=1.0",
            "-dColorImageResolution=\(step.dpi)", "-dGrayImageResolution=\(step.dpi)", "-dMonoImageResolution=\(max(step.dpi * 2, 300))",
            "-o", destination.path,
            "-c", "<< /ColorACSImageDict << \(sampling) >> /GrayACSImageDict << \(sampling) >> >> setdistillerparams",
            "-f", url.path,
        ], purpose: "Compressing PDF")
    }

    static func compressAudio(_ url: URL, format: FileFormat, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        var bitrate = preset.audioBitrate
        if let targetBytes, info.duration > 0 {
            bitrate = max(32_000, min(320_000, Int(Double(targetBytes) * 8 * 0.96 / info.duration)))
        }
        let output = outputFormat(for: url)
        if output == .m4a, !FFmpeg.isAvailable, await MediaInfo.isNativelyReadable(url) {
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, progress: progress)
            return
        }
        try await AudioEngine.ffmpegConvert(source: url, destination: destination, target: output, bitrate: bitrate, progress: progress)
    }
}

