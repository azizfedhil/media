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
}

struct RemoteImage: View {
    let url: URL?
    /// Longest edge in points; converted to pixels for downsampling.
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                let img = await ImagePipeline.shared.image(for: url, maxPixel: size * scale)
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
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
