import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO
import QuickLook
import RoomsCore

func thumbnail(_ url: URL, pixels: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

struct ChatAvatarView: View {
    @ObservedObject var chat: ChatController
    let userID: String
    let name: String
    var size: CGFloat = 32
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Circle().fill(Palette.accent.opacity(0.2)).overlay(Text(String(name.prefix(1))).font(.caption.bold())) }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
            .task(id: "\(chat.sessionGeneration)-\(userID)-\(chat.profileRevisions[userID, default: 0])") {
                image = nil
                do { if let url = try await chat.loadAvatar(userID), !Task.isCancelled { image = thumbnail(url, pixels: Int(size * 3)) } } catch { image = nil }
            }
    }
}

struct MessageCardView: View {
    @ObservedObject var chat: ChatController
    let message: ChatMessage
    let currentUserID: String
    var grouped = false
    let openProfile: (String) -> Void
    let openFile: (ChatAttachment, ChatMessage) -> Void
    let openReply: (String, String) -> Void
    let edit: (ChatMessage) -> Void
    let delete: (ChatMessage) -> Void
    /// Opens the full reaction picker; nil hides "Diğer tepkiler".
    var react: ((ChatMessage) -> Void)? = nil
    private var busy: Bool { chat.actionBusy.contains(message.id) }
    @ObservedObject private var safety = SafetyCenter.shared
    @State private var revealed = false
    @State private var confirmBlock = false
    @State private var reporting = false
    @State private var notice: SafetyNotice?
    private var hidden: Bool { message.authorID != currentUserID && safety.isBlocked(message.authorID) && !revealed }
    var body: some View {
        Group {
            if hidden {
                if grouped { Color.clear.frame(height: 0).accessibilityHidden(true) }
                else {
                    HStack(spacing: 8) {
                        Image(systemName: "person.slash").accessibilityHidden(true)
                        Text("Engellediğin kullanıcının mesajı gizlendi")
                        Spacer(minLength: 0)
                        Button("Göster") { revealed = true }.buttonStyle(.bordered).controlSize(.small)
                    }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44).accessibilityIdentifier("chat.message.\(message.id)")
                }
            } else { card }
        }
        .task(id: "\(currentUserID)-\(message.channelID)-\(chat.authorityGeneration)") {
            safety.attach(SafetyClient.make); safety.use(userID: currentUserID)
            await safety.ensureLoaded()
            await safety.refreshModeration(channelID: message.channelID, generation: chat.authorityGeneration)
        }
        .confirmationDialog("\(message.authorName) engellensin mi?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Engelle", role: .destructive) { Task { notice = await SafetyActions.block(message.authorID, name: message.authorName) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { Text("Mesajları bu telefonda gizlenir ve sana özel mesaj gönderemez. Engeli Arkadaşlar sayfasından kaldırabilirsin.") }
        .sheet(isPresented: $reporting) {
            ReportSheet(title: "Mesajı bildir", subject: "\(message.authorName): " + String(chat.displayContent(message).prefix(120))) { reason, note in
                try await safety.reportMessage(message.id, reason: reason, context: note)
            }
        }
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("Tamam") {} } message: { Text(notice?.message ?? "") }
    }
    private var copyLink: URL? { MessageLinks.first(in: chat.displayContent(message)) }
    private var card: some View {
        HStack(alignment: .top, spacing: 11) {
            if grouped { Color.clear.frame(width: 44, height: 1).accessibilityHidden(true) }
            else { Button { openProfile(message.authorID) } label: { ChatAvatarView(chat: chat, userID: message.authorID, name: message.authorName, size: 34).frame(width: 44, height: 44, alignment: .top) }.buttonStyle(.plain).accessibilityLabel("\(message.authorName) profilini aç") }
            VStack(alignment: .leading, spacing: 6) {
                if !grouped {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(chat.profileCache[message.authorID]?.name ?? message.authorName).font(.subheadline.bold()).foregroundStyle(.primary)
                        if message.created != .distantPast { Text(message.created, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Menu { actions } label: { Image(systemName: "ellipsis").font(.subheadline).frame(width: 44, height: 44).contentShape(Rectangle()) }.disabled(busy).accessibilityLabel("Mesaj işlemleri")
                    }
                }
                ForEach(message.replyIDs, id: \.self) { id in
                    Button { openReply(id, message.channelID) } label: {
                        Label(chat.timeline.message(id).map { safety.isBlocked($0.authorID) ? "Engellenen kullanıcının mesajı" : $0.authorName + ": " + String(chat.displayContent($0).prefix(100)) } ?? "Yanıtlanan mesajı aç", systemImage: "arrowshape.turn.up.left")
                            .font(.caption).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if let gif = MessageMarkup.gifURL(message.content) { KlipyMessageGif(url: gif) }
                else if !message.content.isEmpty { MessageTextView(chat: chat, message: message) }
                if message.edited { Text("düzenlendi").font(.caption2).foregroundStyle(.secondary) }
                ForEach(message.attachments) { attachment in
                    if attachment.mime.hasPrefix("image/") && message.delivery == .sent && chat.access.history {
                        Button { openFile(attachment, message) } label: { InlinePhoto(chat: chat, attachment: attachment, message: message) }
                            .buttonStyle(.plain).accessibilityLabel("\(attachment.name) fotoğrafını büyüt")
                    } else if ChatVideo.playable(attachment.mime) && message.delivery == .sent && chat.access.history {
                        VideoAttachmentCard(chat: chat, attachment: attachment, message: message) { openFile(attachment, message) }
                    } else {
                    Button { openFile(attachment, message) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            if attachment.mime.hasPrefix("image/") { Image(systemName: "photo").font(.largeTitle).foregroundStyle(Palette.accent).frame(maxWidth: .infinity, minHeight: 92).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)) }
                            HStack(spacing: 9) { Image(systemName: attachment.mime.hasPrefix("image/") ? "photo" : "doc").foregroundStyle(Palette.accent); VStack(alignment: .leading, spacing: 4) { Text(attachment.name).font(.subheadline).lineLimit(2); Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }; Spacer(minLength: 0); Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
                        }.padding(11).frame(maxWidth: .infinity, minHeight: 48).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(message.delivery != .sent || !chat.access.history).accessibilityLabel("\(attachment.name) dosyasını aç")
                    }
                }
                if !message.reactions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
                        ForEach(message.reactions.keys.sorted(), id: \.self) { emoji in
                            let selected = message.reactions[emoji]?.contains(currentUserID) == true
                            Button { Task { _ = await chat.perform(.reaction(id: message.id, emoji: emoji, remove: selected)) } } label: {
                                HStack(spacing: 4) { ReactionLabel(chat: chat, key: emoji, size: 16); Text("\(message.reactions[emoji]?.count ?? 0)") }.font(.caption.bold()).padding(.horizontal, 9).frame(minHeight: 44)
                            }
                                .buttonStyle(RoomControlStyle(selected: selected)).disabled(busy || !chat.access.react || !chat.access.history)
                                .accessibilityLabel("\(ReactionLabel.name(emoji, chat: chat)) reaksiyonu").accessibilityValue("\(message.reactions[emoji]?.count ?? 0) kişi" + (selected ? ", seçili" : ""))
                        }
                    } }
                }
                switch message.delivery {
                case .sending: Label("Gönderiliyor…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                case .failed: HStack { Text("Gönderim doğrulanamadı").font(.caption).foregroundStyle(.secondary); Button("Tekrar gönder") { chat.retrySend(message.id) }.disabled(!chat.access.send || chat.loading); Button("Listeden kaldır") { chat.discardPending(message.id) } }.font(.caption)
                case .sent: EmptyView()
                }
                if busy { ProgressView("İşleniyor…").font(.caption) }
            }
        }.padding(.top, grouped ? 0 : 8).frame(maxWidth: .infinity, alignment: .leading).contextMenu { actions }.accessibilityIdentifier("chat.message.\(message.id)")
    }
    @ViewBuilder private var actions: some View {
        if message.delivery == .sent {
            Button("Yanıtla", systemImage: "arrowshape.turn.up.left") { chat.setReply(message.id) }.disabled(!chat.access.send)
            if chat.access.react && chat.access.history {
                ForEach(EmojiOption.defaults) { emoji in Button(emoji.symbol + " " + emoji.name) { Task { _ = await chat.perform(.reaction(id: message.id, emoji: chat.reactionKey(message, for: emoji.id), remove: chat.reactionSelected(message, emoji: emoji.id))) } } }
                if let react { Button("Diğer tepkiler…", systemImage: "face.smiling") { react(message) } }
            }
            Button("Profili görüntüle", systemImage: "person.crop.circle") { openProfile(message.authorID) }
            if !message.content.isEmpty { Button("Kopyala", systemImage: "doc.on.doc") { UIPasteboard.general.string = chat.displayContent(message) } }
            if let copyLink { Button("Bağlantıyı kopyala", systemImage: "link") { UIPasteboard.general.url = copyLink } }
            if message.authorID == currentUserID { Button("Düzenle", systemImage: "pencil") { edit(message) }.disabled(!chat.access.send); Button("Sil", systemImage: "trash", role: .destructive) { delete(message) } }
            else {
                // ManageMessages (desktop `moderates`); the server still rechecks the delete.
                if safety.canModerate(message.channelID) { Button("Sil", systemImage: "trash", role: .destructive) { delete(message) } }
                Button("Mesajı bildir", systemImage: "flag") { reporting = true }
                if safety.isBlocked(message.authorID) { Button("Engeli kaldır", systemImage: "person.crop.circle.badge.checkmark") { Task { notice = await SafetyActions.unblock(message.authorID, name: message.authorName) } } }
                else { Button("Kullanıcıyı engelle", systemImage: "person.slash", role: .destructive) { confirmBlock = true } }
            }
        }
    }
}

