import Foundation

/// Optional command-line tools used for design files and lossless compression.
/// Like FFmpeg, none are bundled; Settings → Formats shows which are installed.
enum ExternalTool: String, CaseIterable, Identifiable {
    case pdftocairo
    case ghostscript
    case oxipng
    case qpdf
    case jpegtran
    case pngquant
    case mozjpeg
    case svgo
    case pdf2docx

    var id: String { rawValue }

    var executable: String {
        switch self {
        case .ghostscript: return "gs"
        case .mozjpeg: return "cjpeg"
        default: return rawValue
        }
    }

    var package: String {
        switch self {
        case .pdftocairo: return "poppler"
        case .ghostscript: return "ghostscript"
        case .oxipng: return "oxipng"
        case .qpdf: return "qpdf"
        case .jpegtran: return "jpeg"
        case .pngquant: return "pngquant"
        case .mozjpeg: return "mozjpeg"
        case .svgo: return "svgo"
        case .pdf2docx: return "pdf2docx"
        }
    }

    /// pdf2docx is a Python tool, so it installs with pipx rather than Homebrew.
    var installCommand: String {
        self == .pdf2docx ? "brew install pipx && pipx install pdf2docx" : "brew install \(package)"
    }

    var usage: String {
        switch self {
        case .pdftocairo: return "Illustrator and EPS to vector SVG"
        case .ghostscript: return "EPS and legacy Illustrator files"
        case .oxipng: return "Lossless PNG compression"
        case .qpdf: return "Lossless PDF compression"
        case .jpegtran: return "Lossless JPEG compression"
        case .pngquant: return "Smaller PNGs that keep their size and transparency"
        case .mozjpeg: return "Sharper JPEGs at the same file size"
        case .svgo: return "SVG optimization; cleaner SVGs from Illustrator and EPS"
        case .pdf2docx: return "PDF to Word that keeps layout, images and tables"
        }
    }

    var path: String? {
        // mozjpeg's cjpeg shares its name with libjpeg's, so only its own keg-only location counts.
        if self == .mozjpeg {
            return ["/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        // Homebrew installs libjpeg's tools keg-only, outside the usual bin directories.
        let extra = self == .jpegtran ? ["/opt/homebrew/opt/jpeg/bin/jpegtran", "/usr/local/opt/jpeg/bin/jpegtran"] : []
        return Shell.which(executable, extra: extra)
    }

    var isAvailable: Bool { path != nil }

    @discardableResult
    func run(_ arguments: [String], purpose: String, acceptedStatuses: Set<Int32> = [0]) async throws -> ShellResult {
        guard let path else { throw OpenTangerineError.toolMissing(tool: executable, install: installCommand, purpose: purpose) }
        DiagnosticLog.log("\(executable) \(arguments.joined(separator: " "))")
        // Size estimates run in the background and must never compete with the user's own work.
        let result = try await Shell.run(path, arguments, qualityOfService: Compressor.isEstimating ? .utility : nil)
        guard acceptedStatuses.contains(result.status) else {
            throw OpenTangerineError.toolFailed(executable, FFmpeg.summarize(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return result
    }
}
