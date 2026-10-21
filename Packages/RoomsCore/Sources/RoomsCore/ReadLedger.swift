import Foundation

public struct ChannelReadState: Equatable, Sendable {
    public let channelID: String
    public let lastReadID: String?
    public let mentions: [String]
    public init(channelID: String, lastReadID: String?, mentions: [String] = []) { self.channelID = channelID; self.lastReadID = lastReadID; self.mentions = mentions }
}

/// Stoat ULIDs are ordered chronologically. Markers advance monotonically;
/// a delayed sync/ack cannot erase newer reads or newer incoming messages.
public struct ReadLedger: Equatable, Sendable {
    public private(set) var available = false
    public private(set) var states: [String: ChannelReadState] = [:]
    public private(set) var latest: [String: String] = [:]
    private var unknownLatest: Set<String> = []
    private var deleted: [String: Set<String>] = [:]
    public init() {}
    public mutating func markUnavailable() { available = false; latest = [:]; unknownLatest = [] }
    public mutating func observeLatest(channelID: String, messageID: String?) {
        guard let messageID else { return }
        if deleted[channelID]?.contains(messageID) == true { if latest[channelID] == nil { unknownLatest.insert(channelID) }; return }
        unknownLatest.remove(channelID)
        if latest[channelID] == nil || latest[channelID]! < messageID { latest[channelID] = messageID }
    }
    public mutating func merge(_ records: [ChannelReadState], baseline: [String: ChannelReadState]? = nil) {
        for record in records {
            let old = states[record.channelID]
            let marker = [old?.lastReadID, record.lastReadID].compactMap { $0 }.max()
            let preserved = (old?.mentions ?? []).filter { baseline == nil || !(baseline?[record.channelID]?.mentions ?? []).contains($0) }
            let mentions = Set(preserved + record.mentions).filter { (marker == nil || $0 > marker!) && deleted[record.channelID]?.contains($0) != true }.sorted()
            states[record.channelID] = ChannelReadState(channelID: record.channelID, lastReadID: marker, mentions: mentions)
        }
        if let baseline {
            let received = Set(records.map(\.channelID))
            for (channelID, snapshot) in baseline where !received.contains(channelID) {
                if let current = states[channelID] {
                    states[channelID] = ChannelReadState(channelID: channelID, lastReadID: current.lastReadID, mentions: current.mentions.filter { !snapshot.mentions.contains($0) })
                }
            }
        }
        available = true
    }
    public mutating func acknowledge(channelID: String, messageID: String) {
        let old = states[channelID]
        let marker = max(old?.lastReadID ?? messageID, messageID)
        states[channelID] = ChannelReadState(channelID: channelID, lastReadID: marker, mentions: (old?.mentions ?? []).filter { $0 > marker })
    }
    public mutating func observeMention(channelID: String, messageID: String) {
        let old = states[channelID]
        guard deleted[channelID]?.contains(messageID) != true else { return }
        guard old?.lastReadID == nil || messageID > old!.lastReadID! else { return }
        states[channelID] = ChannelReadState(channelID: channelID, lastReadID: old?.lastReadID, mentions: Array(Set((old?.mentions ?? []) + [messageID])).sorted())
    }
    public func unread(_ channelID: String) -> Bool? {
        guard available, !unknownLatest.contains(channelID) else { return nil }
        guard let last = latest[channelID] else { return false }
        return states[channelID]?.lastReadID.map { last > $0 } ?? true
    }
    public mutating func removeMessage(channelID: String, messageID: String, fallback: String?) {
        deleted[channelID, default: []].insert(messageID)
        if let old = states[channelID] { states[channelID] = ChannelReadState(channelID: channelID, lastReadID: old.lastReadID, mentions: old.mentions.filter { $0 != messageID }) }
        if latest[channelID] == messageID {
            latest.removeValue(forKey: channelID)
            if let fallback { observeLatest(channelID: channelID, messageID: fallback) }
            else { unknownLatest.insert(channelID) }
        }
    }
    public mutating func remove(_ channelID: String) { states.removeValue(forKey: channelID); latest.removeValue(forKey: channelID); unknownLatest.remove(channelID); deleted.removeValue(forKey: channelID) }
}
