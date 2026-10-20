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
        if finalFormat == .png {
            var candidate = image
            for attempt in 0..<12 {
                try ImageIOBridge.write(candidate, to: destination, format: .png)
                if FileSizeFormatter.size(of: destination) <= targetBytes { progress(1); return }
                guard candidate.width > 1 && candidate.height > 1 else { break }
                candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: max(1, Double(candidate.width) * 0.8), height: max(1, Double(candidate.height) * 0.8)))
                progress(0.2 + 0.7 * Double(attempt + 1) / 12)
            }
            throw OpenTangerineError.invalidInput("The requested size is too small while preserving PNG transparency. Choose a larger target size.")
        }
        var low = 0.15, high = 0.95
        var candidate = image
        var attempts = 0
        var best: Double?
        while attempts < 12 {
            attempts += 1
            let quality = (low + high) / 2
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat, quality: quality)
            let size = FileSizeFormatter.size(of: destination)
            progress(0.2 + 0.7 * Double(attempts) / 12)
            if size <= targetBytes {
                best = quality
                low = quality
                if Double(size) > Double(targetBytes) * 0.9 { break }
            } else {
                high = quality
            }
            if high - low < 0.03 {
                if best == nil {
                    let shrink = 0.8
                    candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: Double(candidate.width) * shrink, height: Double(candidate.height) * shrink))
                    low = 0.15
                    high = 0.95
                    guard candidate.width > 64 else { break }
                } else {
                    break
                }
            }
        }
        if let best {
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat, quality: best)
        }
        progress(1)
    }

    /// Image downsampling (DPI) and JPEG QFactor steps, from least to most loss. Text and vectors stay sharp at every step.
    static let pdfSteps: [(dpi: Int, qFactor: Double)] = [(300, 0.15), (220, 0.25), (150, 0.4), (120, 0.6), (96, 0.76), (72, 1.0), (60, 1.3), (45, 1.8)]

    static func compressPDF(_ url: URL, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        guard ExternalTool.ghostscript.isAvailable else {
            if targetBytes != nil { throw OpenTangerineError.toolMissing(tool: "gs", package: "ghostscript", purpose: "Compressing a PDF to a target size") }
            try PDFOps.compress(url, strong: preset == .strong, to: destination)
            return
        }
        guard let targetBytes else {
            try await ghostscriptPDF(url, step: pdfSteps[preset == .strong ? 4 : 2], to: destination)
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

        // Binary search for the least lossy step that fits; keep the smallest attempt if none does.
        let directory = fm.temporaryDirectory.appendingPathComponent("opentangerine-pdf-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        var low = 0, high = pdfSteps.count - 1, attempts = 0
        var best: URL?
        var smallest: (url: URL, size: Int64)?
        while low <= high {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let candidate = directory.appendingPathComponent("step-\(mid).pdf")
            try await ghostscriptPDF(url, step: pdfSteps[mid], to: candidate)
            let size = FileSizeFormatter.size(of: candidate)
            if smallest == nil || size < smallest!.size { smallest = (candidate, size) }
            if size <= targetBytes { best = candidate; high = mid - 1 } else { low = mid + 1 }
            attempts += 1
            progress(0.1 + 0.85 * Double(attempts) / 4)
        }
        if let best {
            try fm.moveItem(at: best, to: destination)
            return
        }

        // Text-heavy PDFs have no images left to shrink. A target is a promise, so fall back to
        // saving pages as JPEG images, searching for the sharpest rendering that still fits.
        low = 0
        high = pdfRasterSteps.count - 1
        attempts = 0
        var rasterBest: URL?
        while low <= high {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let candidate = directory.appendingPathComponent("raster-\(mid).pdf")
            try await rasterizedPDF(url, step: pdfRasterSteps[mid], to: candidate)
            let size = FileSizeFormatter.size(of: candidate)
            if size < smallest!.size { smallest = (candidate, size) }
            if size <= targetBytes { rasterBest = candidate; high = mid - 1 } else { low = mid + 1 }
            attempts += 1
            progress(min(0.98, 0.5 + 0.45 * Double(attempts) / 4))
        }
        guard let chosen = rasterBest ?? smallest?.url else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        try fm.moveItem(at: chosen, to: destination)
    }

    /// Page rendering (DPI) and JPEG quality steps for the image-only fallback, from sharpest to smallest.
    static let pdfRasterSteps: [(dpi: Int, jpegQuality: Int)] = [(150, 75), (130, 65), (110, 55), (96, 50), (85, 45), (72, 40), (60, 35), (50, 30), (40, 25)]

    static func rasterizedPDF(_ url: URL, step: (dpi: Int, jpegQuality: Int), to destination: URL) async throws {
        try await ExternalTool.ghostscript.run([
            "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=pdfimage24",
            "-r\(step.dpi)", "-sCompression=JPEG", "-dJPEGQ=\(step.jpegQuality)",
            "-o", destination.path, url.path,
        ], purpose: "Compressing PDF")
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
        try await ghostscriptPDF(url, step: pdfSteps[pdfSteps.count - 1], to: strongest)
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

