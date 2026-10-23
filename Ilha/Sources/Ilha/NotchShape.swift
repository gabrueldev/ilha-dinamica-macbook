import SwiftUI

/// Forma do notch: cantos de cima curvando para fora, cantos de baixo arredondados.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tr = min(topRadius, w / 4, h / 2)
        let br = max(0, min(bottomRadius, (h - tr) / 2, (w - 2 * tr) / 2))
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y) }

        var path = Path()
        path.move(to: pt(0, 0))
        path.addQuadCurve(to: pt(tr, tr), control: pt(tr, 0))
        path.addLine(to: pt(tr, h - br))
        path.addQuadCurve(to: pt(tr + br, h), control: pt(tr, h))
        path.addLine(to: pt(w - tr - br, h))
        path.addQuadCurve(to: pt(w - tr, h - br), control: pt(w - tr, h))
        path.addLine(to: pt(w - tr, tr))
        path.addQuadCurve(to: pt(w, 0), control: pt(w - tr, 0))
        path.closeSubpath()
        return path
    }
}

/// Paleta do brilho arco-íris (o resto da ilha é preto e branco).
enum Rainbow {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.42, blue: 0.42),
        Color(red: 1.00, green: 0.73, blue: 0.35),
        Color(red: 0.98, green: 0.93, blue: 0.45),
        Color(red: 0.45, green: 0.92, blue: 0.62),
        Color(red: 0.40, green: 0.75, blue: 1.00),
        Color(red: 0.66, green: 0.52, blue: 1.00),
        Color(red: 1.00, green: 0.48, blue: 0.85),
        Color(red: 1.00, green: 0.42, blue: 0.42),
    ]
    static let gradient = Gradient(colors: colors)

    static func angular(_ t: Double, speed: Double = 90) -> AngularGradient {
        AngularGradient(gradient: gradient, center: .center, angle: .degrees((t * speed).truncatingRemainder(dividingBy: 360)))
    }
}

/// Brilho arco-íris girando em volta de uma forma.
struct RainbowGlow<S: Shape>: View {
    var shape: S
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = 0.75 + 0.25 * sin(t * 2.2)
            ZStack {
                shape.stroke(Rainbow.angular(t), lineWidth: 6)
                    .blur(radius: 14)
                    .opacity(0.9 * breathe * intensity)
                shape.stroke(Rainbow.angular(t), lineWidth: 1.5)
                    .blur(radius: 2)
                    .opacity(0.8 * intensity)
            }
        }
        .allowsHitTesting(false)
    }
}
