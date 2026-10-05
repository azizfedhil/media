import SwiftUI
import ImageIO

/// Downsamples to display size via ImageIO (no full-size bitmaps in memory), caches in
/// NSCache + URLCache, and cancels with the view's task when scrolled offscreen.
actor ImagePipeline {
    static let shared = ImagePipeline()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 30 << 20, diskCapacity: 300 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()
    private var colorCache: [URL: UIColor] = [:]

    init() { cache.totalCostLimit = 60 << 20 }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let (data, _) = try? await session.data(from: url), !Task.isCancelled else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
        return img
    }

    /// Average colour of an image, nudged to be vivid but dark enough to sit behind white text.
    /// Used for the ambient glow behind the Home hero.
    func averageColor(for url: URL) async -> UIColor? {
        if let hit = colorCache[url] { return hit }
        guard let cg = await image(for: url, maxPixel: 48)?.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let base = UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let tuned = UIColor(hue: h, saturation: min(1, s * 1.3 + 0.08), brightness: min(max(b, 0.35), 0.62), alpha: 1)
        colorCache[url] = tuned
        return tuned
    }
}

struct RemoteImage: View {
    let url: URL?
    /// Longest edge in points; converted to pixels for downsampling.
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else if failed {
                    Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
                } else {
                    Shimmer()
                }
            }
            .clipped()
            .task(id: url) {
                failed = false
                guard let url else { failed = true; return }
                let img = await ImagePipeline.shared.image(for: url, maxPixel: size * scale)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { image = img }
                if img == nil { failed = true }
            }
    }
}

/// Soft highlight sweeping across a placeholder while its image loads.
struct Shimmer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.6)
                .offset(x: -g.size.width * 0.6 + phase * g.size.width * 1.6)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

/// Aspect-fit variant for transparent logos.
struct LogoImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .task(id: url) { image = await ImagePipeline.shared.image(for: url, maxPixel: 600) }
    }
}
