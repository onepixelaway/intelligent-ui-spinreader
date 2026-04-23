import SwiftUI

struct TrackpadSurface: View {
    private let cornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            DotMaskedLayers(size: geo.size)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: Color.black.opacity(0.6)
        )
        .allowsHitTesting(true)
    }
}

private struct DotMaskedLayers: View {
    let size: CGSize

    var body: some View {
        ZStack {
            Color.white.opacity(0.03)

            PurpleGlowLayer(size: size)
                .opacity(0.40)

            DiagonalShineLayer(size: size)
                .opacity(0.30)
        }
        .mask(DotGridMask())
    }
}

private struct DotGridMask: View {
    private let dotDiameter: CGFloat = 2
    private let spacing: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            let cols = max(1, Int(floor((size.width - dotDiameter) / spacing)) + 1)
            let rows = max(1, Int(floor((size.height - dotDiameter) / spacing)) + 1)
            let totalW = CGFloat(cols - 1) * spacing
            let totalH = CGFloat(rows - 1) * spacing
            let startX = (size.width - totalW) / 2
            let startY = (size.height - totalH) / 2

            for row in 0..<rows {
                for col in 0..<cols {
                    let cx = startX + CGFloat(col) * spacing
                    let cy = startY + CGFloat(row) * spacing
                    let rect = CGRect(
                        x: cx - dotDiameter / 2,
                        y: cy - dotDiameter / 2,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                }
            }
        }
    }
}

private struct PurpleGlowLayer: View {
    let size: CGSize

    private let xKeyframes: [CGFloat] = [0.2, 0.8, 0.3, 0.7, 0.2]
    private let yKeyframes: [CGFloat] = [0.3, 0.7, 0.8, 0.2, 0.3]
    private let cycle: Double = 6.0

    var body: some View {
        let endRadius = sqrt(size.width * size.width + size.height * size.height) * 0.65
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: cycle)) / cycle
            let (fx, fy) = keyframePosition(phase: phase)

            RadialGradient(
                stops: [
                    .init(color: Color(red: 0.77, green: 0.71, blue: 0.99), location: 0.0),
                    .init(color: Color(red: 0.65, green: 0.55, blue: 0.98).opacity(0.5), location: 0.3),
                    .init(color: .clear, location: 0.6)
                ],
                center: UnitPoint(x: fx, y: fy),
                startRadius: 0,
                endRadius: endRadius
            )
        }
    }

    private func keyframePosition(phase: Double) -> (CGFloat, CGFloat) {
        let segments = xKeyframes.count - 1
        let scaled = phase * Double(segments)
        let i = min(Int(scaled), segments - 1)
        let localRaw = scaled - Double(i)
        let eased = easeInOut(localRaw)
        let x = xKeyframes[i] + (xKeyframes[i + 1] - xKeyframes[i]) * CGFloat(eased)
        let y = yKeyframes[i] + (yKeyframes[i + 1] - yKeyframes[i]) * CGFloat(eased)
        return (x, y)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

private struct DiagonalShineLayer: View {
    let size: CGSize
    private let cycle: Double = 4.0

    // Gradient axis for a 115° (CSS clockwise-from-north) linear sweep.
    private static let shineStart = UnitPoint(x: 0.047, y: 0.289)
    private static let shineEnd = UnitPoint(x: 0.953, y: 0.711)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t.truncatingRemainder(dividingBy: cycle)) / cycle)

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.35),
                            .init(color: Color.white.opacity(0.9), location: 0.5),
                            .init(color: .clear, location: 0.65),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: Self.shineStart,
                        endPoint: Self.shineEnd
                    )
                )
                .frame(width: size.width * 2, height: size.height * 2)
                .offset(
                    x: -size.width + phase * (2 * size.width),
                    y: -size.height + phase * (2 * size.height)
                )
        }
    }
}
