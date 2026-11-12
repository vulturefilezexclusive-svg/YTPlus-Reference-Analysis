import AVFoundation
import UIKit

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
            let title = frequency >= 1000
                ? (frequency.truncatingRemainder(dividingBy: 1000) == 0
                    ? "\(Int(frequency / 1000)) kHz"
                    : String(format: "%.1f kHz", frequency / 1000))
                : "\(Int(frequency)) Hz"
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

