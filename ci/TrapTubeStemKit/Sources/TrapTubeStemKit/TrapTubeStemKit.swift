import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Demucs

@MainActor
@objc(TrapTubeStemStudioFactory) public final class TrapTubeStemStudioFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let controller = UIHostingController(rootView: TrapTubeStemStudioView())
        controller.title = "EQ"
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

private enum TrapTubeStemModelOption: String, CaseIterable, Identifiable {
    case balanced
    case sixStem
    case fineTuned

    var id: String { rawValue }

    var model: DemucsModel {
        switch self {
        case .balanced: .fourStem
        case .sixStem: .sixStem
        case .fineTuned: .fineTunedAll
        }
    }

    var displayName: String {
        switch self {
        case .balanced: "HTDemucs · 4 stems"
        case .sixStem: "HTDemucs · 6 stems"
        case .fineTuned: "HTDemucs FT · Fine-tuned"
        }
    }

    // Relative model tier from the upstream model descriptions, not a published
    // head-to-head benchmark or a guarantee for every song.
    var qualityTier: Int { self == .fineTuned ? 5 : 3 }

    var detail: String {
        switch self {
        case .balanced: "Balanced speed and quality · vocals, drums, bass, other"
        case .sixStem: "Adds guitar and piano · same general quality tier"
        case .fineTuned: "Highest-quality variant · separate fine-tuned stem models"
        }
    }
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
    @Published var selectedModelOption: TrapTubeStemModelOption = .balanced {
        didSet {
            UserDefaults.standard.set(selectedModelOption.rawValue, forKey: "TrapTube.StemStudio.Model")
            stopPlayback()
            outputs = [:]
            refresh()
        }
    }

    private var selectedModel: DemucsModel { selectedModelOption.model }
    var selectedModelInfo: DemucsModelInfo { DemucsEngine.info(for: selectedModel) }
    var selectedModelIsDownloaded: Bool { DemucsEngine.isDownloaded(selectedModel) }
    var availableStemNames: [String] { selectedModelInfo.stems.map(\.rawValue) }

    // Configure the native model cache before constructing the Rust-backed engine.
    // The engine is lazy so no Demucs worker can start before cache setup completes.
    private lazy var engine: DemucsEngine = {
        _ = TrapTubeStemStorage.configured
        return DemucsEngine()
    }()

    init() {
        _ = TrapTubeStemStorage.configured
        if let saved = UserDefaults.standard.string(forKey: "TrapTube.StemStudio.Model"),
           let option = TrapTubeStemModelOption(rawValue: saved) {
            selectedModelOption = option
        }
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
        status = "Downloading \(selectedModelInfo.label) · about \(selectedModelInfo.sizeMB) MB"
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

    // A single Split action is sufficient: if the selected model is missing,
    // download it first and then continue into separation automatically.
    func separate() {
        guard selectedFile != nil, !isProcessing, !isDownloading else { return }
        error = nil
        if !isModelReady {
            isDownloading = true
            downloadProgress = 0
            status = "Downloading \(selectedModelInfo.label)…"
            let modelToDownload = selectedModel
            Task { @MainActor in
                do {
                    try await DemucsEngine.download(modelToDownload) { update in
                        Task { @MainActor in
                            self.downloadProgress = update.fraction
                            self.status = "Downloading model · \(Int(update.fraction * 100))%"
                        }
                    }
                    self.isDownloading = false
                    self.refresh()
                    guard self.isModelReady else {
                        self.error = "The model download finished but the model is not available. Try downloading it again."
                        self.status = "Model unavailable"
                        return
                    }
                    self.runSeparation()
                } catch {
                    self.isDownloading = false
                    self.error = "Model download failed: \(error.localizedDescription)"
                    self.status = "Model download failed"
                }
            }
            return
        }
        runSeparation()
    }

    /// Exact byte sizes of the published weights files. The engine's own
    /// cache check only tests that a file exists, so a damaged download
    /// would otherwise poison every load attempt with a native panic.
    private nonisolated static let expectedWeightsBytes: [String: Int64] = [
        "htdemucs": 84_030_696,
        "htdemucs_6s": 54_890_960,
        "htdemucs_ft": 336_125_008
    ]

    /// Structural validation of a downloaded weights file: exact size plus a
    /// safetensors header whose tensor offsets end exactly at end-of-file.
    nonisolated static func weightsFileIsValid(_ model: DemucsModel) -> Bool {
        guard let url = DemucsEngine.downloadedFileURL(for: model) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 16 else { return false }
        if let expected = expectedWeightsBytes[DemucsEngine.info(for: model).id], size != expected {
            return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return false }
        var headerLength: UInt64 = 0
        for (index, byte) in prefix.enumerated() { headerLength |= UInt64(byte) << UInt64(index * 8) }
        guard headerLength > 0, headerLength < UInt64(size) - 8,
              let headerData = try? handle.read(upToCount: Int(headerLength)),
              headerData.count == Int(headerLength),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return false }
        var maxEnd: UInt64 = 0
        for (key, value) in header where key != "__metadata__" {
            guard let tensor = value as? [String: Any],
                  let offsets = tensor["data_offsets"] as? [Int], offsets.count == 2 else { return false }
            maxEnd = max(maxEnd, UInt64(offsets[1]))
        }
        return 8 + headerLength + maxEnd == UInt64(size)
    }

