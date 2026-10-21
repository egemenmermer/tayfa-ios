import CoreGraphics
import XCTest
@testable import RoomsCore

final class CommunityCatalogTests: XCTestCase {
    private func packet() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(#"{"servers":[{"_id":"s","name":"Friends","icon":{"_id":"image"},"channels":["b","private","a","b"],"categories":[{"id":"cat","title":"Together","channels":["private","a","a"]}]},{"_id":"t","name":"Other"}]}"#.utf8))
    }
    func testCommunityOrderCategoriesAndPermissionFilteredChannels() throws {
        let catalog = RoomCommunity.fromReady(try packet()); XCTAssertEqual(catalog.map(\.id), ["s", "t"])
        let first = try XCTUnwrap(catalog.first); XCTAssertEqual(first.iconID, "image")
        XCTAssertEqual(first.ordered(["a", "b", "c"]), ["b", "a", "c"])
        let sections = first.sections(available: ["a", "b", "c"])
        XCTAssertEqual(sections.map(\.name), ["Kanallar", "Together"])
        XCTAssertEqual(sections.map(\.channels), [["b", "c"], ["a"]])
        XCTAssertFalse(sections.flatMap(\.channels).contains("private"))
    }
    func testRemovedCommunityAndChannelCannotRemainSelected() throws {
        var selection = CommunitySelection(); selection.communityID = "gone"; selection.channelID = "private"
        selection.reconcile(communities: RoomCommunity.fromReady(try packet()), permittedChannels: ["a"])
        XCTAssertEqual(selection.communityID, "s"); XCTAssertNil(selection.channelID)
        selection.reconcile(communities: [], permittedChannels: []); XCTAssertNil(selection.communityID)
    }
    @MainActor func testNavigationPersistenceIsolatedByAccountAndOrigin() throws {
        let suite = "rooms-navigation-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = CommunitySelectionStore(defaults: defaults), origin = URL(string: "https://rooms.test")!
        var selection = CommunitySelection(); selection.communityID = "s"; selection.channelID = "a"
        store.save(selection, origin: origin, owner: "u")
        XCTAssertEqual(store.load(origin: origin, owner: "u"), selection)
        XCTAssertNil(store.load(origin: origin, owner: "other").communityID)
        XCTAssertNil(store.load(origin: URL(string: "https://other.test")!, owner: "u").communityID)
    }
    func testScrollMemoryIsBoundedAndPrivateChannelsPurged() {
        var memory = ConversationScrollMemory()
        for i in 0..<20 { memory.remember(channelID: "c\(i)", anchor: "m\(i)") }
        XCTAssertNil(memory.anchor(for: "c0")); XCTAssertEqual(memory.anchor(for: "c19"), "m19")
        memory.reconcile(permitted: ["c18"]); XCTAssertNil(memory.anchor(for: "c19")); XCTAssertEqual(memory.anchor(for: "c18"), "m18")
    }
    func testMiniPlayerOcclusionCannotMarkMessageRead() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 500), row = CGRect(x: 16, y: 150, width: 358, height: 70)
        XCTAssertTrue(ReadVisibilityPolicy.readable(row: row, viewport: viewport, occlusions: []))
        XCTAssertFalse(ReadVisibilityPolicy.readable(row: row, viewport: viewport, occlusions: [CGRect(x: 200, y: 130, width: 180, height: 140)]))
        XCTAssertFalse(ReadVisibilityPolicy.readable(row: CGRect(x: 0, y: 580, width: 390, height: 70), viewport: viewport, occlusions: []))
        XCTAssertTrue(ReadVisibilityPolicy.readable(row: row, viewport: viewport, occlusions: [.zero]))
    }
}
