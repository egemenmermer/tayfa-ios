import SwiftUI
import AVKit
import ImageIO
import LiveKit
import RoomsCore

// MARK: Message text

/// Rendered message text is reused while the content and the mentioned names stay the same.
@MainActor private enum MessageTextCache {
    final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    static let cache: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.countLimit = 400; return cache }()
    static func text(_ message: ChatMessage, chat: ChatController) -> AttributedString {
        let key = (message.content + "\u{1E}" + message.mentions.map(chat.mentionName).joined(separator: "\u{1F}")) as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        var text = MessageMarkup.render(message.content, name: chat.mentionName)
        // Mentions look like desktop's `<mark>`: accent text on a soft accent background.
        for (value, range) in text.runs[MentionAttribute.self] where value != nil {
            text[range].foregroundColor = Palette.accent; text[range].backgroundColor = Palette.accent.opacity(0.16)
        }
        cache.setObject(Box(text), forKey: key)
        return text
    }
}

/// Message text with inline markdown, tappable links, mentions and community emoji.
struct MessageTextView: View {
    @ObservedObject var chat: ChatController
    let message: ChatMessage
    @State private var emojis: [String: UIImage] = [:]
    var body: some View {
        let text = MessageTextCache.text(message, chat: chat)
        let ids = text.runs[CustomEmojiAttribute.self].compactMap(\.0)
        Group {
            if ids.isEmpty { Text(text) } else { Self.compose(text, images: emojis) }
        }
        .font(.body).foregroundStyle(Color.primary.opacity(0.9)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).lineSpacing(3)
        .task(id: ids) {
            for id in Set(ids) where emojis[id] == nil {
                guard let url = try? await chat.emojiImage(id), !Task.isCancelled else { continue }
                if let image = EmojiImage.inline(url) { emojis[id] = image }
            }
        }
    }
    /// Emoji runs become inline images once loaded; until then their `:id:` text stays.
    private static func compose(_ text: AttributedString, images: [String: UIImage]) -> Text {
        var result = Text("")
        for (id, range) in text.runs[CustomEmojiAttribute.self] {
            let piece: Text
            if let id, let image = images[id] { piece = Text(Image(uiImage: image)).baselineOffset(-4) }
            else { piece = Text(AttributedString(text[range])) }
            result = Text("\(result)\(piece)")
        }
        return result
    }
}

enum EmojiImage {
    /// A community emoji drawn at text size.
    static func inline(_ url: URL, points: CGFloat = 22) -> UIImage? {
        guard let image = thumbnail(url, pixels: Int(points * 3)) else { return nil }
        let box = CGRect(origin: .zero, size: CGSize(width: points, height: points))
        return UIGraphicsImageRenderer(size: box.size).image { _ in image.draw(in: AVMakeRect(aspectRatio: image.size, insideRect: box)) }
    }
}

// MARK: Reactions

/// A reaction key as shown: the emoji, a community emoji image, or 🙂 for an unreadable key.
struct ReactionLabel: View {
    @ObservedObject var chat: ChatController
    let key: String
    var size: CGFloat = 18
    @State private var image: UIImage?
    var body: some View {
        if let symbol = ReactionKey.symbol(key) { Text(symbol) }
        else if ReactionKey.isCustom(key) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "face.smiling").foregroundStyle(.secondary) }
            }.frame(width: size, height: size)
                .task(id: key) { if let url = try? await chat.emojiImage(key), !Task.isCancelled { image = thumbnail(url, pixels: Int(size * 3)) } }
        } else { Text("🙂") }
    }
    static func name(_ key: String, chat: ChatController) -> String {
        ReactionKey.symbol(key) ?? chat.emojiName(key).map { ":\($0):" } ?? "Topluluk emojisi"
    }
}

// MARK: Animated images

/// Plays GIF, APNG or WebP frames with ImageIO while on screen; one frame is decoded at a time.
/// Very large or very long images stay on their first frame.
struct AnimatedImage: UIViewRepresentable {
    let data: Data
    var fill = false
    func makeUIView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView(); view.clipsToBounds = true; view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit; view.load(data); return view
    }
    func updateUIView(_ view: AnimatedImageView, context: Context) { view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit; view.load(data) }
    static func dismantleUIView(_ view: AnimatedImageView, coordinator: ()) { view.stop() }
}
final class AnimatedImageView: UIImageView {
    @MainActor private final class Run { var stopped = false }
    private var data: Data?
    private var run: Run?
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
    func load(_ data: Data) {
        guard data != self.data else { return }
        stop(); self.data = data; image = Self.firstFrame(data); start()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stop() } else { start() } }
    private func start() {
        guard run == nil, window != nil, let data, Self.animates(data) else { return }
        let run = Run(); self.run = run
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
            MainActor.assumeIsolated {
                guard let self, !run.stopped else { stop.pointee = true; return }
                self.image = UIImage(cgImage: frame)
            }
        }
        if status != noErr { self.run = nil }
    }
    func stop() { run?.stopped = true; run = nil }
    static func firstFrame(_ data: Data, pixels: Int = 960) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    /// Bounded work: at most 400 frames of at most ~1.5 megapixels from at most 16 MB.
    static func animates(_ data: Data) -> Bool {
        guard data.count <= 16_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let frames = CGImageSourceGetCount(source)
        guard frames > 1, frames <= 400, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return false }
        return width * height <= 1_500_000
    }
}