    /// Loads a model with automatic recovery: a corrupt cache file is
    /// deleted and re-downloaded, and if the native loader panics, the
    /// weights are fetched fresh and the load retried exactly once. A panic
    /// on a verified clean file is reported as a model-variant failure.
    nonisolated static func loadWithRecovery(engine: DemucsEngine, model: DemucsModel,
                                             status: @escaping @Sendable (String) async -> Void) async throws {
        if DemucsEngine.isDownloaded(model), !weightsFileIsValid(model) {
            _ = DemucsEngine.deleteDownload(model)
        }
        if !DemucsEngine.isDownloaded(model) {
            await status("Downloading model...")
            try await DemucsEngine.download(model)
            guard weightsFileIsValid(model) else {
                _ = DemucsEngine.deleteDownload(model)
                throw NSError(domain: "TrapTubeStemKit", code: 14,
                              userInfo: [NSLocalizedDescriptionKey: "The model download did not produce a valid file. Check your connection and try again."])
            }
        }
        do {
            try await engine.load(model)
        } catch {
            guard error.localizedDescription.contains("panicked") else { throw error }
            _ = DemucsEngine.deleteDownload(model)
            await status("The model loader crashed - downloading a fresh copy...")
            try await DemucsEngine.download(model)
            guard weightsFileIsValid(model) else { throw error }
            do {
                try await engine.load(model)
            } catch {
                throw NSError(domain: "TrapTubeStemKit", code: 15,
                              userInfo: [NSLocalizedDescriptionKey: "This model variant crashes the separation engine even with a verified clean download. Switch to the standard HTDemucs model - the fine-tuned variant is not stable in this build."])
            }
        }
    }

    /// When the fine-tuned model provably crashes the engine on a verified
    /// clean download, switch the selection to the standard model so the
    /// next tap just works. Returns true when a switch happened.
    private func switchToStandardAfterVerifiedCrash() -> Bool {
        guard selectedModelOption != .balanced else { return false }
        selectedModelOption = .balanced
        UserDefaults.standard.set(TrapTubeStemModelOption.balanced.rawValue,
                                  forKey: "TrapTube.StemStudio.Model")
        isModelReady = DemucsEngine.isDownloaded(selectedModel)
        fail("The fine-tuned model crashes this build's engine even with a clean download, so Stem Studio switched to the standard HTDemucs model. Tap Separate again to run with it.")
        return true
    }

    private func runSeparation() {
        guard let selectedFile, !isProcessing else { return }
        isProcessing = true
        processingProgress = 0
        outputs = [:]
        error = nil
        status = "Preparing stereo audio…"
        let destination = TrapTubeStemStorage.stems.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = self.engine
        let selectedModel = self.selectedModel
        let expectedStemCount = self.selectedModelInfo.stems.count

        Task.detached(priority: .userInitiated) {
            var stage = "Audio decoding"
            do {
                let pcm = try Self.readStereo(selectedFile)
                guard !pcm.left.isEmpty, pcm.left.count == pcm.right.count else {
                    throw NSError(domain: "TrapTubeStemKit", code: 12,
                                  userInfo: [NSLocalizedDescriptionKey: "The imported file contains no usable audio samples."])
                }
                stage = "HTDemucs model loading"
                await self.setStatus("Loading HTDemucs…", progress: 0.02)
                try await Self.loadWithRecovery(engine: engine, model: selectedModel) { message in
                    await self.setStatus(message, progress: 0.02)
                }
                stage = "Metal GPU warmup"
                await self.setStatus("Preparing Metal inference…", progress: 0.05)
                try await engine.warmup()
                stage = "HTDemucs source separation"
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

                stage = "Stem WAV export"
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
                guard result.count == expectedStemCount else {
                    throw NSError(domain: "TrapTubeStemKit", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "The selected model returned \(result.count) stems; expected \(expectedStemCount)."])
                }
                await self.finish(result)
            } catch {
                let detail = "\(stage) failed: \(error.localizedDescription)"
                NSLog("[TrapTube Stem Studio] %@", detail)
                let nsError = error as NSError
                if nsError.domain == "TrapTubeStemKit", nsError.code == 15,
                   await self.switchToStandardAfterVerifiedCrash() {
                    // The helper switched the model and set the message.
                } else {
                    await self.fail(detail)
                }
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
        status = "\(result.count) stems separated successfully"
    }

    private func fail(_ message: String) {
        isProcessing = false
        isModelReady = DemucsEngine.isDownloaded(selectedModel)
        error = message
        status = "Separation failed"
    }

    func play(_ name: String) {
        stopPlayback()
        guard let url = outputs[name] else { return }
        do {
            try TrapTubeEQManager.shared.play(file: url)
            playingStem = name
        } catch {
            self.error = "Couldn't play \(name): \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        TrapTubeEQManager.shared.stopOwnedAudio()
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

/// Liquid Glass surface: the real iOS 26 glass effect where the OS offers
/// it, and a layered material approximation on iOS 17-25, so the design
/// language is the same on every supported version.
struct TTGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                                               startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 14, y: 5)
        }
    }
}