struct EmojiOption: Identifiable {
    let id: String; let symbol: String; let name: String
    static let defaults = [EmojiOption(id: "1f44d", symbol: "👍", name: "Beğen"), .init(id: "2764-fe0f", symbol: "❤️", name: "Kalp"), .init(id: "1f602", symbol: "😂", name: "Gül"), .init(id: "1f389", symbol: "🎉", name: "Kutla"), .init(id: "1f62e", symbol: "😮", name: "Şaşır")]
}

struct MessageEditView: View {
    @ObservedObject var chat: ChatController
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var saving = false
    init(chat: ChatController, message: ChatMessage) { self.chat = chat; self.message = message; _content = State(initialValue: message.content) }
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $content).frame(minHeight: 150).accessibilityLabel("Mesaj metni")
                Text("\(content.count)/4000").font(.caption).foregroundStyle(.secondary)
                if let error = chat.actionError { Text(error).foregroundStyle(.secondary) }
            }.navigationTitle("Mesajı düzenle").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Kaydediliyor…" : "Kaydet") {
                            saving = true; Task { if await chat.perform(.edit(id: message.id, content: content)) { dismiss() }; saving = false }
                        }.disabled(saving || content.count > 4000 || (content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachments.isEmpty))
                    }
                }
        }.interactiveDismissDisabled(saving)
    }
}

