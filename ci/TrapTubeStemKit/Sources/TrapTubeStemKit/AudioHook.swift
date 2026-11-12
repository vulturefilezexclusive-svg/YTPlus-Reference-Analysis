import AVFoundation
import Foundation

/// Installs TrapTube's EQ on AVPlayerItems whose decoded audio tracks expose
/// AVAudioMix processing. This deliberately does not attempt to bypass FairPlay
/// or custom renderers that do not expose an AVPlayerItem audio mix.
@objc(TrapTubeAudioHook)
public final class TrapTubeAudioHook: NSObject {
    private weak var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var attachmentTask: Task<Void, Never>?
    private weak var observedItem: AVPlayerItem?

    @objc public func install(on player: AVPlayer) {
        invalidate()
        self.player = player
        itemObservation = player.observe(\\.currentItem, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async { [weak self, weak observedPlayer] in
                guard let self, let observedPlayer else { return }
                self.observeCurrentItem(observedPlayer.currentItem)
            }
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        guard observedItem !== item else { return }
        attachmentTask?.cancel()
        attachmentTask = nil
        statusObservation?.invalidate()
        statusObservation = nil

        if let previous = observedItem {
            TrapTubeEQManager.shared.detach(from: previous)
        }
        observedItem = item
        guard let item else { return }

        // Track loading is asynchronous. Reading asset.tracks synchronously at
        // item replacement can return an empty array and permanently miss EQ.
        statusObservation = item.observe(\\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            guard let self, let item else { return }
            if item.status == .failed {
                NSLog("[TrapTube EQ] Player item failed before EQ attachment: %@", item.error?.localizedDescription ?? "unknown error")
            }
        }
        attachWhenTracksAreReady(item)
    }

    private func attachWhenTracksAreReady(_ item: AVPlayerItem) {
        attachmentTask?.cancel()
        attachmentTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            let attached = await TrapTubeEQManager.shared.attachWhenReady(to: item)
            guard !Task.isCancelled else {
                TrapTubeEQManager.shared.detach(from: item)
                return
            }
            guard self.player?.currentItem === item else {
                TrapTubeEQManager.shared.detach(from: item)
                return
            }
            if attached {
                NSLog("[TrapTube EQ] Attached audio processing tap to current YouTube AVPlayerItem")
            } else {
                NSLog("[TrapTube EQ] Current player item did not expose a compatible audio-processing path")
            }
        }
    }

    @objc public func invalidate() {
        attachmentTask?.cancel()
        attachmentTask = nil
        itemObservation?.invalidate()
        itemObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let item = observedItem {
            TrapTubeEQManager.shared.detach(from: item)
        }
        observedItem = nil
        player = nil
    }

    deinit { invalidate() }
}
