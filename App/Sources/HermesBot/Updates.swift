import Foundation
import Observation
import Sparkle

/// Installing new versions of the app, with Sparkle. Sparkle looks at the
/// release feed once a day (its own schedule; the person can turn it off in Settings),
/// and offers a newer version in its own window, where it is downloaded, checked against
/// the app's EdDSA key and installed. "Check for Updates…" in the app menu looks at once.
///
/// It is on only in an app bundle that `Tools/make-app.sh` gave a feed and a public key
/// (`SUFeedURL`, `SUPublicEDKey`); anything else (a local build made without a key, or
/// `swift run`) has updates off and only says its version.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    /// The version this copy of the app is, from its bundle; nil when it runs from source.
    let current: String?
    /// Sparkle's updater, when updates are on.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watching: NSKeyValueObservation?
    /// Whether a check can be asked for now: not while one is already under way.
    private(set) var canCheck = false

    var isOn: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        current = Self.version(in: bundle.infoDictionary ?? [:])
        // Sparkle updates the main bundle whatever it is given, so only that one is asked.
        guard bundle == .main, bundle.bundleURL.pathExtension == "app", Self.isConfigured(bundle.infoDictionary ?? [:]) else {
            controller = nil
            return
        }
        // Started at once, so the scheduled check runs from launch.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Sparkle changes it on the main thread.
        watching = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    /// Looks for a newer version now, in Sparkle's own window.
    func check() {
        controller?.checkForUpdates(nil)
    }

    /// Whether Sparkle looks for new versions by itself. Kept by Sparkle in this Mac's
    /// preferences for the app.
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// The version shown, `CFBundleShortVersionString`.
    nonisolated static func version(in info: [String: Any]) -> String? {
        (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether a bundle's `Info.plist` sets up updates: a feed at an https address, and
    /// an EdDSA public key (32 bytes, base64), with Sparkle told to check the archive's
    /// signature before it is unpacked and to take only a signed feed, for good. Sparkle itself
    /// refuses an update that fails any of these; this only keeps a bundle made without
    /// them from starting an updater that could never install anything.
    nonisolated static func isConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https", feed.host() != nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0
        else { return false }
        return true
    }
}
