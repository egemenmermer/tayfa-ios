import Foundation
import ImageIO
import UniformTypeIdentifiers

/// iPhone photos are usually HEIC, which the desktop chat cannot show inline (it shows PNG, JPEG,
/// WebP and GIF). Photos are re-encoded as an upright JPEG without metadata such as location.
public enum PhotoNormalizer {
    /// Formats sent unchanged: shown inline everywhere, and GIF keeps its animation.
    public static let passThrough: Set<String> = ["image/png", "image/gif", "image/webp"]
    public static let maxPixels = 3072

    public static func prepare(_ file: LocalAttachment) throws -> LocalAttachment {
        guard !passThrough.contains(file.mime) else { return file }
        let converted = try jpeg(from: file.url, name: file.name)
        FileStager.remove(file.url)
        return converted
    }

    /// A file chosen from Files keeps its original bytes unless desktop cannot show it (HEIC/HEIF).
    public static func prepareFile(_ file: LocalAttachment) throws -> LocalAttachment {
        ["image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence"].contains(file.mime) ? try prepare(file) : file
    }

    public static func jpeg(from source: URL, name: String) throws -> LocalAttachment {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(input) > 0 else { throw RoomsError.invalidMessage }
        // The thumbnail path applies the EXIF orientation and bounds memory for very large photos.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { throw RoomsError.invalidMessage }
        let directory = try FileStager.directory()
        let base = (name as NSString).deletingPathExtension
        let output = directory.appendingPathComponent(FilePolicy.safeName((base.isEmpty ? "Fotoğraf" : base) + ".jpg"))
        do {
            guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw RoomsError.invalidMessage }
            CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw RoomsError.invalidMessage }
            let size = (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= FilePolicy.maxBytes else { throw RoomsError.fileTooLarge }
            return LocalAttachment(id: directory.lastPathComponent, url: output, name: output.lastPathComponent, mime: "image/jpeg", size: size)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
