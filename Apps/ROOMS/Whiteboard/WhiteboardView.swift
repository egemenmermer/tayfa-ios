import SwiftUI
import RoomsCore

/// One room's whiteboard: tools, own-element removal, session undo and live cursors (desktop `Whiteboard.tsx`).
@MainActor final class WhiteboardModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, rectangle, ellipse, text, erase, select
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pen: "Kalem"
            case .rectangle: "Dikdörtgen"
            case .ellipse: "Daire"
            case .text: "Metin: tahtaya dokun ve yaz"
            case .erase: "Silgi: kendi öğene dokun"
            case .select: "Seç"
            }
        }
        var icon: String {
            switch self {
            case .pen: "pencil.tip"
            case .rectangle: "square"
            case .ellipse: "circle"
            case .text: "textformat"
            case .erase: "eraser"
            case .select: "cursorarrow"
            }
        }
    }
    typealias Point = WhiteboardElement.Point
    struct Cursor { let point: Point; let at: Date }
    @Published var tool = Tool.pen { didSet { if tool != .select { selected = nil }; if tool != .text { textAnchor = nil } } }
    @Published var color = WhiteboardBoard.colors[0]
    @Published private(set) var draft: [Point] = []
    @Published var textAnchor: Point?
    @Published var selected: String?
    @Published private(set) var cursors: [String: Cursor] = [:]
    @Published var message: String?
    @Published private(set) var working = false
    @Published private(set) var history = WhiteboardHistory()
    let watch: WatchTogetherModel
    let media: RoomMedia
    private var lastShared = Date.distantPast
    private var budget = (second: 0, count: 0)

    init(watch: WatchTogetherModel, media: RoomMedia) { self.watch = watch; self.media = media }
    var board: [WhiteboardElement] { watch.room?.whiteboard ?? [] }
    var readOnly: Bool { watch.room == nil }
    var busy: Bool { working || watch.busy || readOnly }
    /// Cursors travel over the voice room's LiveKit connection.
    var live: Bool { media.connected }

    func attach() { media.handleData(topic: WhiteboardCursor.topic) { [weak self] packet in self?.receive(packet) } }
    func detach() { share(nil, force: true); media.handleData(topic: WhiteboardCursor.topic, nil); cursors = [:] }
    private func receive(_ packet: RoomDataPacket) {
        guard !packet.fromServer, let sender = packet.sender, sender != watch.me else { return }
        // Desktop budget: cursors are frequent and disposable, at most 600 a second.
        let second = Int(Date().timeIntervalSince1970)
        if budget.second != second { budget = (second, 0) }
        budget.count += 1
        guard budget.count <= 600 else { return }
        switch WhiteboardCursor.parse(packet.payload, board: watch.roomID) {
        case .moved(let point)?: cursors[sender] = Cursor(point: point, at: Date())
        case .left?: cursors[sender] = nil
        case nil: break
        }
    }
    func sweep() {
        let now = Date(), fresh = cursors.filter { now.timeIntervalSince($0.value.at) < 5 }
        if fresh.count != cursors.count { cursors = fresh }
    }
    /// At most 20 updates a second; lifting the finger tells the others the pointer left.
    func share(_ point: Point?, force: Bool = false) {
        guard live else { return }
        let now = Date()
        if point != nil, !force, now.timeIntervalSince(lastShared) < 0.05 { return }
        lastShared = now
        let payload = WhiteboardCursor.payload(board: watch.roomID, at: point), media = media
        Task { try? await media.publishData(payload, topic: WhiteboardCursor.topic, reliable: false) }
    }

    func dragged(to point: Point, from start: Point) {
        share(point)
        guard !busy, [.pen, .rectangle, .ellipse].contains(tool) else { return }
        if draft.isEmpty { draft = [start] }
        if tool == .pen {
            // Skip sub-pixel jitter; the finished stroke is simplified to the protocol's 500 points.
            if let last = draft.last, hypot(point.x - last.x, point.y - last.y) >= 1.5, draft.count < 4000 { draft.append(point) }
        } else { draft = [draft[0], point] }
    }
    func lifted(at point: Point, tap: Bool) {
        share(nil, force: true)
        let raw = draft; draft = []
        switch tool {
        case .pen:
            guard !busy else { return }
            add(kind: "stroke", points: WhiteboardBoard.simplify((raw.isEmpty ? [point] : raw) + [point]))
        case .rectangle, .ellipse:
            guard !busy, let first = raw.first, hypot(point.x - first.x, point.y - first.y) >= 2 else { return }
            add(kind: tool.rawValue, points: [first, point])
        case .text:
            guard tap, !busy else { return }
            textAnchor = Point(x: point.x, y: max(22, point.y))
        case .erase:
            guard tap, let element = WhiteboardBoard.hit(board, at: point) else { return }
            remove(element)
        case .select:
            guard tap else { return }
            selected = WhiteboardBoard.hit(board, at: point)?.id
        }
    }
    func commitText(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let anchor = textAnchor else { return }
        textAnchor = nil
        guard !text.isEmpty else { return }
        add(kind: "text", points: [anchor], text: String(text.prefix(2000)), width: WhiteboardBoard.textWidth)
    }
    private func add(kind: String, points: [Point], text: String? = nil, width: Double = WhiteboardBoard.strokeWidth) {
        let element = WhiteboardElement(id: UUID().uuidString.lowercased(), kind: kind, points: Array(points.prefix(WhiteboardBoard.maxPoints)), text: text, color: color, width: width, authorId: watch.me)
        run { try await self.watch.send(.whiteboardPut(element)); self.history.record(.add(element)) }
    }
    func remove(_ element: WhiteboardElement) {
        guard element.authorId == watch.me else { message = "Yalnızca kendi çizimini veya notunu silebilirsin."; return }
        run {
            try await self.watch.send(.whiteboardRemove(elementID: element.id))
            self.history.record(.remove(element))
            if self.selected == element.id { self.selected = nil }
        }
    }
    func undo() {
        run {
            let fresh = UUID().uuidString.lowercased()
            let command = try self.history.undo(board: self.board, freshID: fresh)
            if let command { try await self.watch.send(command) }
            if case .whiteboardPut? = command { self.history.undone(restoredAs: fresh) } else { self.history.undone(restoredAs: nil) }
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        working = true; message = nil
        Task { defer { working = false }; do { try await work() } catch { message = error.localizedDescription } }
    }
}

