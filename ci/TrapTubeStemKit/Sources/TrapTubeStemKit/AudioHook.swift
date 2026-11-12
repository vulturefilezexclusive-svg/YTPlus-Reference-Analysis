import AVFoundation
import Foundation

/// Observes AVPlayer.currentItem and installs the EQ tap when YouTube replaces
/// its player item. The host must expose a normal AVPlayerItem audio track.
@objc(TrapTubeAudioHook)
public final class TrapTubeAudioHook: NSObject {
    private weak var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?

    @objc public func install(on player: AVPlayer) {
        invalidate()
        self.player = player
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            guard let self, let item = observedPlayer.currentItem else { return }
            DispatchQueue.main.async {
                _ = TrapTubeEQManager.shared.attach(to: item)
            }
        }
    }

    @objc public func invalidate() {
        itemObservation?.invalidate()
        itemObservation = nil
        if let item = player?.currentItem {
            TrapTubeEQManager.shared.detach(from: item)
        }
        player = nil
    }

    deinit { invalidate() }
}
