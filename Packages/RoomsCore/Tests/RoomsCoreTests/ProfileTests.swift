import XCTest
@testable import RoomsCore

final class ProfileTests: XCTestCase {
    func testPatchBodySetsFieldsAndRemovesEmptyOnes() throws {
        var profile = OwnProfile(displayName: "  Osman ", bio: "Merhaba", statusText: "", presence: .busy, username: "ob")
        let body = try profile.patchBody()
        XCTAssertEqual(body["display_name"], .string("Osman"))
        XCTAssertEqual(body["profile"]["content"], .string("Merhaba"))
        XCTAssertEqual(body["status"]["presence"], .string("Busy"))
        XCTAssertEqual(body["status"]["text"], .null)
        XCTAssertEqual(body["remove"], .array([.string("StatusText")]))
        profile.bio = ""; profile.statusText = "Film izliyorum"
        let next = try profile.patchBody()
        XCTAssertEqual(next["status"]["text"], .string("Film izliyorum"))
        XCTAssertEqual(next["remove"], .array([.string("ProfileContent")]))
    }
    func testInvalidFieldsExplainWhyAndNeverReachTheServer() {
        var profile = OwnProfile(displayName: "O", username: "ob")
        XCTAssertNotNil(profile.problem); XCTAssertThrowsError(try profile.patchBody())
        profile.displayName = "Osman"; XCTAssertNil(profile.problem)
        profile.statusText = String(repeating: "a", count: 129); XCTAssertNotNil(profile.problem)
    }
    func testAvatarUploadAcceptsOnlySmallImages() throws {
        XCTAssertThrowsError(try AvatarPolicy.multipart(Data(), mime: "image/png", boundary: "b"))
        XCTAssertThrowsError(try AvatarPolicy.multipart(Data([1]), mime: "image/gif", boundary: "b"))
        XCTAssertThrowsError(try AvatarPolicy.multipart(Data(count: AvatarPolicy.maxBytes + 1), mime: "image/jpeg", boundary: "b"))
        let body = try AvatarPolicy.multipart(Data([1, 2, 3]), mime: "image/jpeg", boundary: "b")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("filename=\"avatar.jpg\""))
    }
}
