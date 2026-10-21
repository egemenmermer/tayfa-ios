import XCTest
@testable import RoomsCore

final class WhiteboardTests: XCTestCase {
    typealias Point = WhiteboardElement.Point
    func testBoardFitsLikeTheDesktopSVGAndRoundTrips() {
        let size = CGSize(width: 500, height: 620) // narrower than 1000×620: letterboxed top and bottom
        let frame = WhiteboardBoard.fit(size)
        XCTAssertEqual(frame.width, 500, accuracy: 0.001); XCTAssertEqual(frame.height, 310, accuracy: 0.001); XCTAssertEqual(frame.minY, 155, accuracy: 0.001)
        XCTAssertEqual(WhiteboardBoard.boardPoint(CGPoint(x: 250, y: 310), in: size), Point(x: 500, y: 310))
        XCTAssertEqual(WhiteboardBoard.boardPoint(CGPoint(x: -20, y: 900), in: size), Point(x: 0, y: 620))
        XCTAssertEqual(WhiteboardBoard.boardPoint(CGPoint(x: 100.04, y: 155), in: size), Point(x: 200.1, y: 0))
        let back = WhiteboardBoard.viewPoint(Point(x: 1000, y: 620), in: size)
        XCTAssertEqual(back.x, 500, accuracy: 0.001); XCTAssertEqual(back.y, 465, accuracy: 0.001)
    }
    func testCursorColoursAndPayloadsMatchDesktop() throws {
        XCTAssertEqual(WhiteboardBoard.cursorColor("a"), WhiteboardBoard.cursorColors[97 % 6])
        let moved = WhiteboardCursor.payload(board: "room", at: Point(x: 12.4, y: 99.6))
        XCTAssertEqual(String(data: moved, encoding: .utf8), #"{"b":"room","x":12,"y":100}"#)
        XCTAssertEqual(WhiteboardCursor.parse(moved, board: "room"), .moved(Point(x: 12, y: 100)))
        XCTAssertEqual(WhiteboardCursor.parse(WhiteboardCursor.payload(board: "room", at: nil), board: "room"), .left)
        XCTAssertNil(WhiteboardCursor.parse(moved, board: "other"))
        XCTAssertEqual(WhiteboardCursor.parse(Data(#"{"b":"room","x":5000,"y":-3}"#.utf8), board: "room"), .moved(Point(x: 1000, y: 0)))
        XCTAssertNil(WhiteboardCursor.parse(Data("not json".utf8), board: "room"))
        XCTAssertNil(WhiteboardCursor.parse(Data(repeating: 32, count: 600), board: "room"))
    }
    func testStrokesAreSimplifiedUnderTheProtocolLimit() {
        let line = (0..<50).map { Point(x: Double($0), y: Double($0) * 2) }
        XCTAssertEqual(WhiteboardBoard.simplify(line), [line.first!, line.last!])
        let wave = (0..<2000).map { Point(x: Double($0) / 2, y: 300 + 200 * sin(Double($0) / 7)) }
        let simplified = WhiteboardBoard.simplify(wave)
        XCTAssertLessThanOrEqual(simplified.count, 500); XCTAssertEqual(simplified.first, wave.first); XCTAssertEqual(simplified.last, wave.last)
        XCTAssertGreaterThan(simplified.count, 50)
    }
    func testHitTestingFindsTheTopmostElementNearAFinger() {
        let stroke = WhiteboardElement(id: "s", kind: "stroke", points: [Point(x: 0, y: 0), Point(x: 100, y: 0)], color: "#ffffff", width: 3, authorId: "me")
        let box = WhiteboardElement(id: "r", kind: "rectangle", points: [Point(x: 200, y: 200), Point(x: 300, y: 260)], color: "#ffffff", width: 3, authorId: "me")
        let ring = WhiteboardElement(id: "e", kind: "ellipse", points: [Point(x: 500, y: 100), Point(x: 700, y: 300)], color: "#ffffff", width: 3, authorId: "me")
        let note = WhiteboardElement(id: "t", kind: "text", points: [Point(x: 50, y: 400)], text: "Merhaba", color: "#ffffff", width: 2, authorId: "me")
        let over = WhiteboardElement(id: "s2", kind: "stroke", points: [Point(x: 0, y: 5), Point(x: 100, y: 5)], color: "#ffffff", width: 3, authorId: "you")
        let board = [stroke, box, ring, note, over]
        XCTAssertEqual(WhiteboardBoard.hit(board, at: Point(x: 50, y: 2))?.id, "s2")
        XCTAssertEqual(WhiteboardBoard.hit(board, at: Point(x: 250, y: 205))?.id, "r")
        XCTAssertNil(WhiteboardBoard.hit(board, at: Point(x: 250, y: 230)))
        XCTAssertEqual(WhiteboardBoard.hit(board, at: Point(x: 600, y: 103))?.id, "e")
        XCTAssertNil(WhiteboardBoard.hit(board, at: Point(x: 600, y: 200)))
        XCTAssertEqual(WhiteboardBoard.hit(board, at: Point(x: 80, y: 390))?.id, "t")
    }
    func testUndoRemovesOwnAddsAndRestoresRemovalsUnderAFreshID() throws {
        let element = WhiteboardElement(id: "a", kind: "stroke", points: [Point(x: 1, y: 1), Point(x: 2, y: 2)], color: "#B8CDFF", width: 3, authorId: "me")
        var history = WhiteboardHistory()
        XCTAssertNil(try history.undo(board: [], freshID: "x"))
        history.record(.add(element))
        XCTAssertEqual(try history.undo(board: [element], freshID: "x"), .whiteboardRemove(elementID: "a"))
        XCTAssertNil(try history.undo(board: [], freshID: "x"))
        let moved = WhiteboardElement(id: "a", kind: "stroke", points: [Point(x: 9, y: 9)], color: "#B8CDFF", width: 3, authorId: "me")
        XCTAssertThrowsError(try history.undo(board: [moved], freshID: "x"))
        history.record(.remove(element))
        guard case .whiteboardPut(let restored)? = try history.undo(board: [], freshID: "new") else { return XCTFail("expected a put") }
        XCTAssertEqual(restored.id, "new"); XCTAssertEqual(restored.points, element.points)
        history.undone(restoredAs: "new")
        XCTAssertEqual(history.edits, [.add(WhiteboardElement(id: "new", kind: "stroke", points: element.points, color: "#B8CDFF", width: 3, authorId: "me"))])
        for index in 0..<60 { history.record(.add(WhiteboardElement(id: "e\(index)", kind: "stroke", points: [], color: "#B8CDFF", width: 3))) }
        XCTAssertEqual(history.edits.count, 50)
    }
}
