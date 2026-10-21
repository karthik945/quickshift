import SwiftUI

@MainActor
struct ExportAssetsToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var scales: Set<Int> = [1, 2, 3]
    @State private var format: FileFormat = .png
    @State private var sourceScale = 1
    @State private var icons: Set<AssetExporter.IconPlatform> = []

    private static let vectorFormats: Set<FileFormat> = [.ai, .eps, .pdf, .svg]

    private var hasRaster: Bool {
        session.files.contains { FileFormat.detect($0).map { !Self.vectorFormats.contains($0) } ?? true }
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? "Export" : "Export \(session.files.count) files", saveEnabled: !scales.isEmpty || !icons.isEmpty, onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        Text(url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Scales").font(.headline)
                HStack(spacing: 18) {
                    ForEach(1...4, id: \.self) { scale in
                        Toggle("@\(scale)x", isOn: member(scale, of: $scales)).toggleStyle(.checkbox)
                    }
                }
                FormRow(title: "Format") {
                    SegmentedPicker(selection: $format, options: [FileFormat.png, .jpg, .webp].map { ($0, $0.displayName) })
                }
                if hasRaster {
                    FormRow(title: "Original is") {
                        SegmentedPicker(selection: $sourceScale, options: [1, 2, 3].map { ($0, "@\($0)x") })
                    }
                    FormHint("Pixel images can't gain detail. Pick the scale the original was made at, so smaller sizes are made by shrinking it.")
                } else {
                    FormHint("Vector artwork is re-rendered at every scale, so each size stays sharp.")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("App icons").font(.headline)
                ForEach(AssetExporter.IconPlatform.allCases) { platform in
                    Toggle(isOn: member(platform, of: $icons)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(platform.title)
                            Text(platform.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                FormHint("Non-square artwork is centred on a transparent square. iOS icons get a white background because App Store icons can't be transparent.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text("Each file gets its own \u{201C}assets\u{201D} folder, saved to \(settings.outputLocation.title.lowercased()).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func member<T: Hashable>(_ value: T, of set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { isOn in
                if isOn { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
            }
        )
    }

    private func run() {
        let options = AssetExporter.Options(scales: scales.sorted(), format: format, sourceScale: sourceScale, icons: icons)
        for url in session.files {
            let parent = settings.outputLocation.directory(for: url)
            JobRunner.shared.run(title: ToolID.exportAssets.progressTitle, detail: url.lastPathComponent, symbol: ToolID.exportAssets.symbol) { progress in
                [try await AssetExporter.export(url, options: options, into: parent, progress: progress)]
            }
        }
        ToolWindowManager.shared.close(session)
    }
}
