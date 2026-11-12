import AVFoundation
import MediaToolbox
import UIKit

/// TrapTube EQ for app-owned audio and AVPlayerItem audio tracks that expose an
/// editable audio mix. FairPlay or custom YouTube renderers may reject/bypass taps.
@objc(TrapTubeEQManager)
public final class TrapTubeEQManager: NSObject {
    public static let frequencies: [Float] = [31, 62, 125, 250, 500, 750, 1000, 1500,
                                               2000, 3000, 4000, 6000, 8000, 10000, 12000, 16000]
    public static let shared = TrapTubeEQManager()

    private let lock = NSLock()
    private var bandGains = Array(repeating: Float(0), count: 16)
    private var bassBoost: Float = 0
    private var masterPercent: Float = 100
    private var attachedItems = NSHashTable<AVPlayerItem>.weakObjects()
    private var tapSampleRate: Double = 44100
    private var tapIsFloatPCM = false
    private var tapStates: [[BiquadState]] = []

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let engineEQ = AVAudioUnitEQ(numberOfBands: 17)
    private let limiter = AVAudioUnitDynamicsProcessor()

    private override init() {
        super.init()
        configureEngineGraph()
        let defaults = UserDefaults.standard
        for index in Self.frequencies.indices {
            let key = "TrapTube.EQ.Band.\(index)"
            if defaults.object(forKey: key) != nil { setBandGain(defaults.float(forKey: key), at: index) }
        }
        if defaults.object(forKey: "TrapTube.EQ.Bass") != nil { setBassBoost(defaults.float(forKey: "TrapTube.EQ.Bass")) }
        if defaults.object(forKey: "TrapTube.EQ.Master") != nil { setMasterGainPercent(defaults.float(forKey: "TrapTube.EQ.Master")) }
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public func setBandGain(_ gain: Float, at index: Int) {
        guard frequencies.indices.contains(index) else { return }
        let value = min(12, max(-12, gain))
        lock.lock(); bandGains[index] = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Band.\(index)")
        engineEQ.bands[index].gain = value
    }

    public func bandGain(at index: Int) -> Float {
        guard frequencies.indices.contains(index) else { return 0 }
        lock.lock(); defer { lock.unlock() }; return bandGains[index]
    }

    public func setBassBoost(_ decibels: Float) {
        let value = min(20, max(0, decibels))
        lock.lock(); bassBoost = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Bass")
        engineEQ.bands[16].gain = value
    }

    public var bassBoostDecibels: Float {
        lock.lock(); defer { lock.unlock() }; return bassBoost
    }

    public func setMasterGainPercent(_ percent: Float) {
        let value = min(200, max(0, percent))
        lock.lock(); masterPercent = value; lock.unlock()
        // AVAudioUnitGain uses dB; 0% is silence and 200% is +6.02 dB.
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Master")
        engineEQ.globalGain = value == 0 ? -96 : 20 * log10(value / 100)
    }

    public var masterGainPercent: Float {
        lock.lock(); defer { lock.unlock() }; return masterPercent
    }

    /// Configure an AVPlayerItem audio mix tap. Returns false when the item has no
    /// audio tracks or MediaToolbox refuses tap creation (possible with protected media).
    @discardableResult
    public func attachToPlayer(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return false }
        return attach(to: item)
    }

