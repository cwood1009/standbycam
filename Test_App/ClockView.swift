import SwiftUI

struct ClockView: View {
    var use24h: Bool
    var showDate: Bool
    var isRecording: Bool

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = use24h ? "HH:mm" : "h:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date

            VStack(spacing: 5) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(timeString(now))
                        .tallSF(size: 280,
                                weight: .light,
                                rounded: false,
                                xScale: 0.95,
                                yScale: 1.56,
                                kerning: -8)
                }

                if showDate {
                    Text(now.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(isRecording ? 0.45 : 0.62))
                        .animation(.easeInOut(duration: 0.3), value: isRecording)
                }
            }
            .padding(.horizontal, 0)
        }
    }
}

private struct CompressedIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.fontWidth(.compressed)
        } else {
            content
        }
    }
}

private struct TallSFStyle: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let useRounded: Bool
    let xScale: CGFloat
    let yScale: CGFloat
    let kerning: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: useRounded ? .rounded : .default))
            .modifier(CompressedIfAvailable())
            .kerning(kerning)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.50))
            .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
            .minimumScaleFactor(0.2)
            .lineLimit(1)
            .scaleEffect(x: xScale, y: yScale, anchor: .center)
            .modifier(NarrowFallback())
            .drawingGroup()
    }
}

extension View {
    func tallSF(size: CGFloat,
                weight: Font.Weight = .black,
                rounded: Bool = true,
                xScale: CGFloat = 0.88,
                yScale: CGFloat = 1.12,
                kerning: CGFloat = -6) -> some View {
        modifier(TallSFStyle(size: size,
                             weight: weight,
                             useRounded: rounded,
                             xScale: xScale,
                             yScale: yScale,
                             kerning: kerning))
    }
}

private struct NarrowFallback: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
        } else {
            content
                .scaleEffect(x: 0.86, y: 1.0, anchor: .center)
                .allowsTightening(true)
        }
    }
}
