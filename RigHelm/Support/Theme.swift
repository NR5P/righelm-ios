import SwiftUI

/// RigHelm's colours (from the desktop app's widgets).
enum Theme {
    static let amber = Color(red: 1, green: 176 / 255, blue: 46 / 255)
    static let cyan = Color(red: 80 / 255, green: 200 / 255, blue: 1)
    static let green = Color(red: 90 / 255, green: 220 / 255, blue: 120 / 255)
    static let red = Color(red: 235 / 255, green: 70 / 255, blue: 60 / 255)
    static let dim = Color(red: 90 / 255, green: 90 / 255, blue: 96 / 255)
    static let panel = Color(red: 14 / 255, green: 16 / 255, blue: 20 / 255)
    static let card = Color(red: 24 / 255, green: 27 / 255, blue: 33 / 255)
    static let background = Color(red: 9 / 255, green: 11 / 255, blue: 14 / 255)
    /// The logo's wooden wheel.
    static let wood = LinearGradient(colors: [Color(red: 1, green: 0.79, blue: 0.54), Color(red: 0.88, green: 0.5, blue: 0.19), Color(red: 0.59, green: 0.31, blue: 0.11)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A rounded dark panel, like RigHelm's frames.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

/// A button that lights up when on (RigHelm's "LED" buttons).
struct LEDButton: View {
    let title: String
    let on: Bool
    var color: Color = Theme.amber
    var minWidth: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                .background(on ? color : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal level bar with a label and value text.
struct MeterBar: View {
    let label: String
    let fraction: Double
    let text: String
    var color: Color = Theme.cyan
    /// Fraction from which the bar turns red.
    var redFrom: Double?
    var ticks: [(Double, String)] = []
    var height: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.dim)
                .frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                let f = min(max(fraction, 0), 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.5))
                    if let r = redFrom, f > r {
                        HStack(spacing: 0) {
                            Rectangle().fill(color).frame(width: w * r)
                            Rectangle().fill(Theme.red).frame(width: w * (f - r))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: w * f)
                    }
                    ForEach(ticks.indices, id: \.self) { i in
                        Text(ticks[i].1)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .position(x: w * ticks[i].0, y: geo.size.height / 2)
                    }
                }
                .animation(.linear(duration: 0.12), value: f)
            }
            .frame(height: height)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 62, alignment: .trailing)
        }
    }
}