struct ProfileView: View {
    @ObservedObject var chat: ChatController
    let userID: String
    let currentUserID: String
    let message: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var error: String?
    @State private var retry = UUID()
    @ObservedObject private var safety = SafetyCenter.shared
    @State private var confirmBlock = false
    @State private var reporting = false
    @State private var notice: SafetyNotice?
    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        ChatAvatarView(chat: chat, userID: userID, name: profile.name, size: 80)
                        Text(profile.name).font(.title2.bold())
                        Text(profile.username + (profile.discriminator.map { "#" + $0 } ?? "")).foregroundStyle(.secondary).textSelection(.enabled)
                        if let status = profile.status, !status.isEmpty { Text(status) }
                    }
                    if let bio = profile.bio, !bio.isEmpty { Section("Hakkında") { Text(verbatim: bio).textSelection(.enabled) } }
                    if userID != currentUserID {
                        Section { Button("Mesaj gönder", systemImage: "text.bubble") { dismiss(); message() }.frame(minHeight: 44) }
                        Section {
                            if safety.isBlocked(userID) { Button("Engeli kaldır", systemImage: "person.crop.circle.badge.checkmark") { Task { notice = await SafetyActions.unblock(userID, name: profile.name) } }.frame(minHeight: 44) }
                            else { Button("Kullanıcıyı engelle", systemImage: "person.slash", role: .destructive) { confirmBlock = true }.frame(minHeight: 44) }
                            Button("Kullanıcıyı bildir", systemImage: "flag", role: .destructive) { reporting = true }.frame(minHeight: 44)
                        } footer: { Text("Bildirimler sunucu yöneticilerine iletilir.") }
                    }
                } else if let error { Section { Text(error); Button("Tekrar dene") { retry = UUID() } } }
                else { ProgressView("Profil yükleniyor…") }
            }.navigationTitle("Profil").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
                .onChange(of: chat.authorityGeneration) { _, _ in profile = nil; retry = UUID() }
                .confirmationDialog("\(profile?.name ?? "Bu kullanıcı") engellensin mi?", isPresented: $confirmBlock, titleVisibility: .visible) {
                    Button("Engelle", role: .destructive) { Task { notice = await SafetyActions.block(userID, name: profile?.name ?? "Kullanıcı") } }
                    Button("Vazgeç", role: .cancel) {}
                } message: { Text("Mesajları bu telefonda gizlenir ve sana özel mesaj gönderemez. Engeli Arkadaşlar sayfasından kaldırabilirsin.") }
                .sheet(isPresented: $reporting) {
                    ReportSheet(title: "Kullanıcıyı bildir", subject: profile?.name ?? "Kullanıcı") { reason, note in try await safety.reportUser(userID, reason: reason, context: note) }
                }
                .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("Tamam") {} } message: { Text(notice?.message ?? "") }
                .task { safety.attach(SafetyClient.make); await safety.ensureLoaded() }
                .task(id: retry) {
                    profile = nil; error = nil
                    do { let value = try await chat.fetchProfile(userID); if !Task.isCancelled { profile = value } }
                    catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
        }
    }
}

