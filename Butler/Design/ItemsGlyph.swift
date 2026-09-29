import SwiftUI

/// The 物品 entry: an open box with a bottle, a ball and a spark coming out of it, so it reads as
/// "all sorts of things" rather than a parcel or a fridge. Drawn on a 24-point grid like SF Symbols.
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
        // The box: open top, rounded bottom corners.
        path.move(to: CGPoint(x: 4, y: 12))
        path.addLine(to: CGPoint(x: 20, y: 12))
        path.addLine(to: CGPoint(x: 20, y: 18.5))
        path.addArc(center: CGPoint(x: 18, y: 18.5), radius: 2, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: 6, y: 20.5))
        path.addArc(center: CGPoint(x: 6, y: 18.5), radius: 2, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        // A bottle standing in it.
        path.move(to: CGPoint(x: 8.3, y: 12))
        path.addLine(to: CGPoint(x: 8.3, y: 7.3))
        path.addLine(to: CGPoint(x: 11, y: 7.3))
        path.addLine(to: CGPoint(x: 11, y: 12))
        // A ball beside it.
        path.addEllipse(in: CGRect(x: 15.6 - 3.2, y: 8.8 - 3.2, width: 6.4, height: 6.4))
        // A small spark above.
        path.move(to: CGPoint(x: 6, y: 3.2))
        path.addLine(to: CGPoint(x: 6, y: 5.8))
        path.move(to: CGPoint(x: 4.7, y: 4.5))
        path.addLine(to: CGPoint(x: 7.3, y: 4.5))
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}
