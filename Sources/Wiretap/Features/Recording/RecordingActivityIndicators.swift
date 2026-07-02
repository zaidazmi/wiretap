import SwiftUI

struct LiveRecordingGlyph: View {
    var size: CGFloat = 46
    var isActive = true

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(isActive ? 0.14 : 0.08))

            Circle()
                .stroke(Color.red.opacity(isActive ? 0.22 : 0.12), lineWidth: 1)

            Circle()
                .fill(Color.red)
                .frame(width: size * 0.42, height: size * 0.42)
                .shadow(color: .red.opacity(isActive ? 0.32 : 0), radius: 8, y: 2)

            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .symbolEffect(.pulse, isActive: isActive)
        .accessibilityHidden(true)
    }
}

struct LiveWaveformMeter: View {
    var color: Color = .red
    var barCount = 18
    var isActive = true

    @State private var isAnimating = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color.opacity(opacity(for: index)))
                    .frame(width: 4, height: height(for: index))
                    .animation(
                        .easeInOut(duration: duration(for: index))
                            .repeatForever(autoreverses: true)
                            .delay(Double(index % 5) * 0.05),
                        value: isAnimating
                    )
            }
        }
        .frame(height: 42)
        .onAppear {
            isAnimating = isActive
        }
        .onChange(of: isActive) { _, newValue in
            isAnimating = newValue
        }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let resting = CGFloat([10, 18, 28, 16, 34, 24, 14][index % 7])
        let active = CGFloat([24, 12, 36, 22, 16, 32, 20][index % 7])
        return isAnimating ? active : resting
    }

    private func opacity(for index: Int) -> Double {
        isAnimating ? 0.92 - (Double(index % 4) * 0.08) : 0.28
    }

    private func duration(for index: Int) -> TimeInterval {
        0.58 + (Double(index % 4) * 0.08)
    }
}