struct ReplyDetailView: View {
    @ObservedObject var chat: ChatController
    let messageID: String
    let channelID: String
    @Environment(\.dismiss) private var dismiss
    @State private var message: ChatMessage?
    @State private var error: String?
    @State private var retry = UUID()
    var body: some View {
        NavigationStack {
            ScrollView {
                if let message { VStack(alignment: .leading, spacing: 12) { Text(message.authorName).font(.headline); Text(verbatim: chat.displayContent(message)).textSelection(.enabled); if !message.attachments.isEmpty { Text("\(message.attachments.count) ek").foregroundStyle(.secondary) } }.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                else if let error { VStack { Text(error); Button("Tekrar dene") { retry = UUID() } }.padding() }
                else { ProgressView("Mesaj yükleniyor…").padding() }
            }.navigationTitle("Yanıtlanan mesaj").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
                .task(id: retry) { do { message = try await chat.fetchReply(messageID, channelID: channelID) } catch { if !Task.isCancelled { self.error = error.localizedDescription } } }
        }
    }
}

/// A photo shown inside the conversation, like Discord; tapping opens it full size.
struct InlinePhoto: View {
    @ObservedObject var chat: ChatController
    let attachment: ChatAttachment
    let message: ChatMessage
    @State private var image: UIImage?
    @State private var animated: Data?
    @State private var failed = false
    var body: some View {
        Group {
            if let image, let animated, image.size.height > 0 {
                AnimatedImage(data: animated).aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 320), maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel("GIF")
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: min(image.size.width, 320), maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Palette.surface).frame(width: 220, height: 150)
                    .overlay { if failed { Label("Fotoğraf açılamadı", systemImage: "photo").font(.caption).foregroundStyle(.secondary) } else { ProgressView() } }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: "\(chat.sessionGeneration)-\(attachment.id)") {
                failed = false
                do {
                    let url = try await chat.preview(attachment, message: message)
                    let decoded = await Task.detached(priority: .userInitiated) { thumbnail(url, pixels: 960) }.value
                    // A GIF animates in place; its first frame sizes the view.
                    let gif = attachment.mime == "image/gif" && attachment.size <= 8_000_000 ? await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value : nil
                    if !Task.isCancelled { image = decoded; animated = gif; failed = decoded == nil }
                } catch { if !Task.isCancelled { failed = true } }
            }
    }
}
struct AttachmentViewer: View {
    @ObservedObject var chat: ChatController
    let attachment: ChatAttachment
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = UUID()
    /// The photo file belongs to the conversation's inline cache; the viewer must not delete it.
    @State private var shared = false
    var body: some View {
        NavigationStack {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(.black) }
                else if let file { QuickLookFile(url: file) }
                else if let error { VStack(spacing: 16) { Text(error); Button("Tekrar dene") { retry = UUID() } }.padding(24) }
                else { ProgressView("Dosya indiriliyor…") }
            }.navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } }
                    ToolbarItem(placement: .topBarLeading) { if let file { ShareLink(item: file) { Label("Paylaş / kaydet", systemImage: "square.and.arrow.up") } } }
                }
                .task(id: retry) {
                    error = nil
                    do {
                        if attachment.mime.hasPrefix("image/") {
                            let url = try await chat.preview(attachment, message: message)
                            guard !Task.isCancelled else { return }
                            shared = true; file = url; image = thumbnail(url, pixels: 1600); return
                        }
                        let url = try await chat.download(attachment, message: message)
                        guard !Task.isCancelled else { FileStager.remove(url); return }
                        file = url
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
                .onDisappear { if let file, !shared { FileStager.remove(file) }; file = nil; image = nil }
        }
    }
}
private struct QuickLookFile: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { context.coordinator.url = url; controller.reloadData() }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

