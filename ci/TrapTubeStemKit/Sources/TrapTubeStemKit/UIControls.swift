import SwiftUI
import AVFoundation
import UIKit

@MainActor
@objc(TrapTubeEQFactory)
public final class TrapTubeEQFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        // Kept as a compatibility entry point; EQ now lives inside Stem Studio.
        TrapTubeStemStudioFactory.makeViewController()
    }
}

@MainActor
@objc(TrapTubeAudioBoostFactory)
public final class TrapTubeAudioBoostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let controller = UIHostingController(rootView: TrapTubeVolumeBoostView())
        controller.title = "Stream Volume Boost"
        return controller
    }
}

private struct TrapTubeVolumeBoostView: View {
    @AppStorage("VolumeBoostYTEnabled") private var isEnabled = false
    @AppStorage("CustomYouTubeVolumeScalar") private var gain = 1.0

    private let accent = Color(red: 0.82, green: 0.035, blue: 0.12)
    private let background = Color(red: 0.025, green: 0.025, blue: 0.035)

    private var decibels: Double { 20.0 * (gain - 1.0) / 19.0 }
    private var multiplier: Double { pow(10.0, (gain - 1.0) / 19.0) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("STREAM VOLUME BOOST")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(2).foregroundStyle(accent)
                    Text("Turn up your stream")
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Adjust the gain control used by the bundled YTPlus stream-volume component.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.66))
                }

                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $isEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable stream boost").font(.headline).foregroundStyle(.white)
                            Text(isEnabled ? "Volume boost is enabled" : "Normal stream volume")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .tint(accent)

                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)

                    HStack {
                        Text("Boost amount").font(.headline).foregroundStyle(.white)
                        Spacer()
                        Text(String(format: "+%.1f dB", decibels))
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                            .foregroundStyle(accent)
                    }
                    Slider(value: $gain, in: 1...20, step: 1).tint(accent)
                    HStack {
                        Text("Normal · 1×").foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text(String(format: "%.2f×", multiplier)).foregroundStyle(accent)
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(18)
                .background(Color(red: 0.08, green: 0.08, blue: 0.095),
                            in: RoundedRectangle(cornerRadius: 18))

                Label("High gain can cause clipping, distortion, or uncomfortable playback levels. Start low and reduce the boost if audio becomes harsh.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)

                Text("The bundled YTPlus gain component may cache its value when initialized. If a change does not take effect immediately, fully close and reopen TrapTube.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