/// KLIPY GIF bytes from its CDN, shared by the picker and the conversation.
@MainActor enum RemoteGifs {
    private static let cache: NSCache<NSURL, NSData> = { let cache = NSCache<NSURL, NSData>(); cache.totalCostLimit = 32 * 1024 * 1024; return cache }()
    static func data(_ url: URL, limit: Int) async throws -> Data {
        if let hit = cache.object(forKey: url as NSURL) { return hit as Data }
        guard GifPolicy.mediaURL(url.absoluteString) != nil else { throw RoomsError.invalidEndpoint }
        let data = try await ExternalFetcher.shared.data(url, allowedHosts: [GifPolicy.mediaHost], limit: limit)
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}

/// A GIF sent from the picker: the message is its KLIPY link, shown as the picture (desktop `chat-gif`).
struct KlipyMessageGif: View {
    let url: URL
    @State private var data: Data?
    @State private var aspect: CGFloat = 4 / 3
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        Group {
            if let data { AnimatedImage(data: data).aspectRatio(aspect, contentMode: .fit) }
            else {
                RoundedRectangle(cornerRadius: 10).fill(Palette.surface).aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if failed { Button("GIF açılamadı. Yeniden dene", systemImage: "arrow.clockwise") { attempt += 1 }.font(.caption).padding(8) }
                        else { ProgressView() }
                    }
            }
        }.frame(maxWidth: 260, maxHeight: 260, alignment: .leading).clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("GIF")
            .task(id: "\(url.absoluteString)#\(attempt)") {
                failed = false
                do {
                    let value = try await RemoteGifs.data(url, limit: 8_000_000)
                    guard !Task.isCancelled else { return }
                    if let frame = AnimatedImageView.firstFrame(value, pixels: 64), frame.size.height > 0 { aspect = max(0.4, min(2.5, frame.size.width / frame.size.height)) }
                    data = value
                } catch { if !Task.isCancelled { failed = true } }
            }
    }
}

// MARK: Video attachments

enum ChatVideo {
    /// Desktop plays MP4, WebM and QuickTime in place; iPhone plays the formats AVFoundation reads.
    static func playable(_ mime: String) -> Bool { ["video/mp4", "video/quicktime", "video/x-m4v"].contains(mime.lowercased()) }
}
/// Owns a downloaded video file for as long as the row exists (used on the main actor only).
private final class VideoFile: ObservableObject {
    @Published var url: URL?
    @Published var poster: UIImage?
    deinit { if let url { FileStager.remove(url) } }
}
private struct VideoRequest: Identifiable { let id = UUID(); let url: URL }

/// A shared video: like desktop, nothing downloads until play is pressed; then a poster frame stays.
struct VideoAttachmentCard: View {
    @ObservedObject var chat: ChatController
    let attachment: ChatAttachment
    let message: ChatMessage
    let openFile: () -> Void
    @StateObject private var file = VideoFile()
    @State private var loading = false
    @State private var failed = false
    @State private var playing: VideoRequest?
    private var size: String { ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { play() } label: {
                ZStack {
                    if let poster = file.poster { Image(uiImage: poster).resizable().scaledToFill() } else { Palette.surface }
                    if loading { ProgressView().tint(.white) }
                    else { Image(systemName: "play.fill").font(.title2).foregroundStyle(.white).frame(width: 54, height: 54).background(.black.opacity(0.5), in: Circle()) }
                }.frame(maxWidth: 300).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(loading).accessibilityLabel(loading ? "Video yükleniyor" : "\(attachment.name) videosunu oynat")
            HStack(spacing: 8) {
                Text(failed ? "Video oynatılamadı. Yeniden dene ya da dosyayı aç." : "Video · \(size)").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Dosyayı aç", action: openFile).font(.caption).frame(minHeight: 44).accessibilityLabel("\(attachment.name) dosyasını aç veya kaydet")
            }.frame(maxWidth: 300)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .fullScreenCover(item: $playing) { VideoPlayerScreen(url: $0.url) }
    }
    private func play() {
        if let url = file.url { playing = VideoRequest(url: url); return }
        loading = true; failed = false
        Task {
            defer { loading = false }
            do {
                let url = try await chat.download(attachment, message: message)
                file.url = url; playing = VideoRequest(url: url)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 640, height: 640)
                if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image { file.poster = UIImage(cgImage: frame) }
            } catch { if !(error is CancellationError) { failed = true } }
        }
    }
}
private struct VideoPlayerScreen: UIViewControllerRepresentable {
    let url: URL
    /// The playout requirement held while the video is on screen (released on dismiss).
    final class Coordinator { var audio: SessionRequirementHandle? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // LiveKit owns the audio session: outside a voice room this makes it a playback session (speaker, sound
        // with the silent switch on); inside one the call session stays as it is.
        context.coordinator.audio = try? AudioManager.shared.acquireSessionRequirement(.playbackOnly)
        let controller = AVPlayerViewController(); controller.player = AVPlayer(url: url); controller.player?.play(); return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        try? coordinator.audio?.release(); coordinator.audio = nil
    }
}
