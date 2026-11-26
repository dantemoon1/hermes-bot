import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Tells the person outside the app when a bot is waiting on them while the window is not in
/// front: a system notification (asked for the first time one is needed, never at launch) and
/// one quiet bounce of the Dock icon. Clicking a notification brings the app forward to that bot.
@MainActor
final class WaitingAlerts {
    struct Notice: Equatable, Sendable {
        /// Stable identifier for this waiting question, used to clear the notification when it ends.
        let id: String
        let botID: String
        let botTitle: String
        let body: String
    }

    /// Called when the person clicks a notification, naming the bot it was for.
    var onSelectBot: ((String) -> Void)?
    /// Called when a notification is clicked and the main window needs to be reopened.
    var onReopenWindow: (() -> Void)?

    private let postNotice: (Notice) -> Void
    private let removeNotices: ([String]) -> Void
    private let requestAttention: () -> Int
    private let cancelAttention: (Int) -> Void

    /// Active Dock attention request, cancelled when the app comes forward or every alerted notice clears.
    private var attentionRequest: Int?
    /// Identifiers of notifications posted and not yet removed, by bot.
    private var posted: [String: Set<String>] = [:]

    init(
        post: @escaping (Notice) -> Void,
        remove: @escaping ([String]) -> Void,
        bounce: @escaping () -> Int,
        cancelBounce: @escaping (Int) -> Void
    ) {
        self.postNotice = post
        self.removeNotices = remove
        self.requestAttention = bounce
        self.cancelAttention = cancelBounce
    }

    /// No-op alerts, used in tests unless a test supplies its own spy.
    static func silent() -> WaitingAlerts {
        WaitingAlerts(post: { _ in }, remove: { _ in }, bounce: { 0 }, cancelBounce: { _ in })
    }

    /// Live macOS alerts: system notifications (when running as a `.app` bundle) and a single
    /// informational Dock bounce. Never prompts for notification permission until `notify` runs.
    static func live() -> WaitingAlerts {
        let bridge = SystemNotificationBridge()
        let alerts = WaitingAlerts(
            post: { bridge.post($0) },
            remove: { bridge.remove($0) },
            bounce: { NSApp.requestUserAttention(.informationalRequest) },
            cancelBounce: { NSApp.cancelUserAttentionRequest($0) }
        )
        bridge.onSelectBot = { [weak alerts] botID in
            alerts?.selectBot(botID)
        }
        bridge.installDelegateIfBundled()
        return alerts
    }

    /// Alerts the person outside the app that a bot is waiting on them.
    func notify(_ notice: Notice) {
        posted[notice.botID, default: []].insert(notice.id)
        postNotice(notice)
        if let existing = attentionRequest {
            cancelAttention(existing)
        }
        attentionRequest = requestAttention()
    }

    /// Removes notifications for questions that are no longer waiting. Cancels the Dock
    /// bounce once no alerted question remains open.
    func reconcile(openIDs: Set<String>) {
        var toRemove: [String] = []
        for (botID, ids) in posted {
            let stale = ids.subtracting(openIDs)
            guard !stale.isEmpty else { continue }
            toRemove.append(contentsOf: stale)
            let remaining = ids.subtracting(stale)
            posted[botID] = remaining.isEmpty ? nil : remaining
        }
        if !toRemove.isEmpty { removeNotices(toRemove) }
        if posted.isEmpty { cancelBounce() }
    }

    /// Removes every notification posted for a bot (the person looked at it, or it was deleted).
    func clearBot(_ botID: String) {
        guard let ids = posted.removeValue(forKey: botID), !ids.isEmpty else { return }
        removeNotices(Array(ids))
        if posted.isEmpty { cancelBounce() }
    }

    /// The window came to the front: stop bouncing and clear notices for the bot on screen.
    func appCameForward(selectedBotID: String?) {
        cancelBounce()
        if let selectedBotID { clearBot(selectedBotID) }
    }

    /// Clears every posted notification and cancels any Dock bounce (leaving the gateway).
    func clearAll() {
        let all = posted.values.flatMap { $0 }
        posted = [:]
        if !all.isEmpty { removeNotices(all) }
        cancelBounce()
    }

    /// Handles clicking a notification (called by the system delegate and by tests).
    func selectBot(_ botID: String) {
        clearBot(botID)
        cancelBounce()
        onReopenWindow?()
        onSelectBot?(botID)
    }

    private func cancelBounce() {
        guard let existing = attentionRequest else { return }
        attentionRequest = nil
        cancelAttention(existing)
    }
}

/// Bridges `UNUserNotificationCenter` safely. Guarded to `.app` bundles because
/// `UNUserNotificationCenter.current()` aborts unbundled executables (`swift run` / `swift test`).
@MainActor
private final class SystemNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    var onSelectBot: ((String) -> Void)?
    /// Identifiers still wanted; checked both before and after awaiting `add` so a question
    /// that settled while submission was in flight never leaves a stale banner behind.
    private var liveIDs: Set<String> = []
    /// Coalesces concurrent first-time permission prompts into one.
    private var authTask: Task<Bool, Never>?

    /// `UNUserNotificationCenter.current()` throws an uncatchable Obj-C exception outside a `.app`.
    private static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func installDelegateIfBundled() {
        guard Self.isBundledApp else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ notice: WaitingAlerts.Notice) {
        guard Self.isBundledApp else { return }
        liveIDs.insert(notice.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.ensureAuthorized(), self.liveIDs.contains(notice.id) else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.botTitle
            content.body = notice.body
            content.sound = .default
            content.userInfo = ["botID": notice.botID]
            let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
            let center = UNUserNotificationCenter.current()
            try? await center.add(request)
            // Recheck after submission: if the question settled while `add` was suspended,
            // `remove` ran before registration completed, so clear it now.
            if !self.liveIDs.contains(notice.id) {
                center.removePendingNotificationRequests(withIdentifiers: [notice.id])
                center.removeDeliveredNotifications(withIdentifiers: [notice.id])
            }
        }
    }

    func remove(_ ids: [String]) {
        for id in ids { liveIDs.remove(id) }
        guard Self.isBundledApp, !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func ensureAuthorized() async -> Bool {
        if let existing = authTask { return await existing.value }
        let task = Task { @MainActor () -> Bool in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                return true
            case .notDetermined:
                return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            default:
                return false
            }
        }
        authTask = task
        let granted = await task.value
        if authTask == task { authTask = nil }
        return granted
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run {
            let visible = NSApp.isActive && NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }
            return visible ? [] : [.banner, .sound]
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let botID = response.notification.request.content.userInfo["botID"] as? String
        await MainActor.run {
            if let botID { self.onSelectBot?(botID) }
            NSApp.activate()
            for window in NSApp.windows where window.canBecomeMain {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
