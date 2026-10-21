import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import RoomsCore

final class PhotoNormalizerTests: XCTestCase {
    private func makePhoto(type: UTType, width: Int, height: Int, orientation: Int = 1) throws -> LocalAttachment {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let directory = try FileStager.directory(), url = directory.appendingPathComponent("IMG_0001.\(type.preferredFilenameExtension ?? "img")")
        let writer = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLongitude: 29.0]
        CGImageDestinationAddImage(writer, context.makeImage()!, [kCGImagePropertyOrientation: orientation, kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        return LocalAttachment(id: directory.lastPathComponent, url: url, name: url.lastPathComponent, mime: type.preferredMIMEType!, size: size)
    }
    private func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }
    func testHEICBecomesUprightJPEGWithoutLocation() throws {
        let photo = try makePhoto(type: .heic, width: 4000, height: 3000, orientation: 6)
        let sent = try PhotoNormalizer.prepare(photo)
        defer { FileStager.remove(sent.url) }
        XCTAssertEqual(sent.mime, "image/jpeg"); XCTAssertEqual(sent.name, "IMG_0001.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.url.path))
        let info = properties(sent.url)
        XCTAssertNil(info[kCGImagePropertyGPSDictionary])
        // Orientation 6 (rotated) is applied to the pixels: the result is portrait and long side ≤ 3072.
        XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 2304)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 3072)
        XCTAssertEqual((info[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }
    func testFilesKeepJPEGBytesButConvertHEIC() throws {
        let jpeg = try makePhoto(type: .jpeg, width: 30, height: 20)
        defer { FileStager.remove(jpeg.url) }
        XCTAssertEqual(try PhotoNormalizer.prepareFile(jpeg), jpeg)
        let heic = try makePhoto(type: .heic, width: 30, height: 20)
        let sent = try PhotoNormalizer.prepareFile(heic)
        defer { FileStager.remove(sent.url) }
        XCTAssertEqual(sent.mime, "image/jpeg")
    }
    func testPNGIsSentUnchanged() throws {
        let photo = try makePhoto(type: .png, width: 20, height: 10)
        defer { FileStager.remove(photo.url) }
        XCTAssertEqual(try PhotoNormalizer.prepare(photo), photo)
    }
}
