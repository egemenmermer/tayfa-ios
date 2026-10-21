import Foundation
import CoreGraphics

/// The room whiteboard (desktop `Whiteboard.tsx`): a 1000×620 board that every viewer scales to fit,
/// so coordinates match everywhere. Elements live in the room activity (`whiteboard.put/remove`).
public enum WhiteboardBoard {
    public typealias Point = WhiteboardElement.Point
    public static let width = 1000.0, height = 620.0
    public static let colors = ["#B8CDFF", "#65BC94", "#E7B96F", "#E57B7B", "#F4F6F8"]
    public static let cursorColors = ["#8B83FF", "#53C793", "#F2BB67", "#F17984", "#6CC4F0", "#D58CF0"]
    public static let strokeWidth = 3.0, textWidth = 2.0, fontSize = 20.0, maxPoints = 500
    /// Desktop `hue`: the sum of the id's UTF-16 units picks a cursor colour.
    public static func cursorColor(_ id: String) -> String { cursorColors[id.utf16.reduce(0) { $0 + Int($1) } % cursorColors.count] }

    /// The board inside a view of `size`: uniformly scaled and centred (SVG `xMidYMid meet`).
    public static func fit(_ size: CGSize) -> CGRect {
        let scale = max(0.0001, min(size.width / width, size.height / height))
        let board = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (size.width - board.width) / 2, y: (size.height - board.height) / 2, width: board.width, height: board.height)
    }
    /// View → board, clamped to the board and rounded to 0.1 like desktop `point`.
    public static func boardPoint(_ point: CGPoint, in size: CGSize) -> Point {
        let frame = fit(size), scale = frame.width / width
        let round = { (value: Double) in (value * 10).rounded() / 10 }
        return Point(x: round(min(width, max(0, (point.x - frame.minX) / scale))), y: round(min(height, max(0, (point.y - frame.minY) / scale))))
    }
    public static func viewPoint(_ point: Point, in size: CGSize) -> CGPoint {
        let frame = fit(size), scale = frame.width / width
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }
    /// The box a rectangle or ellipse spans: from its first to its last point.
    public static func shape(_ points: [Point]) -> CGRect? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y))
    }

    /// A finished pen stroke: Ramer–Douglas–Peucker with a growing tolerance until it fits the protocol's 500 points.
    public static func simplify(_ points: [Point], tolerance: Double = 0.8, limit: Int = maxPoints) -> [Point] {
        guard points.count > 2 else { return points }
        var epsilon = tolerance, result = rdp(points, epsilon)
        while result.count > limit { epsilon *= 1.6; result = rdp(points, epsilon) }
        return result
    }
    private static func rdp(_ points: [Point], _ epsilon: Double) -> [Point] {
        var keep = [Bool](repeating: false, count: points.count); keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var farthest = start, distance = -1.0
            for index in (start + 1)..<end {
                let value = segmentDistance(points[index], points[start], points[end])
                if value > distance { distance = value; farthest = index }
            }
            if distance > epsilon { keep[farthest] = true; stack.append((start, farthest)); stack.append((farthest, end)) }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
    static func segmentDistance(_ point: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The topmost element under a touch, with a finger-sized tolerance (board units).
    public static func hit(_ elements: [WhiteboardElement], at point: Point, tolerance: Double = 12) -> WhiteboardElement? {
        elements.last { element in
            let reach = tolerance + element.width / 2
            switch element.kind {
            case "text":
                guard let anchor = element.points.first else { return false }
                let box = CGRect(x: anchor.x, y: anchor.y - fontSize, width: Double((element.text ?? "").count) * fontSize * 0.56, height: fontSize + 4)
                return box.insetBy(dx: -tolerance, dy: -tolerance).contains(CGPoint(x: point.x, y: point.y))
            case "rectangle":
                guard let box = shape(element.points) else { return false }
                let corners = [Point(x: box.minX, y: box.minY), Point(x: box.maxX, y: box.minY), Point(x: box.maxX, y: box.maxY), Point(x: box.minX, y: box.maxY)]
                return zip(corners, corners.dropFirst() + [corners[0]]).contains { segmentDistance(point, $0, $1) <= reach }
            case "ellipse":
                guard let box = shape(element.points) else { return false }
                let rx = box.width / 2, ry = box.height / 2, cx = box.midX, cy = box.midY
                guard rx > 1, ry > 1 else { return segmentDistance(point, Point(x: box.minX, y: box.minY), Point(x: box.maxX, y: box.maxY)) <= reach }
                let radial = hypot((point.x - cx) / rx, (point.y - cy) / ry)
                return abs(radial - 1) * min(rx, ry) <= reach
            default:
                guard let first = element.points.first else { return false }
                if element.points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= reach }
                return zip(element.points, element.points.dropFirst()).contains { segmentDistance(point, $0, $1) <= reach }
            }
        }
    }
}

