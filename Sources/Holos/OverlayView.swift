import SwiftUI

enum OverlayPhase: Equatable {
    /// handsFree — запис без утримання клавіші
    case hidden, recording, handsFree, transcribing, done, failed
}

final class OverlayModel: ObservableObject {
    @Published private(set) var phase: OverlayPhase = .hidden
    private(set) var previousPhase: OverlayPhase = .hidden
    private(set) var phaseChangedAt: TimeInterval = 0

    // Рівень гучності не @Published: його щокадру читає Canvas, перемальовувати весь SwiftUI не треба
    private var peak = 0.0
    private var peakAt: TimeInterval = 0

    func set(_ newPhase: OverlayPhase, at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard newPhase != phase else { return }
        previousPhase = phase
        phaseChangedAt = time
        phase = newPhase
    }

    func push(rms: Float, at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        let decibels = 20 * log10(max(Double(rms), 1e-6))
        let normalized = min(1, max(0, (decibels + 52) / 40))
        peak = max(normalized, level(at: time))
        peakAt = time
    }

    /// Миттєва атака й плавне згасання — смужки не смикаються між порціями аудіо
    func level(at time: TimeInterval) -> Double {
        peak * exp(-max(0, time - peakAt) * 6)
    }
}

/// Пігулка, що анімується в часі
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        let hidden = model.phase == .hidden
        TimelineView(.animation(minimumInterval: nil, paused: hidden)) { context in
            OverlayPill(model: model, time: context.date.timeIntervalSinceReferenceDate)
        }
        .scaleEffect(hidden ? 0.6 : 1)
        .opacity(hidden ? 0 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Один кадр пігулки в момент `time`. Без власного стану — тому її можна відрендерити й для перевірки.
struct OverlayPill: View {
    let model: OverlayModel
    let time: TimeInterval

    private static let barCount = 13
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3
    private static let height: CGFloat = 20
    private static let indicatorSize: CGFloat = 14
    private static let gap: CGFloat = 10
    private static let morphDuration = 0.35

    private static var barsWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    var body: some View {
        Canvas { context, _ in draw(context) }
            .frame(width: Self.indicatorSize + Self.gap + Self.barsWidth, height: Self.height)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule().fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    // MARK: - Малювання

    private func draw(_ context: GraphicsContext) {
        let progress = min(1, max(0, (time - model.phaseChangedAt) / Self.morphDuration))
        let blend = progress * progress * (3 - 2 * progress) // smoothstep
        let level = model.level(at: time)
        let from = model.previousPhase
        let to = model.phase

        for (phase, alpha) in [(from, 1 - blend), (to, blend)] where alpha > 0.01 {
            var layer = context
            layer.opacity = alpha
            drawIndicator(phase, level: level, in: layer)
        }

        let midY = Self.height / 2
        let minHeight = Self.barWidth
        for i in 0..<Self.barCount {
            let value = mix(barHeight(from, i, level), barHeight(to, i, level), blend)
            let height = minHeight + CGFloat(value) * (Self.height - minHeight)
            let x = Self.indicatorSize + Self.gap + CGFloat(i) * (Self.barWidth + Self.barSpacing)
            let rect = CGRect(x: x, y: midY - height / 2, width: Self.barWidth, height: height)
            let color = barColor(from, i).mix(barColor(to, i), blend)
            context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(color.color))
        }
    }

    /// Висота смужки 0…1
    private func barHeight(_ phase: OverlayPhase, _ i: Int, _ level: Double) -> Double {
        let x = Double(i) / Double(Self.barCount - 1)
        let profile = 0.4 + 0.6 * exp(-pow((x - 0.5) / 0.28, 2)) // у центрі вищі
        switch phase {
        case .hidden, .done, .failed:
            return 0
        case .recording, .handsFree:
            return min(1, pow(level, 0.8) * 1.15) * profile * (0.65 + 0.35 * sin(time * 10 + Double(i) * 1.9))
        case .transcribing:
            // Хвиля, що біжить зліва направо
            return (0.12 + 0.78 * pow(0.5 + 0.5 * sin(time * 6.5 - Double(i) * 0.62), 2)) * profile
        }
    }

    private func barColor(_ phase: OverlayPhase, _ i: Int) -> RGB {
        switch phase {
        case .hidden, .recording, .handsFree:
            return RGB(0.96, 0.96, 0.98)
        case .transcribing:
            return RGB.palette(Double(i) / Double(Self.barCount) * 0.9 - time * 0.45)
        case .done:
            return RGB(0.34, 0.84, 0.5)
        case .failed:
            return RGB(1, 0.36, 0.36)
        }
    }

    private func drawIndicator(_ phase: OverlayPhase, level: Double, in context: GraphicsContext) {
        let center = CGPoint(x: Self.indicatorSize / 2, y: Self.height / 2)
        switch phase {
        case .hidden:
            break
        case .recording:
            let red = RGB(1, 0.32, 0.32).color
            let halo = 4 + 3.5 * level
            context.fill(Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
                         with: .color(red.opacity(0.3)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(red))
        case .handsFree:
            // Квадратик «стоп»: клавішу можна відпустити, наступне натискання завершить запис
            let red = RGB(1, 0.32, 0.32).color
            let halo = 4.5 + 3.5 * level
            context.fill(Path(roundedRect: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2),
                              cornerRadius: halo * 0.45), with: .color(red.opacity(0.3)))
            context.fill(Path(roundedRect: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8), cornerRadius: 2),
                         with: .color(red))
        case .transcribing:
            let start = Angle.degrees(time * 400)
            var arc = Path()
            arc.addArc(center: center, radius: 5.5, startAngle: start, endAngle: start + .degrees(250), clockwise: false)
            context.stroke(arc, with: .color(RGB.palette(-time * 0.45).color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        case .done:
            var check = Path()
            check.move(to: CGPoint(x: center.x - 4, y: center.y + 0.2))
            check.addLine(to: CGPoint(x: center.x - 1.2, y: center.y + 3))
            check.addLine(to: CGPoint(x: center.x + 4, y: center.y - 2.8))
            context.stroke(check, with: .color(RGB(0.34, 0.84, 0.5).color),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .failed:
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - 3.5, y: center.y - 3.5))
            cross.addLine(to: CGPoint(x: center.x + 3.5, y: center.y + 3.5))
            cross.move(to: CGPoint(x: center.x + 3.5, y: center.y - 3.5))
            cross.addLine(to: CGPoint(x: center.x - 3.5, y: center.y + 3.5))
            context.stroke(cross, with: .color(RGB(1, 0.36, 0.36).color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

struct RGB {
    let r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// Циклічний градієнт блакитний → фіолетовий → рожевий → блакитний
    static func palette(_ position: Double) -> RGB {
        let stops = [RGB(0.35, 0.78, 1.0), RGB(0.62, 0.47, 1.0), RGB(1.0, 0.46, 0.76)]
        let p = position - floor(position)
        let scaled = p * Double(stops.count)
        let index = Int(scaled) % stops.count
        return stops[index].mix(stops[(index + 1) % stops.count], scaled - floor(scaled))
    }
}
