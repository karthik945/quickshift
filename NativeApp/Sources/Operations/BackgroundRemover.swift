import CoreImage
import Foundation
import Vision

/// Cuts the subject out of a photo with Apple's on-device Vision model and saves a transparent PNG.
/// Nothing leaves the Mac and no AI service or key is involved.
enum BackgroundRemover {
    static func removeBackground(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void = { _ in }) async throws {
        let image = try ImageIOBridge.load(url)
        progress(0.2)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw OpenTangerineError.invalidInput("No clear subject found in \(url.lastPathComponent). Background removal works best when a person, animal or object stands out from the background.")
        }
        progress(0.7)
        let masked = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let output = CIImage(cvPixelBuffer: masked)
        guard let cutout = CIContext().createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw OpenTangerineError.encodeFailed(destination.lastPathComponent)
        }
        try ImageIOBridge.write(cutout, to: destination, format: .png)
        progress(1)
    }

    /// Runs straight from the wheel without a window: one transparent PNG per image.
    @MainActor static func run(_ files: [URL]) {
        let settings = AppSettings.shared
        for url in files {
            let destination = ConversionMatrix.uniqueURL(
                directory: settings.outputLocation.directory(for: url),
                baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent),
                suffix: "no background", ext: FileFormat.png.fileExtension
            )
            JobRunner.shared.run(title: ToolID.removeBackground.progressTitle, detail: url.lastPathComponent, symbol: ToolID.removeBackground.symbol) { progress in
                try await removeBackground(url, to: destination, progress: progress)
                return [destination]
            }
        }
    }
}
