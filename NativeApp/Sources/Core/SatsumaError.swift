import Foundation

enum OpenTangerineError: LocalizedError {
    case unsupportedConversion(FileFormat, FileFormat)
    case unreadable(URL)
    case encodeFailed(String)
    case ffmpegMissing(String)
    case toolFailed(String, String)
    case toolMissing(tool: String, package: String, purpose: String)
    case cancelled
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedConversion(from, to):
            return "Converting \(from.displayName) to \(to.displayName) is not supported."
        case let .unreadable(url):
            return "Could not read \(url.lastPathComponent)."
        case let .encodeFailed(what):
            return "Could not write \(what)."
        case let .ffmpegMissing(what):
            return "\(what) needs ffmpeg. Install it (for example with `brew install ffmpeg`) or set its path in Settings."
        case let .toolFailed(tool, output):
            return "\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .toolMissing(tool, package, purpose):
            return "\(purpose) needs \(tool). Install it with `brew install \(package)`, then try again."
        case .cancelled:
            return "Cancelled."
        case let .invalidInput(reason):
            return reason
        }
    }
}