    @discardableResult
    public func attach(to item: AVPlayerItem) -> Bool {
        guard !item.asset.tracks(withMediaType: .audio).isEmpty else { return false }
        let mix = AVMutableAudioMix()
        var parameters: [AVAudioMixInputParameters] = []
        for track in item.asset.tracks(withMediaType: .audio) {
            let input = AVMutableAudioMixInputParameters(track: track)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passUnretained(self).toOpaque(),
                init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
                finalize: { _ in },
                prepare: { tap, _, processingFormat in
                    guard let raw = MTAudioProcessingTapGetStorage(tap) else { return }
                    let manager = Unmanaged<TrapTubeEQManager>.fromOpaque(raw).takeUnretainedValue()
                    manager.configureTap(sampleRate: processingFormat.pointee.mSampleRate,
                                         isFloatPCM: (processingFormat.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
                },
                unprepare: { _ in },
                process: { tap, frames, _, bufferList, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                    guard status == noErr, let raw = MTAudioProcessingTapGetStorage(tap) else { return }
                    let manager = Unmanaged<TrapTubeEQManager>.fromOpaque(raw).takeUnretainedValue()
                    manager.processTapBuffers(bufferList, frameCount: Int(framesOut.pointee))
                })
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard status == noErr, let tap else { return false }
            input.audioTapProcessor = tap
            parameters.append(input)
        }
        mix.inputParameters = parameters
        item.audioMix = mix
        attachedItems.add(item)
        return true
    }

    public func detach(from item: AVPlayerItem) {
        item.audioMix = nil
        attachedItems.remove(item)
    }

    /// Use this engine path for audio files/stems owned and decoded by TrapTube.
    public func play(file url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                        options: [.allowAirPlay, .allowBluetoothA2DP])
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try engine.start() }
        playerNode.stop()
        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
    }

    public func stopOwnedAudio() { playerNode.stop() }

    private func configureEngineGraph() {
        engine.attach(playerNode)
        engine.attach(engineEQ)
        engine.attach(limiter)
        for index in 0..<16 {
            let band = engineEQ.bands[index]
            band.filterType = .parametric
            band.frequency = frequencies[index]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        let shelf = engineEQ.bands[16]
        shelf.filterType = .lowShelf
        shelf.frequency = 100
        shelf.gain = 0
        shelf.bypass = false
        limiter.threshold = -1.0
        limiter.headRoom = 0.5
        limiter.attackTime = 0.001
        limiter.releaseTime = 0.08
        limiter.masterGain = 0
        engine.connect(playerNode, to: engineEQ, format: nil)
        engine.connect(engineEQ, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        engine.prepare()
    }

    private func configureTap(sampleRate: Double, isFloatPCM: Bool) {
        lock.lock()
        tapSampleRate = max(8000, sampleRate)
        tapIsFloatPCM = isFloatPCM
        tapStates = []
        lock.unlock()
    }

    private func processTapBuffers(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        let gains = bandGains
        let bass = bassBoost
        let master = masterPercent / 100
        let sampleRate = tapSampleRate
        let isFloatPCM = tapIsFloatPCM
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if !isFloatPCM { lock.unlock(); return }
        if tapStates.count != buffers.count {
            tapStates = buffers.map { buffer in Array(repeating: BiquadState(), count: max(1, Int(buffer.mNumberChannels)) * 17) }
        }
        for (bufferIndex, buffer) in buffers.enumerated() {
            guard let data = buffer.mData, buffer.mDataByteSize >= UInt32(MemoryLayout<Float>.size) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * channels)
            let pcm = data.bindMemory(to: Float.self, capacity: samples)
            var coefficients = gains.enumerated().map { index, gain in
                BiquadCoefficients.peaking(frequency: Double(Self.frequencies[index]), gainDB: Double(gain), sampleRate: sampleRate, q: 1.0)
            }
            coefficients.append(BiquadCoefficients.lowShelf(frequency: 100, gainDB: Double(bass), sampleRate: sampleRate))
            for sample in 0..<samples {
                var value = pcm[sample] * master
                let channel = sample % channels
                for band in 0..<17 {
                    let stateIndex = channel * 17 + band
                    value = tapStates[bufferIndex][stateIndex].process(value, coefficients[band])
                }
                pcm[sample] = abs(value) > 0.85 ? tanhf(value) : value
            }
        }
        lock.unlock()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            do { try AVAudioSession.sharedInstance().setActive(true); try engine.start() }
            catch { NSLog("[TrapTube EQ] Audio engine resume failed: %@", error.localizedDescription) }
        } else {
            playerNode.pause()
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard engine.isRunning else { return }
        engine.pause()
        do { try engine.start() }
        catch { NSLog("[TrapTube EQ] Route-change restart failed: %@", error.localizedDescription) }
    }
}

