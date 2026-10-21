import XCTest
@testable import RoomsCore

final class MentionDraftTests: XCTestCase {
    private let people = [
        MentionCandidate(id: "01USERSEMS000000000000AAAA", name: "sems"),
        MentionCandidate(id: "01USERONUR000000000000BBBB", name: "Onur"),
        MentionCandidate(id: "01USERONUR000000000000CCCC", name: "Onur"),
        MentionCandidate(id: "01USERCACA000000000000DDDD", name: "cacakinglord"),
    ]

    func testQueryOnlyMatchesTrailingWordStartingWithAt() {
        XCTAssertEqual(MentionDraft.query(in: "@"), "")
        XCTAssertEqual(MentionDraft.query(in: "selam @se"), "se")
        XCTAssertNil(MentionDraft.query(in: "mail@host"))
        XCTAssertNil(MentionDraft.query(in: "@sems geldi"))
        XCTAssertNil(MentionDraft.query(in: "düz metin"))
    }

    func testSuggestionsPreferPrefixAndIgnoreCaseAndDiacritics() {
        XCTAssertEqual(MentionDraft.suggestions("SE", from: people).map(\.name), ["sems"])
        XCTAssertEqual(MentionDraft.suggestions("king", from: people).map(\.name), ["cacakinglord"])
        XCTAssertEqual(MentionDraft.suggestions("ö", from: [MentionCandidate(id: "x", name: "Ömer")]).count, 1)
        XCTAssertEqual(MentionDraft.suggestions("", from: people).count, 4)
    }

    func testDuplicateNamesGetDistinctTokens() {
        let first = MentionDraft.token(for: people[1], among: people)
        let second = MentionDraft.token(for: people[2], among: people)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(MentionDraft.token(for: people[0], among: people), "@sems")
    }

    func testEncodeConvertsOnlyIntactBoundTokens() {
        let bindings = ["@sems": people[0].id, "@Onur#BBBB": people[1].id]
        let result = MentionDraft.encode("@sems ve @Onur#BBBB bakın, @semsx değil", bindings: bindings)
        XCTAssertEqual(result.content, "<@\(people[0].id)> ve <@\(people[1].id)> bakın, @semsx değil")
        XCTAssertEqual(Set(result.mentions), [people[0].id, people[1].id])
    }

    func testEncodeLeavesUnboundTextUntouched() {
        let result = MentionDraft.encode("@sems yazdım ama seçmedim", bindings: [:])
        XCTAssertEqual(result.content, "@sems yazdım ama seçmedim")
        XCTAssertTrue(result.mentions.isEmpty)
    }
}
