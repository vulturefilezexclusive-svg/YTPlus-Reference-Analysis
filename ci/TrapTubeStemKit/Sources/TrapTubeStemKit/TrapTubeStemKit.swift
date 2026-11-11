import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Demucs

@MainActor
@objc(TrapTubeStemStudioFactory) public final class TrapTubeStemStudioFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let controller = UIHostingController(rootView: TrapTubeStemStudioView())
        controller.title = "Stem Studio"
        return controller
    }
}

private enum TrapTubeStemStorage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("TrapTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    static let modelCache: URL = {
        let url = root.appendingPathComponent("Demucs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        return url
    }()

    static let imports: URL = {
        let url = root.appendingPathComponent("Imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let stems: URL = {
        let url = root.appendingPathComponent("Stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let configured: Bool = {
        DemucsEngine.configureCacheDirectory(modelCache)
        return true
    }()
}

@MainActor
private final class TrapTubeStemModel: ObservableObject {
    @Published var selectedFile: URL?
    @Published var outputs: [String: URL] = [:]
    @Published var isModelReady = false
    @Published var isDownloading = false
    @Published var isProcessing = false
    @Published var downloadProgress = 0.0
    @Published var processingProgress = 0.0
    @Published var status = "Import an audio file to get started"
    @Published var error: String?
    @Published var playingStem: String?

    private var audioPlayer: AVAudioPlayer?
    // One HTDemucs network returns all four stems without loading four separate fine-tuned submodels.
    private let selectedModel: DemucsModel = .fourStem
    private let engine = DemucsEngine()

    init() {
        _ = TrapTubeStemStorage.configured
        refresh()
    }

    func refresh() {
        isModelReady = DemucsEngine.isDownloaded(selectedModel)
        if isModelReady && !isProcessing && !isDownloading {
            status = "HTDemucs is ready · offline capable"
        }
    }

    func importFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
            let destination = TrapTubeStemStorage.imports
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: url, to: destination)
            selectedFile = destination
            outputs = [:]
            error = nil
            status = "Ready to separate"
        } catch {
            self.error = "Couldn't import this file: \(error.localizedDescription)"
        }
    }

    func downloadModel() {
        guard !isDownloading, !isModelReady else { return }
        isDownloading = true
        downloadProgress = 0
        error = nil
        status = "Downloading HTDemucs · about 84 MB"
        Task {
            do {
                try await DemucsEngine.download(selectedModel) { update in
                    Task { @MainActor in
                        self.downloadProgress = update.fraction
                        self.status = "Downloading model · \(Int(update.fraction * 100))%"
                    }
                }
                isDownloading = false
                refresh()
                status = isModelReady ? "Model ready · available offline" : "Model download incomplete"
            } catch {
                isDownloading = false
                self.error = error.localizedDescription
                status = "Model download failed"
            }
        }
    }

    func separate() {
        guard let selectedFile, !isProcessing else { return }
        guard isModelReady else {
            error = "Download the enhanced model before separating audio."
            return
        }
        isProcessing = true
        processingProgress = 0
        outputs = [:]
        error = nil
        status = "Preparing stereo audio…"
        let destination = TrapTubeStemStorage.stems.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = self.engine
        let selectedModel = self.selectedModel

        Task.detached(priority: .userInitiated) {
            do {
                let pcm = try Self.readStereo(selectedFile)
                await self.setStatus("Loading HTDemucs…", progress: 0.02)
                try await engine.load(selectedModel)
                await self.setStatus("Preparing Metal inference…", progress: 0.05)
                try await engine.warmup()
                let separated = try await engine.separate(
                    left: pcm.left,
                    right: pcm.right,
                    sampleRate: pcm.sampleRate
                ) { update in
                    Task { @MainActor in
                        self.processingProgress = update.fraction
                        self.status = "Separating audio · chunk \(update.chunkIndex) of \(update.totalChunks)"
                    }
                }

                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var result: [String: URL] = [:]
                for stem in separated {
                    guard stem.left.count == pcm.left.count, stem.right.count == pcm.right.count else {
                        throw NSError(domain: "TrapTubeStemKit", code: 10,
                                      userInfo: [NSLocalizedDescriptionKey: "The model returned an unexpected stem length."])
                    }
                    let key = stem.kind.rawValue
                    let output = destination.appendingPathComponent("\(key).wav")
                    try Self.writeWAV(left: stem.left, right: stem.right,
                                      sampleRate: Double(pcm.sampleRate), url: output)
                    result[key] = output
                }
                guard result.count == 4 else {
                    throw NSError(domain: "TrapTubeStemKit", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "HTDemucs did not return all four stems."])
                }
                await self.finish(result)
            } catch {
                await self.fail(error.localizedDescription)
            }
        }
    }

    private func setStatus(_ value: String, progress: Double) {
        status = value
        processingProgress = progress
    }

    private func finish(_ result: [String: URL]) {
        outputs = result
        isProcessing = false
        processingProgress = 1
        status = "Four stems separated successfully"
    }

    private func fail(_ message: String) {
        isProcessing = false
        error = message
        status = "Separation failed"
    }

    func play(_ name: String) {
        stopPlayback()
        guard let url = outputs[name] else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            playingStem = name
        } catch {
            self.error = "Couldn't play \(name): \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingStem = nil
    }

    nonisolated private static func readStereo(_ url: URL) throws -> (left: [Float], right: [Float], sampleRate: UInt32) {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0, file.length > 0 else {
            throw NSError(domain: "TrapTubeStemKit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This audio file could not be decoded."])
        }
        let duration = Double(file.length) / sourceFormat.sampleRate
        guard duration <= 8 * 60 else {
            throw NSError(domain: "TrapTubeStemKit", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "For memory safety, Stem Studio currently accepts tracks up to 8 minutes."])
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "TrapTubeStemKit", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate the source audio buffer."])
        }
        try file.read(into: source)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate,
                                         channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw NSError(domain: "TrapTubeStemKit", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not convert this file to stereo PCM."])
        }
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * target.sampleRate / sourceFormat.sampleRate) + 1024)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "TrapTubeStemKit", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate the stereo conversion buffer."])
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !supplied else { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        guard status != .error, converted.frameLength > 0,
              let channels = converted.floatChannelData else {
            throw NSError(domain: "TrapTubeStemKit", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Stereo PCM conversion failed."])
        }
        let count = Int(converted.frameLength)
        return (
            Array(UnsafeBufferPointer(start: channels[0], count: count)),
            Array(UnsafeBufferPointer(start: channels[1], count: count)),
            UInt32(target.sampleRate)
        )
    }

    nonisolated private static func writeWAV(left: [Float], right: [Float], sampleRate: Double, url: URL) throws {
        guard left.count == right.count,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else {
            throw NSError(domain: "TrapTubeStemKit", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate a separated WAV file."])
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@MainActor
private struct TrapTubeStemStudioView: View {
    @StateObject private var model = TrapTubeStemModel()
    @State private var showImporter = false

    private var accent: Color {
        let hex = UserDefaults.standard.string(forKey: "TrapTube.AccentHex") ?? "D1091F"
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(clean, radix: 16) ?? 0xD1091F
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("STEM STUDIO").font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(2.2).foregroundStyle(accent)
                    Text("Separate your sound").font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Split a local audio file into vocals, drums, bass, and other instruments.")
                        .font(.subheadline).foregroundStyle(Color.white.opacity(0.64))
                }

                Button { showImporter = true } label: {
                    Label(model.selectedFile?.lastPathComponent ?? "Import audio file",
                          systemImage: "folder.badge.plus")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.45), lineWidth: 1))
                }
                .tint(accent)

                VStack(alignment: .leading, spacing: 10) {
                    Label(model.isModelReady ? "HTDemucs ready" : "Enhanced model required",
                          systemImage: model.isModelReady ? "checkmark.seal.fill" : "cpu")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(model.isModelReady ? Color.green : accent)
                    Text(model.isModelReady
                         ? "The 84 MB four-stem model is stored in Application Support and can be reused offline."
                         : "Download the 84 MB four-stem model once. It stays in persistent app storage for offline use.")
                        .font(.caption).foregroundStyle(Color.white.opacity(0.65))
                    if !model.isModelReady {
                        Button { model.downloadModel() } label: {
                            HStack {
                                if model.isDownloading { ProgressView().tint(.white) }
                                else { Image(systemName: "arrow.down.circle.fill") }
                                Text(model.isDownloading ? model.status : "Download HTDemucs · 84 MB")
                            }
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(accent, in: Capsule())
                        }
                        .disabled(model.isDownloading)
                        if model.isDownloading {
                            ProgressView(value: model.downloadProgress).tint(accent)
                        }
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))

                Button { model.separate() } label: {
                    HStack {
                        if model.isProcessing { ProgressView().tint(.white) }
                        else { Image(systemName: "waveform.badge.mic") }
                        Text(model.isProcessing ? model.status : "Separate into four stems")
                    }
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(accent, in: Capsule())
                }
                .disabled(model.selectedFile == nil || !model.isModelReady || model.isProcessing)
                .opacity(model.selectedFile == nil || !model.isModelReady || model.isProcessing ? 0.45 : 1)

                if model.isProcessing {
                    ProgressView(value: model.processingProgress).tint(accent)
                    Text(model.status).font(.caption).foregroundStyle(Color.white.opacity(0.65))
                }

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Separated stems").font(.headline.weight(.bold)).foregroundStyle(.white)
                    ForEach(["vocals", "drums", "bass", "other"], id: \.self) { name in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: name)).foregroundStyle(accent).frame(width: 24)
                            Text(name.capitalized).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            Spacer()
                            if let url = model.outputs[name] {
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up").foregroundStyle(.white.opacity(0.7))
                                }
                                Button {
                                    if model.playingStem == name { model.stopPlayback() }
                                    else { model.play(name) }
                                } label: {
                                    Image(systemName: model.playingStem == name ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title2).foregroundStyle(accent)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text("Not generated").font(.caption).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))

                Text("Processing runs locally with Metal acceleration. The initial model download requires internet; subsequent separations can run offline. Files remain on this device.")
                    .font(.caption).foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(18)
        }
        .background(Color(red: 0.025, green: 0.025, blue: 0.035).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importFile(url) }
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
        .onAppear { model.refresh() }
    }

    private func icon(for stem: String) -> String {
        switch stem {
        case "vocals": return "mic.fill"
        case "drums": return "drum.fill"
        case "bass": return "guitars.fill"
        default: return "waveform"
        }
    }
}