struct WhiteboardView: View {
    @StateObject private var board: WhiteboardModel
    @ObservedObject var watch: WatchTogetherModel
    @ObservedObject var media: RoomMedia
    let roomName: String
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var typing: Bool
    private let sweep = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(watch: WatchTogetherModel, media: RoomMedia, roomName: String) {
        _board = StateObject(wrappedValue: WhiteboardModel(watch: watch, media: media))
        self.watch = watch; self.media = media; self.roomName = roomName
    }
    private var elements: [WhiteboardElement] { watch.room?.whiteboard ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            GeometryReader { geometry in stage(geometry.size) }.padding(.horizontal, 10).padding(.vertical, 6)
            if board.textAnchor != nil { noteBar }
            footer
        }
        .background(Palette.rail.ignoresSafeArea())
        .task { watch.start(); board.attach() }
        .onDisappear { board.detach() }
        .onReceive(sweep) { _ in board.sweep() }
        .onChange(of: board.textAnchor) { _, anchor in if anchor != nil { note = ""; typing = true } }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Beyaz tahtayı küçült")
            VStack(alignment: .leading, spacing: 2) {
                Text("Beyaz tahta").font(.headline)
                Text(roomName + (board.cursors.isEmpty ? "" : " · \(board.cursors.count + 1) kişi burada")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            RoomIconControl(label: board.history.canUndo ? "Bu oturumdaki son kendi işlemini geri al" : "Bu oturumda geri alınacak kendi işlemin yok", icon: "arrow.uturn.backward") { board.undo() }
                .disabled(board.busy || !board.history.canUndo)
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WhiteboardModel.Tool.allCases) { tool in
                    Button { board.tool = tool } label: { Image(systemName: tool.icon).font(.system(size: 17, weight: .semibold)).frame(width: 42, height: 42) }
                        .buttonStyle(RoomControlStyle(selected: board.tool == tool)).accessibilityLabel(tool.label).accessibilityAddTraits(board.tool == tool ? .isSelected : [])
                }
                Divider().frame(height: 28).padding(.horizontal, 4)
                ForEach(WhiteboardBoard.colors, id: \.self) { color in
                    Button { board.color = color } label: {
                        Circle().fill(Color(boardHex: color)).frame(width: 26, height: 26)
                            .overlay { if board.color == color { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.black) } }
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Çizim rengi \(color)").accessibilityAddTraits(board.color == color ? .isSelected : [])
                }
            }.padding(.horizontal, 10)
        }.disabled(board.busy)
    }
    private func stage(_ size: CGSize) -> some View {
        let frame = WhiteboardBoard.fit(size), scale = frame.width / WhiteboardBoard.width
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.fill(Path(roundedRect: frame, cornerRadius: 10 * scale), with: .color(Palette.surface))
                var dots = Path()
                for x in stride(from: 1.0, to: WhiteboardBoard.width, by: 24) {
                    for y in stride(from: 1.0, to: WhiteboardBoard.height, by: 24) {
                        dots.addEllipse(in: CGRect(x: frame.minX + x * scale - scale, y: frame.minY + y * scale - scale, width: 2 * scale, height: 2 * scale))
                    }
                }
                context.fill(dots, with: .color(.white.opacity(0.08)))
                for element in elements {
                    if element.id == board.selected { draw(element, in: &context, size: size, scale: scale, highlight: true) }
                    draw(element, in: &context, size: size, scale: scale)
                }
                if !board.draft.isEmpty {
                    let kind = board.tool == .pen ? "stroke" : board.tool.rawValue
                    draw(WhiteboardElement(id: "draft", kind: kind, points: board.draft, color: board.color, width: WhiteboardBoard.strokeWidth), in: &context, size: size, scale: scale)
                }
                if let anchor = board.textAnchor {
                    let at = WhiteboardBoard.viewPoint(anchor, in: size)
                    context.fill(Path(CGRect(x: at.x, y: at.y - 20 * scale, width: 2, height: 22 * scale)), with: .color(Color(boardHex: board.color)))
                }
                for (id, cursor) in board.cursors { drawCursor(id: id, at: cursor.point, in: &context, size: size, scale: scale) }
            }
            if elements.isEmpty && board.draft.isEmpty && board.textAnchor == nil {
                VStack(spacing: 6) {
                    Image(systemName: "pencil.tip").font(.title2)
                    Text("İlk çizgi senden.").font(.subheadline.bold())
                    Text("Kalemle çiz, şekil ekle ya da metin aracıyla tahtaya dokunup yaz.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            board.dragged(to: WhiteboardBoard.boardPoint(value.location, in: size), from: WhiteboardBoard.boardPoint(value.startLocation, in: size))
        }.onEnded { value in
            board.lifted(at: WhiteboardBoard.boardPoint(value.location, in: size), tap: hypot(value.translation.width, value.translation.height) < 8)
        })
        .accessibilityElement(children: .ignore).accessibilityLabel("Ortak çizim tahtası").accessibilityValue("\(elements.count) öğe")
        .accessibilityAction(named: "Son kendi işlemini geri al") { board.undo() }
    }
    private func draw(_ element: WhiteboardElement, in context: inout GraphicsContext, size: CGSize, scale: CGFloat, highlight: Bool = false) {
        let color = highlight ? Palette.accent.opacity(0.45) : Color(boardHex: element.color)
        let width = (element.width + (highlight ? 8 : 0)) * scale
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        let points = element.points.map { WhiteboardBoard.viewPoint($0, in: size) }
        switch element.kind {
        case "text":
            guard let anchor = points.first else { return }
            let text = Text(element.text ?? "").font(.system(size: WhiteboardBoard.fontSize * scale)).foregroundStyle(highlight ? Palette.accent : Color(boardHex: element.color))
            // SVG text sits on its baseline; the bottom of the line is a little below it.
            context.draw(text, at: CGPoint(x: anchor.x, y: anchor.y + 4.5 * scale), anchor: .bottomLeading)
        case "rectangle", "ellipse":
            guard let box = WhiteboardBoard.shape(element.points) else { return }
            let rect = CGRect(x: WhiteboardBoard.viewPoint(.init(x: box.minX, y: box.minY), in: size).x, y: WhiteboardBoard.viewPoint(.init(x: box.minX, y: box.minY), in: size).y, width: box.width * scale, height: box.height * scale)
            context.stroke(element.kind == "rectangle" ? Path(roundedRect: rect, cornerRadius: 8 * scale) : Path(ellipseIn: rect), with: .color(color), style: style)
        default:
            guard let first = points.first else { return }
            if points.count == 1 || points.allSatisfy({ $0 == first }) {
                context.fill(Path(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)), with: .color(color)); return
            }
            var path = Path(); path.addLines(points)
            context.stroke(path, with: .color(color), style: style)
        }
    }
    private func drawCursor(id: String, at point: WhiteboardElement.Point, in context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        let at = WhiteboardBoard.viewPoint(point, in: size), unit = max(scale, 0.6)
        let arrow: [(Double, Double)] = [(0, 0), (0, 17), (4.6, 12.6), (8, 20), (11, 18.6), (7.7, 11.4), (13.5, 11.4)]
        var path = Path(); path.addLines(arrow.map { CGPoint(x: at.x + $0.0 * unit, y: at.y + $0.1 * unit) }); path.closeSubpath()
        let color = Color(boardHex: WhiteboardBoard.cursorColor(id))
        context.fill(path, with: .color(color))
        let name = media.people.first { $0.id == id }?.name ?? "Katılımcı"
        context.draw(Text(name).font(.system(size: max(10, 12 * unit), weight: .semibold)).foregroundStyle(color), at: CGPoint(x: at.x + 15 * unit, y: at.y + 26 * unit), anchor: .bottomLeading)
    }
    private var noteBar: some View {
        HStack(spacing: 8) {
            TextField("Yaz, sonra Ekle'ye dokun", text: $note).focused($typing).submitLabel(.done).onAppear { typing = true }
                .onSubmit { board.commitText(note); note = "" }
                .onChange(of: note) { _, value in if value.count > 2000 { note = String(value.prefix(2000)) } }
                .padding(10).background(Palette.raised, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Color(boardHex: board.color))
            Button("Ekle") { board.commitText(note); note = "" }.frame(minHeight: 44).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || board.busy)
            Button { board.textAnchor = nil; note = "" } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Notu bırak")
        }.padding(.horizontal, 12).padding(.vertical, 4)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let id = board.selected, let element = elements.first(where: { $0.id == id }) {
                HStack {
                    Button("Seçili öğeyi sil", systemImage: "trash", role: .destructive) { board.remove(element) }
                        .disabled(board.busy || element.authorId != watch.me).frame(minHeight: 44)
                    if element.authorId != watch.me { Text("Yalnızca kendi öğeni silebilirsin").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Seçimi kaldır") { board.selected = nil }.font(.footnote).frame(minHeight: 44)
                }
            }
            if let message = board.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var status: String {
        if board.working || watch.busy { return "Gönderiliyor…" }
        if board.readOnly { return watch.failure.map { "Bağlantı bekleniyor; düzenleme kapalı. \($0)" } ?? "Bağlantı bekleniyor; düzenleme kapalı" }
        return "\(elements.count) öğe · " + (board.live ? "imleçler canlı" : "imleçler sesli odadayken görünür")
    }
}

extension Color {
    /// `#rrggbb` from the shared board; anything else is drawn white.
    init(boardHex value: String) {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { self = .white; return }
        self = Color(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
    }
}
