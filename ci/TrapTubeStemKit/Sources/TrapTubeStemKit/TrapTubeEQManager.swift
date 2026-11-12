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
    private let limiter: AVAudioUnitEffect = {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }()

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
        guard Self.frequencies.indices.contains(index) else { return }
        let value = min(12, max(-12, gain))
        lock.lock(); bandGains[index] = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "TrapTube.EQ.Band.\(index)")
        engineEQ.bands[index].gain = value
    }

    public func bandGain(at index: Int) -> Float {
        guard Self.frequencies.indices.contains(index) else { return 0 }
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
        // AVAudioUnitEQ globalGain provides the 0-200% master gain range.
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
                    let raw = MTAudioProcessingTapGetStorage(tap)
                    let manager = Unmanaged<TrapTubeEQManager>.fromOpaque(raw).takeUnretainedValue()
                    manager.configureTap(sampleRate: processingFormat.pointee.mSampleRate,
                                         isFloatPCM: (processingFormat.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
                },
                unprepare: { _ in },
                process: { tap, frames, _, bufferList, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                    guard status == noErr else { return }
                    let raw = MTAudioProcessingTapGetStorage(tap)
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
            band.frequency = Self.frequencies[index]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        let shelf = engineEQ.bands[16]
        shelf.filterType = .lowShelf
        shelf.frequency = 100
        shelf.gain = 0
        shelf.bypass = false
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
        if tapStates.count != buffers.count || buffers.enumerated().contains(where: { index, buffer in
            tapStates[index].count != max(1, Int(buffer.mNumberChannels)) * 17
        }) {
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