extension View {
    func ttGlassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(TTGlassCard(cornerRadius: cornerRadius))
    }
}

@MainActor
private struct TrapTubeStemStudioView: View {
    @ObservedObject private var miniStore = TrapTubeMiniPlayerStore.shared
    @State private var reopenRequest: TrapTubePlayerRequest?

    private var accent: Color {
        let hex = UserDefaults.standard.string(forKey: "TrapTube.AccentHex") ?? "D1091F"
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(clean, radix: 16) ?? 0xD1091F
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }

    // Round 22: the tab is the EQ tab now. The old two-page
    // setup (a Stem Separation page beside a Player page, switched
    // by header buttons over a paging TabView) is gone - the stem
    // separation page was deleted from this interface entirely,
    // and what remains is ONE scrolling page: the EQ settings
    // section first, then the YouTube search/player feed, with
    // the mini player bar pinned underneath. The Demucs model
    // code above stays compiled in (the workflow still verifies
    // it) but no view in this tab reaches it anymore.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TRAPTUBE EQ").font(.system(size: 12, weight: .black, design: .rounded))
                            .tracking(2.2).foregroundStyle(accent)
                        Text("Equalizer").font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("The EQ settings and the YouTube player on one page - every change applies live to the playing stream.")
                            .font(.subheadline).foregroundStyle(Color.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)

                    TrapTubeEQSettingsSection()
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("PLAYER").font(.caption.weight(.black))
                            .tracking(1.5).foregroundStyle(accent)
                        Text("Search YouTube and play - the EQ above rides along, and a minimized stream keeps playing under this page.")
                            .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)

                    TrapTubePlayerHomeView()
                }
                .padding(.vertical, 18)
            }
            if let mini = miniStore.controller {
                miniPlayerBar(mini)
            }
        }
        .background {
            LinearGradient(colors: [Color(red: 0.055, green: 0.04, blue: 0.075),
                                    Color(red: 0.015, green: 0.015, blue: 0.028)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $reopenRequest) { request in
            TrapTubeNativePlayerView(request: request)
        }
        .onAppear {
            // Round 19: build the EQ manager (and its audio engine
            // graph) the moment the tab opens, not at first attach.
            TrapTubeEQManager.prewarm()
        }
    }

    /// Round 20's mini player bar, rendered by the root since
    /// Round 22 (the feed view lives inside the scrolling page
    /// now, where a bar at its end would never be seen): play/
    /// pause, the title and path readout, close, and
    /// tap-to-reopen, which re-presents the player with the SAME
    /// controller - nothing reloads, the position is untouched.
    private func miniPlayerBar(_ controller: TrapTubePlayerController) -> some View {
        HStack(spacing: 12) {
            Button { controller.togglePlayPause() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(accent, in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.title.isEmpty ? "TrapTube Player" : controller.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(controller.pathStatusText.isEmpty ? "Now playing" : controller.pathStatusText)
                    .font(.caption2).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if let saved = miniStore.request { reopenRequest = saved }
            }
            Button { miniStore.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct TrapTubeEQSliderRow: View {
    let title: String
    let range: ClosedRange<Float>
    let suffix: String
    let onChange: (Float) -> Void
    @State private var value: Float

    init(title: String, value: Float, range: ClosedRange<Float>, suffix: String,
         onChange: @escaping (Float) -> Void) {
        self.title = title
        self.range = range
        self.suffix = suffix
        self.onChange = onChange
        _value = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.1f%@", value, suffix))
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.82, green: 0.035, blue: 0.12))
            }
            Slider(value: $value, in: range)
                .tint(Color(red: 0.82, green: 0.035, blue: 0.12))
                .onChange(of: value) { newValue in onChange(newValue) }
        }
    }
}
