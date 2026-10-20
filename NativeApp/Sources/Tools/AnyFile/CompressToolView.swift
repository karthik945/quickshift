import SwiftUI

@MainActor
struct CompressToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var useTarget = false
    @State private var targetValue: Double = 1
    @State private var targetUnit: SizeUnit = .megabytes
    @State private var resize = 0
    @State private var preset: CompressionPreset = .balanced
    @State private var estimates: [CompressionPreset: Int64] = [:]
    @State private var estimateErrors: [CompressionPreset: String] = [:]
    @State private var estimateIsSampled = false

    enum SizeUnit: String, CaseIterable, Identifiable {
        case kilobytes = "KB"
        case megabytes = "MB"
        var id: String { rawValue }
        var multiplier: Double { self == .kilobytes ? 1_000 : 1_000_000 }
    }

    private static let estimateSampleCount = 3
    private static let quickTargets: [Double] = [100, 200, 500, 1_000, 2_000]

    private var totalSize: Int64 { session.files.reduce(0) { $0 + FileSizeFormatter.size(of: $1) } }
    private var perFileTarget: Int64? {
        guard useTarget else { return nil }
        return Int64(targetValue * targetUnit.multiplier)
    }

    private enum ImageSize: Int, CaseIterable, Identifiable {
        case original = 0
        case large = 2560
        case medium = 1920
        case small = 1280

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .original: return "Original"
            case .large: return "2560 px"
            case .medium: return "1920 px"
            case .small: return "1280 px"
            }
        }
    }

    private var imageSize: Binding<ImageSize> {
        Binding(
            get: { ImageSize(rawValue: resize) ?? .original },
            set: { resize = $0.rawValue }
        )
    }

    private var hasImages: Bool { session.files.contains { FileFormat.detect($0)?.category == .image } }

    private var presets: [CompressionPreset] {
        Compressor.supportsLossless(session.files) ? CompressionPreset.allCases : CompressionPreset.allCases.filter { $0 != .lossless }
    }

    /// Estimates come from real trial runs, so they are limited to quick image and PDF work.
    private var canEstimate: Bool {
        totalSize <= 300_000_000 && session.files.allSatisfy {
            guard let format = FileFormat.detect($0) else { return false }
            return format.category == .image || format == .pdf
        }
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? "Compress" : "Compress \(session.files.count) files", onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · saves as \(Compressor.outputFormat(for: url, preset: preset).displayName)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 8) {
                Text("Compression")
                    .font(.headline)
                ForEach(presets) { option in
                    presetRow(option)
                }
                .disabled(useTarget)
                .opacity(useTarget ? 0.45 : 1)
                if useTarget {
                    FormHint("Target size is on: each file keeps the highest quality that fits, trying lossless first.")
                } else if canEstimate {
                    FormHint((estimateIsSampled ? "Estimated from the first \(Self.estimateSampleCount) files." : "Estimates are trial runs of each level on your files.") + (preset == .lossless ? " Lossless uses oxipng (PNG), jpegtran (JPEG) and qpdf (PDF)." : ""))
                } else {
                    FormHint("Audio and video sizes are known after compressing.")
                }
            }

            if hasImages && preset != .lossless {
                FormRow(title: "Image size") {
                    SegmentedPicker(selection: imageSize, options: ImageSize.allCases.map { ($0, $0.title) })
                }
                FormHint("Longest edge of each image. Smaller images are never upscaled.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $useTarget.animation(.easeInOut(duration: 0.18))) {
                    Text("Target file size")
                }
                .toggleStyle(.switch)

                if useTarget {
                    HStack(spacing: 6) {
                        ForEach(Self.quickTargets, id: \.self) { kilobytes in
                            let selected = targetValue * targetUnit.multiplier == kilobytes * 1_000
                            Button(kilobytes >= 1_000 ? "\(Int(kilobytes / 1_000)) MB" : "\(Int(kilobytes)) KB") {
                                targetUnit = kilobytes >= 1_000 ? .megabytes : .kilobytes
                                targetValue = kilobytes >= 1_000 ? kilobytes / 1_000 : kilobytes
                            }
                            .buttonStyle(.bordered)
                            .tint(selected ? Theme.accent : nil)
                            .controlSize(.small)
                        }
                    }
                    HStack(spacing: 10) {
                        TextField("Size", value: $targetValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                        SegmentedPicker(selection: $targetUnit, options: SizeUnit.allCases.map { ($0, $0.rawValue) })
                        Text("per file")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    FormHint("PDFs shrink their images step by step while text stays sharp (Ghostscript). Images use a quality search and downscale if needed. Videos and audio pick a bitrate from the duration (FFmpeg required).")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text("\(session.files.count) file\(session.files.count == 1 ? "" : "s"), \(FileSizeFormatter.string(totalSize)) total. Originals stay untouched; compressed copies are saved to \(settings.outputLocation.title.lowercased()).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            resize = settings.compressionResizeLongEdge
            preset = presets.contains(settings.compressionPreset) ? settings.compressionPreset : .balanced
        }
        .onChange(of: preset) { _, value in settings.compressionPreset = value }
        .task(id: resize) { await estimate() }
    }

    private func presetRow(_ option: CompressionPreset) -> some View {
        let selected = option == preset
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { preset = option }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.body.weight(.semibold))
                    Text(option.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                estimateLabel(option)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.1) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.6) : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func estimateLabel(_ option: CompressionPreset) -> some View {
        if let size = estimates[option] {
            let saved = totalSize > 0 ? 1 - Double(size) / Double(totalSize) : 0
            VStack(alignment: .trailing, spacing: 2) {
                Text((estimateIsSampled ? "≈ " : "") + FileSizeFormatter.string(size)).font(.body.monospacedDigit().weight(.semibold))
                Text(saved >= 0.005 ? "−\(Int((saved * 100).rounded()))%" : "Already optimal")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(saved >= 0.005 ? Theme.accent : .secondary)
            }
        } else if let error = estimateErrors[option] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170, alignment: .trailing)
        } else if canEstimate {
            ProgressView().controlSize(.small)
        }
    }

    private func estimate() async {
        guard canEstimate else { return }
        estimates = [:]
        estimateErrors = [:]
        // Many files: measure a few and scale by size, so opening the window stays cheap.
        let sample = Array(session.files.prefix(Self.estimateSampleCount))
        let sampleSize = sample.reduce(Int64(0)) { $0 + FileSizeFormatter.size(of: $1) }
        let scale = sampleSize > 0 ? Double(totalSize) / Double(sampleSize) : 1
        estimateIsSampled = sample.count < session.files.count
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-estimate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return }
        let resize = resize
        for option in presets {
            let work = Task.detached(priority: .utility) { () throws -> Int64 in
                try await Compressor.$isEstimating.withValue(true) {
                    var total: Int64 = 0
                    for (index, url) in sample.enumerated() {
                        try Task.checkCancellation()
                        let output = directory.appendingPathComponent("\(option.rawValue)-\(index).\(Compressor.outputFormat(for: url, preset: option).fileExtension)")
                        try await Compressor.compress(url, preset: option, resizeLongEdge: resize, targetBytes: nil, to: output) { _ in }
                        total += FileSizeFormatter.size(of: output)
                        try? FileManager.default.removeItem(at: output)
                    }
                    return total
                }
            }
            do {
                let total = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if Task.isCancelled { return }
                estimates[option] = Int64(Double(total) * scale)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if case let OpenTangerineError.toolMissing(_, package, _) = error {
                    estimateErrors[option] = "Needs `brew install \(package)`"
                } else {
                    estimateErrors[option] = "Couldn't estimate"
                }
            }
        }
    }

    private func run() {
        let preset = preset
        let target = perFileTarget
        let resize = preset == .lossless ? 0 : resize
        for url in session.files {
            let format = target == nil ? Compressor.outputFormat(for: url, preset: preset) : Compressor.outputFormat(for: url)
            let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
            let destination = ConversionMatrix.uniqueURL(directory: settings.outputLocation.directory(for: url), baseName: base, suffix: "compressed", ext: format.fileExtension)
            JobRunner.shared.run(title: "Compressing", detail: "\(url.lastPathComponent)", symbol: ToolID.compress.symbol, sizeSource: url, targetBytes: target) { progress in
                try await Compressor.compress(url, preset: preset, resizeLongEdge: resize, targetBytes: target, to: destination, progress: progress)
                return [destination]
            }
        }
        ToolWindowManager.shared.close(session)
    }
}