/// Live cursors on LiveKit topic `rooms-cursor-v1` (lossy): `{b: roomId, x, y}`, or `{b}` when the pointer leaves.
public enum WhiteboardCursor {
    public static let topic = "rooms-cursor-v1"
    public enum Update: Equatable, Sendable { case moved(WhiteboardElement.Point), left }
    public static func payload(board: String, at point: WhiteboardElement.Point?) -> Data {
        var value: [String: Any] = ["b": board]
        if let point { value["x"] = Int(point.x.rounded()); value["y"] = Int(point.y.rounded()) }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }
    /// Desktop rules: at most 512 bytes, only this board's updates, coordinates clamped to the board.
    public static func parse(_ data: Data, board: String) -> Update? {
        guard data.count <= 512, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["b"] as? String == board else { return nil }
        guard let x = (value["x"] as? NSNumber)?.doubleValue, let y = (value["y"] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite else { return .left }
        return .moved(.init(x: min(WhiteboardBoard.width, max(0, x)), y: min(WhiteboardBoard.height, max(0, y))))
    }
}

/// This session's own edits for undo, newest last and at most 50 (desktop `history`).
public struct WhiteboardHistory: Sendable {
    public enum Edit: Equatable, Sendable { case add(WhiteboardElement), remove(WhiteboardElement) }
    public struct Changed: Error, LocalizedError, Equatable {
        public var errorDescription: String? { "Bu öğe başka bir oturumda değiştirildi. Güncel öğeyi silmek için silgi aracını kullan." }
    }
    public private(set) var edits: [Edit] = []
    public init() {}
    public var canUndo: Bool { !edits.isEmpty }
    public mutating func record(_ edit: Edit) { edits = Array((edits + [edit]).suffix(50)) }
    /// The command that undoes the newest edit: removing an added element (only if nobody changed it),
    /// or putting a removed one back under a fresh id so a concurrent restore is never overwritten.
    public func undo(board: [WhiteboardElement], freshID: String) throws -> ActivityCommand? {
        guard let last = edits.last else { return nil }
        switch last {
        case .add(let element):
            guard let current = board.first(where: { $0.id == element.id }) else { return nil }
            guard current.kind == element.kind, current.color == element.color, current.width == element.width, current.text == element.text,
                  current.points == element.points, current.authorId == element.authorId else { throw Changed() }
            return .whiteboardRemove(elementID: current.id)
        case .remove(let element):
            return .whiteboardPut(WhiteboardElement(id: freshID, kind: element.kind, points: element.points, text: element.text, color: element.color, width: element.width, authorId: element.authorId))
        }
    }
    /// After an undo was sent: drop it, and point older entries at a restored element's new id.
    public mutating func undone(restoredAs freshID: String?) {
        guard let last = edits.popLast() else { return }
        guard let freshID, case .remove(let removed) = last else { return }
        let restored = WhiteboardElement(id: freshID, kind: removed.kind, points: removed.points, text: removed.text, color: removed.color, width: removed.width, authorId: removed.authorId)
        edits = edits.map { edit in
            switch edit {
            case .add(let element) where element.id == removed.id: .add(restored)
            case .remove(let element) where element.id == removed.id: .remove(restored)
            default: edit
            }
        }
    }
}
