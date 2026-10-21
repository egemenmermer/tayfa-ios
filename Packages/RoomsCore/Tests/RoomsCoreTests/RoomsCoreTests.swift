import XCTest
@testable import RoomsCore

final class RoomsCoreTests: XCTestCase {
    func testHTTPSOriginRejectsCredentialsDevelopmentAndQuery() throws {
        for value in ["http://127.0.0.1", "https://u:p@rooms.test", "https://rooms.test?token=x", "https://rooms.test/unexpected"] { XCTAssertThrowsError(try EndpointPolicy.origin(value)) }
        XCTAssertEqual(try EndpointPolicy.origin("https://rooms.test").host, "rooms.test")
    }
    func testGatewayCannotSendCredentialsToAnotherHost() throws {
        let origin = try EndpointPolicy.origin("https://rooms.test")
        XCTAssertThrowsError(try EndpointPolicy.gateway("wss://other.test/ws", origin: origin))
        XCTAssertThrowsError(try EndpointPolicy.gateway("ws://rooms.test/ws", origin: origin))
        XCTAssertEqual(URLComponents(url: try EndpointPolicy.gateway("wss://rooms.test/ws", origin: origin), resolvingAgainstBaseURL: false)?.queryItems?.count, 2)
    }
    func testMediaRequiresTLSAndNoCredentials() throws {
        XCTAssertThrowsError(try EndpointPolicy.media("ws://rooms.test"))
        XCTAssertThrowsError(try EndpointPolicy.media("wss://rooms.test?token=x"))
        XCTAssertEqual(try EndpointPolicy.media("wss://rooms.test/livekit"), "wss://rooms.test/livekit")
    }
    func testVoiceRoomsUseExistingTextChannelVoiceFlag() throws {
        let packet = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"servers":[{"_id":"s","name":"Friends"}],"channels":[{"_id":"voice","server":"s","name":"General","channel_type":"TextChannel","voice":{}},{"_id":"text","server":"s","name":"Chat","channel_type":"TextChannel"},{"_id":"dm","name":"DM","channel_type":"DirectMessage"}]}"#.utf8))
        XCTAssertEqual(VoiceRoom.fromReady(packet), [VoiceRoom(id: "voice", name: "General", community: "Friends")])
    }
    func testDirectoryDoesNotInventScreenIndicatorForV1() throws {
        let data = Data(#"{"rooms":[{"channelId":"c","participants":[{"id":"u","name":"User","muted":true}]}]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Directory.self, from: data).rooms[0].participants[0].screen)
    }
    func testOperationReplacementInvalidatesLateResults() {
        var epoch = OperationEpoch(); let first = epoch.advance(); let second = epoch.advance()
        XCTAssertFalse(epoch.owns(first)); XCTAssertTrue(epoch.owns(second)); epoch.advance(); XCTAssertFalse(epoch.owns(second))
    }
    func testUnselectedStreamsAreNotSubscribedButVoiceIs() {
        let selection = ScreenSelection()
        XCTAssertTrue(selection.wants(source: "microphone", publicationID: "mic", presenterScreenID: "screen", foreground: true))
        XCTAssertFalse(selection.wants(source: "screen_share", publicationID: "screen", presenterScreenID: "screen", foreground: true))
    }
    func testSwitchingStreamsDoesNotSubscribeOtherScreenAudio() {
        var selection = ScreenSelection(); selection.select("a")
        XCTAssertTrue(selection.wants(source: "screen_share_audio", publicationID: "audio-a", presenterScreenID: "a", foreground: true))
        selection.select("b")
        XCTAssertFalse(selection.wants(source: "screen_share_audio", publicationID: "audio-a", presenterScreenID: "a", foreground: true))
        XCTAssertTrue(selection.wants(source: "microphone", publicationID: "mic", presenterScreenID: "a", foreground: true))
    }
    func testBackgroundStopsScreensWithoutDroppingVoice() {
        var selection = ScreenSelection(); selection.select("a")
        XCTAssertFalse(selection.wants(source: "screen_share", publicationID: "a", presenterScreenID: "a", foreground: false))
        XCTAssertTrue(selection.wants(source: "microphone", publicationID: "mic", presenterScreenID: "a", foreground: false)); XCTAssertEqual(selection.id, "a")
    }
    func testPublisherEndClearsSelectionWithoutChoosingAnother() {
        var selection = ScreenSelection(); selection.select("a"); selection.reconcile(available: ["b"], subscribed: ["b"])
        XCTAssertNil(selection.id); XCTAssertEqual(selection.state, .ended)
    }
    func testWatchCloseAndFailureFreeSelection() {
        var selection = ScreenSelection(); selection.select("a"); selection.select(nil)
        XCTAssertEqual(selection.state, .idle); XCTAssertNil(selection.id)
        selection.select("a"); selection.fail(); XCTAssertEqual(selection.state, .failed); XCTAssertNil(selection.id)
    }
    func testPublicationMustBeAvailableAndSubscribedBeforePlaying() {
        var selection = ScreenSelection(); selection.select("a"); selection.reconcile(available: ["a"], subscribed: [])
        XCTAssertEqual(selection.state, .loading); selection.reconcile(available: ["a"], subscribed: ["a"]); XCTAssertEqual(selection.state, .playing)
    }
    func testOpaqueChannelIDPreventsPathTraversal() {
        for value in ["../secret", "c?token=", "", String(repeating: "a", count: 129)] { XCTAssertThrowsError(try EndpointPolicy.id(value)) }
    }
}
