import SwiftUI

/// The 物品 entry: an open storage box (Paper「v13 物品页」icon option B), plain enough to read at a glance.
/// Drawn on a 24-point grid like SF Symbols.
struct ItemsGlyph: View {
    var size: CGFloat = 22
    var lineWidth: CGFloat = 1.7

    var body: some View {
        ItemsGlyphShape()
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ItemsGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        // Flaps opened outwards.
        path.move(to: CGPoint(x: 3.5, y: 10))
        path.addLine(to: CGPoint(x: 6.5, y: 5))
        path.addLine(to: CGPoint(x: 17.5, y: 5))
        path.addLine(to: CGPoint(x: 20.5, y: 10))
        // The box, rounded at the bottom.
        path.move(to: CGPoint(x: 3.5, y: 10))
        path.addLine(to: CGPoint(x: 20.5, y: 10))
        path.addLine(to: CGPoint(x: 20.5, y: 18.5))
        path.addArc(center: CGPoint(x: 18.5, y: 18.5), radius: 2, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: 5.5, y: 20.5))
        path.addArc(center: CGPoint(x: 5.5, y: 18.5), radius: 2, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        // The handle slot.
        path.move(to: CGPoint(x: 9.5, y: 10))
        path.addLine(to: CGPoint(x: 9.5, y: 13))
        path.addLine(to: CGPoint(x: 14.5, y: 13))
        path.addLine(to: CGPoint(x: 14.5, y: 10))
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}