struct PickedImage: Transferable, Sendable {
    let file: LocalAttachment
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { value in SentTransferredFile(value.file.url) }
            importing: { received in
                let type = UTType(filenameExtension: received.file.pathExtension)?.preferredMIMEType ?? "image/jpeg"
                // HEIC and other camera formats become a JPEG the desktop chat shows inline.
                return PickedImage(file: try PhotoNormalizer.prepare(try FileStager.stage(source: received.file, mime: type)))
            }
    }
}

struct AttachmentComposer<Composer: View>: View {
    @ObservedObject var chat: ChatController
    var onPickerActive: (Bool) -> Void
    @ViewBuilder var composer: () -> Composer
    @State private var importing = false
    @State private var pickingPhoto = false
    @State private var pickingGif = false
    @State private var photo: PhotosPickerItem?
    @State private var importingChannel = ""
    @State private var importingSession: UInt64 = 0
    @State private var error: String?
    @State private var preparing = false
    @State private var preparation: Task<Void, Never>?
    @State private var preparationID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chat.currentAttachments) { draft in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.file.name).font(.caption).lineLimit(1)
                        if draft.state == .uploading { ProgressView(value: draft.progress).accessibilityLabel("Dosya yükleniyor").accessibilityValue("Yüzde \(Int(draft.progress * 100))") }
                        else if draft.state == .ready { Text("Gönderilmeye hazır").font(.caption2).foregroundStyle(.secondary) }
                        else { Text("Yükleme doğrulanamadı").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if draft.state == .failed { Button("Tekrar dene") { chat.retryAttachment(draft.id) }.font(.caption) }
                    Button { chat.cancelAttachment(draft.id) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel(draft.state == .uploading ? "Yüklemeyi iptal et" : "Eki kaldır")
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                if chat.access.files || chat.access.send || !chat.mentionUsers.isEmpty {
                    Menu {
                        if chat.access.files {
                            Button("Fotoğraf seç", systemImage: "photo") { captureScope(); pickingPhoto = true }
                            Button("Dosya seç", systemImage: "doc") { captureScope(); importing = true }
                        }
                        if chat.access.send { Button("GIF gönder", systemImage: "sparkles.rectangle.stack") { error = nil; pickingGif = true } }
                        if !chat.mentionUsers.isEmpty { Menu("Bahset", systemImage: "at") { ForEach(chat.mentionUsers, id: \.id) { user in Button(user.name) { chat.insertMention(user.id) } } } }
                    } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44) }.disabled(preparing)
                        .accessibilityLabel("Dosya, fotoğraf, GIF veya bahsetme ekle")
                }
                composer()
            }.padding(4).background(Palette.raised, in: RoundedRectangle(cornerRadius: 20))
            if preparing { HStack { ProgressView("Hazırlanıyor…").font(.caption); Button("İptal") { cancelPreparation() }.font(.caption).frame(minHeight: 44) } }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                preparing = true; let requestID = UUID(); preparationID = requestID
                preparation = Task {
                    let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() }; if preparationID == requestID { preparing = false; preparation = nil } }
                    do {
                        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType ?? "application/octet-stream"
                        let worker = Task.detached { try PhotoNormalizer.prepareFile(try FileStager.stage(source: url, mime: type)) }
                        let file = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                        guard !Task.isCancelled, preparationID == requestID else { FileStager.remove(file.url); return }
                        chat.addAttachment(file, channelID: importingChannel, expectedSession: importingSession)
                    } catch { if !Task.isCancelled, preparationID == requestID { self.error = error.localizedDescription } }
                }
            }
        }
        .onDisappear { cancelPreparation(); onPickerActive(false) }
        .onChange(of: chat.selected?.id) { _, _ in cancelPreparation() }
        .onChange(of: importing || pickingPhoto || pickingGif) { _, active in onPickerActive(active) }
        .sheet(isPresented: $pickingGif) { GifPickerView(chat: chat) }
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }; preparing = true; let requestID = UUID(); preparationID = requestID
            preparation = Task {
                defer { if preparationID == requestID { preparing = false; photo = nil; preparation = nil } }
                do {
                    if let value = try await item.loadTransferable(type: PickedImage.self) {
                        guard !Task.isCancelled, preparationID == requestID else { FileStager.remove(value.file.url); return }
                        chat.addAttachment(value.file, channelID: importingChannel, expectedSession: importingSession)
                    }
                } catch { if !Task.isCancelled, preparationID == requestID { self.error = error.localizedDescription } }
            }
        }
    }
    private func cancelPreparation() { preparation?.cancel(); preparation = nil; preparationID = UUID(); preparing = false; photo = nil }
    private func captureScope() { importingSession = chat.sessionGeneration; importingChannel = chat.selected?.id ?? ""; error = nil }
}


