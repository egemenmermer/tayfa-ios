import Foundation
import RoomsCore

/// Community cinema halls for the signed-in account: which channel is each community's hall
/// (desktop `cinema-status.ts`), the hall activity shown in the sidebar, and the open hall,
/// which keeps playing while the person browses the rest of the app.
@MainActor final class CinemaHub: ObservableObject {
    @Published private(set) var statuses: [String: CinemaStatus] = [:]
    /// The open hall; nil when the person left it.
    @Published private(set) var hall: HallModel?
    /// Whether the open hall fills the screen (false: it plays in the mini player).
    @Published var expanded = false
    private var api: APIClient?
    private var me: String?
    private var selected: String?
    private var foreground = true
    private var refresher: Task<Void, Never>?
    /// Hall activities by hall channel, polled while their sidebar row or hall is on screen.
    private var activities: [String: WatchTogetherModel] = [:]
    private var watchedRows: Set<String> = []

    func configure(api: APIClient, me: String) {
        reset(); self.api = api; self.me = me; restart()
    }
    /// Signing out: closes the hall without telling the service (the session is gone).
    func reset() {
        hall?.close(sendLeave: false); hall = nil; expanded = false
        refresher?.cancel(); refresher = nil
        activities.values.forEach { $0.stop() }; activities = [:]; watchedRows = []
        statuses = [:]; api = nil; me = nil
    }
    /// The community whose sidebar is on screen (nil while the direct messages list is shown).
    func select(community: String?) {
        guard selected != community else { return }
        selected = community; restart()
    }
    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value {
            restart()
            // A poll that was frozen in the background starts over instead of failing first.
            for id in watchedRows.union([hall?.id].compactMap { $0 }) { activities[id]?.stop(); activity(hallID: id)?.start() }
        }
        else {
            refresher?.cancel(); refresher = nil
            // An open hall keeps its seat (and plays in the background); sidebar previews pause.
            for id in watchedRows where id != hall?.id { activities[id]?.stop() }
        }
    }
    func hallID(community: String?) -> String? { community.flatMap { statuses[$0]?.hallChannelId } }
    func isOwner(community: String?) -> Bool { community.flatMap { statuses[$0]?.isOwner } ?? false }

    /// The hall activity for one hall channel; shared by the sidebar row and the open hall.
    func activity(hallID: String) -> WatchTogetherModel? {
        if let existing = activities[hallID] { return existing }
        guard let api, let me else { return nil }
        let model = WatchTogetherModel(api: api, roomID: hallID, me: me)
        activities[hallID] = model; return model
    }
    /// The sidebar row of `hallID` appeared (true) or went away (false).
    func watchRow(_ hallID: String, visible: Bool) {
        if visible { watchedRows.insert(hallID); if foreground { activity(hallID: hallID)?.start() } }
        else { watchedRows.remove(hallID); if hall?.id != hallID { activities[hallID]?.stop() } }
    }

    /// Opens (or brings back) the hall of `community`.
    func open(community: String) {
        guard let status = statuses[community], let hallID = status.hallChannelId, let api, let me else { return }
        if let hall, hall.id == hallID { expanded = true; return }
        hall?.close(sendLeave: true)
        guard let activity = activity(hallID: hallID) else { return }
        let model = HallModel(api: api, me: me, communityID: community, status: status, activity: activity)
        hall = model; expanded = true
        model.open()
        restart()
    }
    func minimize() { expanded = false }
    /// Leaves the hall: the player stops and the seat is given up.
    func close() {
        guard let hall else { return }
        hall.close(sendLeave: true)
        if !watchedRows.contains(hall.id) { activities[hall.id]?.stop() }
        self.hall = nil; expanded = false
        restart()
    }

    private func restart() {
        refresher?.cancel(); refresher = nil
        guard api != nil, foreground else { return }
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = Set([self.selected, self.hall?.communityID].compactMap { $0 })
                for id in ids { await self.refresh(community: id) }
                // Faster while the catalog imports, as on desktop.
                let importing = ids.contains { self.statuses[$0]?.importRunning == true }
                do { try await Task.sleep(for: .seconds(importing ? 2 : 60)) } catch { return }
            }
        }
    }
    private func refresh(community: String) async {
        guard let api else { return }
        do {
            let status = try await api.cinemaStatus(community: community)
            guard self.api === api, status.communityId == community else { return }
            // Unchanged answers do not redraw the app.
            if statuses[community] != status { statuses[community] = status }
            if let hall, hall.communityID == community {
                if status.hallChannelId == hall.id { hall.update(status: status) }
                else { close() }
            }
        } catch is CancellationError {
        } catch {
            // A server without the cinema service, or a community without access, shows no hall.
            if (error as? CinemaError)?.code == "CINEMA_ACCESS_DENIED" { statuses.removeValue(forKey: community) }
        }
    }
}
