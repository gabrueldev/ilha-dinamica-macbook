import SwiftUI

enum MascotMood: Equatable {
    case idle, working, waiting, done, eating
}

/// O mascote da Ilha: uma gotinha branca com olhos pretos.
struct Mascot: View {
    var mood: MascotMood
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                draw(&ctx, canvasSize, t)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if mood == .waiting {
                Text("!")
                    .font(.system(size: size * 0.5, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: Rainbow.colors, startPoint: .top, endPoint: .bottom))
                    .offset(x: size * 0.22, y: -size * 0.22)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ canvas: CGSize, _ t: Double) {
        let w = canvas.width
        let h = canvas.height
        var bounce: CGFloat = 0
        var look: CGFloat = 0
        switch mood {
        case .working:
            bounce = -abs(sin(t * 5)) * h * 0.07
            look = sin(t * 2.6) * w * 0.07
        case .eating:
            bounce = -abs(sin(t * 7)) * h * 0.04
        case .done:
            bounce = -abs(sin(t * 3)) * h * 0.03
        default:
            break
        }

        let body = CGRect(x: w * 0.06, y: h * 0.08 + bounce, width: w * 0.88, height: h * 0.9)
        ctx.fill(
            Self.dropPath(in: body),
            with: .linearGradient(
                Gradient(colors: [.white, Color(white: 0.82)]),
                startPoint: CGPoint(x: body.midX, y: body.minY),
                endPoint: CGPoint(x: body.midX, y: body.maxY)
            )
        )

        let eyeY = body.minY + body.height * (mood == .eating ? 0.55 : 0.6)
        let spacing = body.width * 0.17
        let eyeW = body.width * 0.12
        let eyeH = body.height * 0.17

        for side in [-1.0, 1.0] {
            let ex = body.midX + side * spacing + look
            if mood == .done {
                var arc = Path()
                arc.move(to: CGPoint(x: ex - eyeW * 0.9, y: eyeY + eyeH * 0.15))
                arc.addQuadCurve(to: CGPoint(x: ex + eyeW * 0.9, y: eyeY + eyeH * 0.15),
                                 control: CGPoint(x: ex, y: eyeY - eyeH * 0.75))
                ctx.stroke(arc, with: .color(.black), style: StrokeStyle(lineWidth: max(1.2, w * 0.06), lineCap: .round))
            } else {
                var ew = eyeW
                var eh = eyeH
                if mood == .waiting { ew *= 1.35; eh *= 1.3 }
                if mood == .idle && Self.isBlinking(t) { eh *= 0.15 }
                ctx.fill(Path(ellipseIn: CGRect(x: ex - ew / 2, y: eyeY - eh / 2, width: ew, height: eh)), with: .color(.black))
            }
        }

        if mood == .eating {
            let open = 0.75 + 0.25 * sin(t * 9)
            let mw = body.width * 0.2
            let mh = body.height * 0.17 * open
            ctx.fill(Path(ellipseIn: CGRect(x: body.midX - mw / 2, y: eyeY + eyeH * 0.8, width: mw, height: mh)), with: .color(.black))
        }
    }

    /// Pisca em intervalos "aleatórios" de 2 a 6 s, sem guardar estado.
    static func isBlinking(_ t: Double) -> Bool {
        let period = 4.0
        let k = floor(t / period)
        let offset = abs(sin(k * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) * 2
        let local = t - k * period - offset
        return local >= 0 && local < 0.13
    }

    static func dropPath(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var path = Path()
        path.move(to: p(0.5, 0))
        path.addCurve(to: p(0.97, 0.63), control1: p(0.66, 0.2), control2: p(0.97, 0.38))
        path.addCurve(to: p(0.5, 1), control1: p(0.97, 0.86), control2: p(0.76, 1))
        path.addCurve(to: p(0.03, 0.63), control1: p(0.24, 1), control2: p(0.03, 0.86))
        path.addCurve(to: p(0.5, 0), control1: p(0.03, 0.38), control2: p(0.34, 0.2))
        path.closeSubpath()
        return path
    }
}