// MARK: Safety helpers (App Store guideline 1.2)

/// Builds the client the safety calls use from the same Keychain session the app signed in with.
enum SafetyClient {
    static func make() -> APIClient? {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "ROOMSAPIOrigin") as? String,
              let origin = try? EndpointPolicy.origin(configured),
              let token = try? SessionVault.read(origin: origin) else { return nil }
        return APIClient(origin: origin, token: token)
    }
}

struct SafetyNotice: Identifiable { let id = UUID(); let title: String; let message: String }

/// Block and unblock with a result the person can read.
@MainActor enum SafetyActions {
    static func block(_ id: String, name: String) async -> SafetyNotice {
        do { try await SafetyCenter.shared.block(id); return SafetyNotice(title: "Engellendi", message: "\(name) engellendi. Mesajları gizlendi.") }
        catch { return SafetyNotice(title: "Engellenemedi", message: failure(error)) }
    }
    static func unblock(_ id: String, name: String) async -> SafetyNotice {
        do { try await SafetyCenter.shared.unblock(id); return SafetyNotice(title: "Engel kaldırıldı", message: "\(name) artık engelli değil.") }
        catch { return SafetyNotice(title: "Engel kaldırılamadı", message: failure(error)) }
    }
    /// 403/404 map to "no access to this room" in the shared client; these calls are not about rooms.
    static func failure(_ error: Error) -> String {
        if let known = error as? RoomsError {
            switch known {
            case .denied: return "Bu işlem için iznin yok ya da sunucu bu işlemi desteklemiyor."
            case .rateLimited: return "Çok sık denedin. Biraz bekleyip tekrar dene."
            default: return known.localizedDescription
            }
        }
        return "İşlem tamamlanamadı. Bağlantını kontrol edip tekrar dene."
    }
}

enum MessageLinks {
    /// The first http(s) link in a message, for "Bağlantıyı kopyala".
    static func first(in text: String) -> URL? {
        guard text.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).lazy.compactMap(\.url).first { $0.scheme == "http" || $0.scheme == "https" }
    }
}

/// Reason and optional note for a report; `submit` throws when the server refuses it.
struct ReportSheet: View {
    let title: String
    let subject: String
    let submit: (SafetyReportReason, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = SafetyReportReason.spam
    @State private var note = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Bildirilen") { Text(subject).lineLimit(3) }
                Section("Neden?") {
                    Picker("Neden", selection: $reason) { ForEach(SafetyReportReason.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.inline).labelsHidden()
                }
                Section { TextField("Eklemek istediğin bir not (isteğe bağlı)", text: $note, axis: .vertical).lineLimit(3...6).onChange(of: note) { _, value in if value.count > SafetyPolicy.contextLimit { note = String(value.prefix(SafetyPolicy.contextLimit)) } } } footer: { Text("Bildirim sunucu yöneticilerine iletilir.") }
                if sent { Section { Label("Bildirimin gönderildi. Teşekkürler.", systemImage: "checkmark.circle").foregroundStyle(.green) } }
                else if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(sent ? "Kapat" : "Vazgeç") { dismiss() }.disabled(sending) }
                    if !sent {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(sending ? "Gönderiliyor…" : "Gönder") {
                                sending = true; error = nil
                                Task {
                                    do { try await submit(reason, note); sent = true }
                                    catch { self.error = SafetyActions.failure(error) }
                                    sending = false
                                }
                            }.disabled(sending)
                        }
                    }
                }
        }.interactiveDismissDisabled(sending)
    }
}
