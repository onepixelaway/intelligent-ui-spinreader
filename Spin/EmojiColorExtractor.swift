import UIKit

@MainActor
final class EmojiColorExtractor {
    static let shared = EmojiColorExtractor()

    private var cache: [String: UIColor] = [:]
    private let renderSize: CGFloat = 64

    private init() {}

    func preloadDefaults() {
        for choice in HighlightEmojiChoice.allCases {
            _ = color(for: choice.emoji)
        }
    }

    func color(for emoji: String) -> UIColor {
        if let cached = cache[emoji] { return cached }
        if let override = colorOverride(for: emoji) {
            cache[emoji] = override
            return override
        }
        let extracted = computeColor(for: emoji) ?? UIColor.systemYellow
        cache[emoji] = extracted
        return extracted
    }

    // The heart and exclamation both extract as red; tint the heart pinker so they're distinguishable.
    private func colorOverride(for emoji: String) -> UIColor? {
        if emoji == HighlightEmojiChoice.heart.emoji {
            return UIColor(red: 1.0, green: 0.6, blue: 0.7, alpha: 1.0)
        }
        return nil
    }

    private func computeColor(for emoji: String) -> UIColor? {
        let font = UIFont.systemFont(ofSize: renderSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attributed = NSAttributedString(string: emoji, attributes: attributes)
        let textSize = attributed.size()
        let canvas = CGSize(
            width: max(1, ceil(textSize.width)),
            height: max(1, ceil(textSize.height))
        )

        let renderer = UIGraphicsImageRenderer(size: canvas)
        let image = renderer.image { _ in
            attributed.draw(at: .zero)
        }
        return averageColor(of: image)
    }

    private func averageColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Premultiplied alpha makes the alpha-weighted true-color average reduce to
        // sum(premulRGB) / sum(alpha). Skipping pixels with alpha < 16 trims faint
        // anti-alias halos that wash the average toward black on dark UI.
        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        var totalA: Double = 0

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * bytesPerPixel
                let alpha = pixels[idx + 3]
                if alpha < 16 { continue }
                totalR += Double(pixels[idx])
                totalG += Double(pixels[idx + 1])
                totalB += Double(pixels[idx + 2])
                totalA += Double(alpha)
            }
        }

        guard totalA > 0 else { return nil }
        return UIColor(
            red: CGFloat(totalR / totalA),
            green: CGFloat(totalG / totalA),
            blue: CGFloat(totalB / totalA),
            alpha: 1.0
        )
    }
}
