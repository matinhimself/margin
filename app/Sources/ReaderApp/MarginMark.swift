import SwiftUI

/// The open-book M, drawn as a vector so the sidebar follows the current ink color.
struct MarginMark: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 64
            Path { path in
                path.move(to: CGPoint(x: 12, y: 15))
                path.addCurve(to: CGPoint(x: 30, y: 25), control1: CGPoint(x: 20, y: 15), control2: CGPoint(x: 26, y: 19))
                path.addLine(to: CGPoint(x: 30, y: 49))
                path.addCurve(to: CGPoint(x: 12, y: 40), control1: CGPoint(x: 24, y: 43), control2: CGPoint(x: 19, y: 40))
                path.closeSubpath()
                path.addRect(CGRect(x: 17, y: 21, width: 2, height: 14))
                path.move(to: CGPoint(x: 34, y: 25))
                path.addCurve(to: CGPoint(x: 52, y: 15), control1: CGPoint(x: 40, y: 19), control2: CGPoint(x: 45, y: 15))
                path.addLine(to: CGPoint(x: 52, y: 40))
                path.addCurve(to: CGPoint(x: 34, y: 49), control1: CGPoint(x: 45, y: 40), control2: CGPoint(x: 40, y: 43))
                path.closeSubpath()
            }
            .transform(CGAffineTransform(scaleX: scale, y: scale))
            .fill(style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}
