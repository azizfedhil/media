import SwiftUI
import UIKit
import AetherEngine

/// Reads fields off engine types by name. The engine's `TrackInfo` / `SubtitleCue` / `SubtitleImage` field
/// types (optional or not, Int vs Int32 ...) can shift between releases; this keeps the app compiling either way.
enum Reflect {
    static func unwrap(_ v: Any?) -> Any? {
        guard let v else { return nil }
        let m = Mirror(reflecting: v)
        guard m.displayStyle == .optional else { return v }
        guard let first = m.children.first else { return nil }
        return unwrap(first.value)
    }
    static func value(_ obj: Any, _ name: String) -> Any? {
        for c in Mirror(reflecting: obj).children where c.label == name { return unwrap(c.value) }
        return nil
    }
    static func string(_ obj: Any, _ name: String) -> String? { value(obj, name) as? String }
    static func bool(_ obj: Any, _ name: String) -> Bool { (value(obj, name) as? Bool) ?? false }
    static func double(_ obj: Any, _ name: String) -> Double? {
        guard let v = value(obj, name) else { return nil }
        return number(v)
    }
    static func number(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let f = v as? Float { return Double(f) }
        if let i = v as? Int { return Double(i) }
        if let i = v as? Int64 { return Double(i) }
        if let i = v as? Int32 { return Double(i) }
        if let c = v as? CGFloat { return Double(c) }
        return nil
    }
    static func int(_ v: Any?) -> Int? {
        guard let u = unwrap(v) else { return nil }
        if let i = u as? Int { return i }
        if let i = u as? Int32 { return Int(i) }
        if let i = u as? Int64 { return Int(i) }
        if let i = u as? UInt32 { return Int(i) }
        return nil
    }

    /// Plain text of a cue payload: handles `.text(String)` and styled `.richText([runs])` alike.
    static func text(_ any: Any?) -> String {
        guard let v = unwrap(any) else { return "" }
        if let s = v as? String { return s }
        let m = Mirror(reflecting: v)
        switch m.displayStyle {
        case .collection:
            return m.children.map { text($0.value) }.joined()
        case .struct, .class:
            for key in ["text", "string", "content"] { if let t = value(v, key) { let s = text(t); if !s.isEmpty { return s } } }
            return ""
        case .enum, .tuple:
            return m.children.first.map { text($0.value) } ?? ""
        default:
            return ""
        }
    }

    static func cgImage(_ any: Any?, depth: Int = 0) -> CGImage? {
        guard depth < 3, let v = unwrap(any) else { return nil }
        // `as? CGImage` is rejected for CF types ("will always succeed"); compare CFTypeIDs instead.
        let obj = v as AnyObject
        if CFGetTypeID(obj) == CGImage.typeID { return unsafeBitCast(obj, to: CGImage.self) }
        if let u = v as? UIImage { return u.cgImage }
        for c in Mirror(reflecting: v).children { if let i = cgImage(c.value, depth: depth + 1) { return i } }
        return nil
    }

    static func normalizedRect(_ any: Any?) -> CGRect? {
        guard let v = unwrap(any) else { return nil }
        for c in Mirror(reflecting: v).children {
            if let r = unwrap(c.value) as? CGRect, r.width > 0, r.height > 0 { return r }
        }
        return nil
    }

    /// "English", "English (SDH)", "Spanish · Forced"...
    static func trackTitle(_ t: Any) -> String {
        let id = int(value(t, "id")) ?? 0
        let lang = string(t, "language")
        let name = string(t, "name")
        var base = "Track \(id)"
        if let l = lang, !l.isEmpty, l.lowercased() != "und" {
            base = Locale.current.localizedString(forLanguageCode: l)?.capitalized ?? l.uppercased()
        } else if let n = name, !n.isEmpty { base = n }
        if let n = name, !n.isEmpty, n.caseInsensitiveCompare(base) != .orderedSame,
           n.caseInsensitiveCompare(lang ?? "") != .orderedSame { base += " (\(n))" }
        if bool(t, "isForced") { base += " · Forced" }
        if bool(t, "isHearingImpaired") { base += " · SDH" }
        if bool(t, "isExternal") { base += " · External" }
        return base
    }
}

/// One subtitle line or bitmap, flattened from the engine's `SubtitleCue`.
struct SubCue: Equatable {
    let start: Double
    let end: Double
    let text: String
    let image: CGImage?
    let rect: CGRect?       // normalised placement of a bitmap on the video canvas, when the engine provides it

    static func == (a: SubCue, b: SubCue) -> Bool {
        a.start == b.start && a.end == b.end && a.text == b.text
            && a.image?.width == b.image?.width && a.image?.height == b.image?.height && a.rect == b.rect
    }

    static func make(_ c: SubtitleCue) -> SubCue? {
        let start = Double(c.startTime)
        let end = Reflect.double(c, "endTime") ?? Reflect.double(c, "end")
            ?? Reflect.double(c, "duration").map { start + $0 } ?? start + 5
        let payload = Mirror(reflecting: c.body).children.first?.value
        let image = Reflect.cgImage(payload)
        var text = image == nil ? Reflect.text(payload) : ""
        // Strip leftover ASS override tags ({\an8}, {\i1}...) and convert hard line breaks.
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard image != nil || !text.isEmpty else { return nil }
        return SubCue(start: start, end: end, text: text, image: image, rect: image == nil ? nil : Reflect.normalizedRect(payload))
    }
}

/// Paints the active cues over the video. Text is drawn natively; PGS / DVD bitmaps are placed on a 16:9 canvas.
struct SubtitleOverlay: View {
    let cues: [SubCue]
    let lift: CGFloat
    /// User-chosen text size multiplier (1 = default).
    var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let video = Self.videoRect(in: size)
            let lines = cues.filter { $0.image == nil }.map(\.text).joined(separator: "\n")
            ZStack {
                ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                    bitmap(cue, video: video, size: size)
                }
                if !lines.isEmpty {
                    VStack {
                        Spacer(minLength: 0)
                        Text(lines)
                            .font(.system(size: (size.width > 700 ? 30 : 21) * scale, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 1.5).shadow(color: .black, radius: 3)
                            .frame(maxWidth: size.width * 0.9)
                            .padding(.bottom, 40 + lift)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder private func bitmap(_ cue: SubCue, video: CGRect, size: CGSize) -> some View {
        if let img = cue.image {
            let pic = Image(decorative: img, scale: 1).resizable()
            if let r = cue.rect, r.maxX <= 1.01, r.maxY <= 1.01 {
                pic.frame(width: r.width * video.width, height: r.height * video.height)
                    .position(x: video.minX + r.midX * video.width, y: video.minY + r.midY * video.height)
            } else {
                pic.scaledToFit()
                    .frame(maxWidth: size.width * 0.9, maxHeight: size.height * 0.3 * min(scale, 1.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40 + lift)
            }
        }
    }

    private static func videoRect(in s: CGSize) -> CGRect {
        let ar: CGFloat = 16.0 / 9.0
        var w = s.width, h = s.width / ar
        if h > s.height { h = s.height; w = h * ar }
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }
}
