import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The colours a slide or worship background is made of, strongest first,
/// for the SlimPARs to match.
public enum ImagePalette {
    /// Below this share of vivid colour the picture counts as black and
    /// white, and the lights get white.
    static let minimumVividShare = 0.02

    /// The picture's colours, or white for a black-and-white one: what a
    /// dropped picture gives the SlimPARs.
    public static func colors(in image: CGImage, count: Int = 5) -> [LightColor] {
        let vivid = vividColors(in: image, count: count)
        return vivid.isEmpty ? [.white] : vivid
    }

    /// Only real colour; empty for black, grey or white. A song matching
    /// Screens keeps its own colour then, rather than turning white.
    public static func vividColors(in image: CGImage, count: Int = 5) -> [LightColor] {
        let side = 48
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // Hue buckets weighted by how vivid each pixel is, so a dark
        // background with a blue glow reads as blue, not black, and a
        // little bright colour outweighs a lot of grey.
        let bins = 36
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var total = 0.0
        for i in 0..<(side * side) {
            let alpha = Double(pixels[i * 4 + 3]) / 255
            guard alpha > 0.1 else { continue }
            let r = Double(pixels[i * 4]) / 255 / alpha
            let g = Double(pixels[i * 4 + 1]) / 255 / alpha
            let b = Double(pixels[i * 4 + 2]) / 255 / alpha
            let peak = max(r, g, b), low = min(r, g, b)
            total += 1
            guard peak > 0.12 else { continue }
            let saturation = (peak - low) / peak
            guard saturation > 0.2 else { continue }
            let w = saturation * saturation * peak
            let bin = min(Int(hue(r, g, b) / 360 * Double(bins)), bins - 1)
            weight[bin] += w
            sums[bin].0 += r * w
            sums[bin].1 += g * w
            sums[bin].2 += b * w
        }
        guard total > 0, weight.reduce(0, +) / total >= minimumVividShare else { return [] }

        var result: [LightColor] = []
        var taken = Set<Int>()
        while result.count < count {
            guard let best = (0..<bins).filter({ !taken.contains($0) && weight[$0] > 0 })
                .max(by: { weight[$0] < weight[$1] }) else { break }
            // A bucket next to one already taken is the same colour.
            for offset in -1...1 { taken.insert((best + offset + bins) % bins) }
            let w = weight[best]
            result.append(LightColor(red: sums[best].0 / w, green: sums[best].1 / w, blue: sums[best].2 / w).atFullStrength)
        }
        return result
    }

    public static func colors(at url: URL, count: Int = 5) -> [LightColor]? {
        guard let image = cgImage(at: url) else { return nil }
        return colors(in: image, count: count)
    }

    /// What a dropped file looks like: an image's first frame, or a video's
    /// frame one second in (motion backgrounds often open on black).
    public static func picture(at url: URL) async -> CGImage? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            for seconds in [1.0, 0] {
                if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                    return image
                }
            }
            return nil
        }
        return cgImage(at: url)
    }

    /// Big enough for the thumbnail, small enough that a 6K photo or a 4K
    /// video frame doesn't stall the app.
    static let maxSide = 1280

    /// The first frame of any image macOS can read, at most `maxSide` across,
    /// the right way up.
    public static func cgImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let peak = max(r, g, b), low = min(r, g, b), d = peak - low
        guard d > 0 else { return 0 }
        var h: Double
        if peak == r { h = (g - b) / d } else if peak == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }
}