@objc(TrapTubeEQFactory)
public final class TrapTubeEQFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        TrapTubeEQViewController()
    }
}

private final class TrapTubeEQViewController: UIViewController {
    private let manager = TrapTubeEQManager.shared
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    private let accent = UIColor(red: 0.82, green: 0.035, blue: 0.12, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "TrapTube Equalizer"
        view.backgroundColor = UIColor(red: 0.025, green: 0.025, blue: 0.035, alpha: 1)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -36)
        ])
        addSlider(title: "Bass boost", range: 0...20, value: manager.bassBoostDecibels, suffix: " dB") { [weak self] in self?.manager.setBassBoost($0) }
        addSlider(title: "Master gain", range: 0...200, value: manager.masterGainPercent, suffix: "%") { [weak self] in self?.manager.setMasterGainPercent($0) }
        for (index, frequency) in TrapTubeEQManager.frequencies.enumerated() {
            let title = frequency >= 1000 ? "\(Int(frequency / 1000)) kHz" : "\(Int(frequency)) Hz"
            addSlider(title: title, range: -12...12, value: manager.bandGain(at: index), suffix: " dB") { [weak self] in self?.manager.setBandGain($0, at: index) }
        }
        let note = UILabel()
        note.text = "EQ applies to TrapTube-owned audio and player items that accept an audio-processing tap. Protected or custom-rendered streams may not expose a processable audio path."
        note.textColor = UIColor.white.withAlphaComponent(0.5); note.font = .systemFont(ofSize: 12)
        note.numberOfLines = 0; stack.addArrangedSubview(note)
    }

    private func addSlider(title: String, range: ClosedRange<Float>, value: Float, suffix: String,
                           changed: @escaping (Float) -> Void) {
        let label = UILabel(); label.textColor = .white; label.font = .systemFont(ofSize: 14, weight: .semibold)
        let valueLabel = UILabel(); valueLabel.textColor = accent; valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let slider = UISlider(); slider.minimumValue = range.lowerBound; slider.maximumValue = range.upperBound
        slider.value = value; slider.minimumTrackTintColor = accent
        let row = UIStackView(arrangedSubviews: [label, UIView(), valueLabel]); row.axis = .horizontal
        let container = UIStackView(arrangedSubviews: [row, slider]); container.axis = .vertical; container.spacing = 5
        let update: (Float) -> Void = { v in
            let rounded = (v * 10).rounded() / 10
            label.text = title; valueLabel.text = "\(rounded)\(suffix)"; changed(rounded)
        }
        slider.addAction(UIAction { _ in update(slider.value) }, for: .valueChanged)
        update(value); stack.addArrangedSubview(container)
    }
}

private struct BiquadCoefficients {
    var b0: Double; var b1: Double; var b2: Double
    var a1: Double; var a2: Double
    static func peaking(frequency: Double, gainDB: Double, sampleRate: Double, q: Double) -> Self {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosine = cos(w)
        let a0 = 1 + alpha / a
        return Self(b0: (1 + alpha * a) / a0, b1: (-2 * cosine) / a0,
                    b2: (1 - alpha * a) / a0, a1: (-2 * cosine) / a0,
                    a2: (1 - alpha / a) / a0)
    }
    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Self {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(w), sine = sin(w), alpha = sine / sqrt(2)
        let root = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosine + root
        return Self(b0: a * ((a + 1) - (a - 1) * cosine + root) / a0,
                    b1: 2 * a * ((a - 1) - (a + 1) * cosine) / a0,
                    b2: a * ((a + 1) - (a - 1) * cosine - root) / a0,
                    a1: -2 * ((a - 1) + (a + 1) * cosine) / a0,
                    a2: ((a + 1) + (a - 1) * cosine - root) / a0)
    }
}
private struct BiquadState {
    var z1 = 0.0
    var z2 = 0.0
    mutating func process(_ input: Float, _ c: BiquadCoefficients) -> Float {
        let x = Double(input)
        let output = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * output + z2
        z2 = c.b2 * x - c.a2 * output
        return Float(output)
    }
}
