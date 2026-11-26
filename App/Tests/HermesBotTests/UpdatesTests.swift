import Foundation
import Testing
@testable import HermesBot

/// When the app turns Sparkle on, and what it says its version is.
@MainActor
struct UpdatesTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func info(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleShortVersionString": "0.2.0",
            "SUFeedURL": "https://github.com/dantemoon1/hermes-bot/releases/latest/download/appcast.xml",
            "SUPublicEDKey": key,
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
        ]
        for (name, value) in changes { info[name] = value }
        return info
    }

    @Test func aBundleWithAFeedAndAKeyHasUpdatesOn() {
        #expect(Updates.isConfigured(info()))
    }

    @Test func anythingMissingOrOddLeavesUpdatesOff() {
        let broken: [[String: Any?]] = [
            ["SUFeedURL": nil], ["SUPublicEDKey": nil],
            ["SUFeedURL": "http://github.com/appcast.xml"], ["SUFeedURL": "file:///tmp/appcast.xml"],
            ["SUFeedURL": "https://"], ["SUFeedURL": "not a url"], ["SUFeedURL": 3],
            ["SUPublicEDKey": ""], ["SUPublicEDKey": "not base64!"],
            ["SUPublicEDKey": Data(repeating: 1, count: 31).base64EncodedString()],
            ["SUPublicEDKey": Data(repeating: 1, count: 64).base64EncodedString()],
            ["SUVerifyUpdateBeforeExtraction": nil], ["SUVerifyUpdateBeforeExtraction": false], ["SUVerifyUpdateBeforeExtraction": "YES"],
            ["SURequireSignedFeed": nil], ["SURequireSignedFeed": false],
            ["SUSignedFeedFailureExpirationInterval": nil], ["SUSignedFeedFailureExpirationInterval": 1_728_000],
        ]
        for change in broken {
            #expect(!Updates.isConfigured(info(change)), "\(change)")
        }
    }

    @Test func theVersionShownIsTheBundles() {
        #expect(Updates.version(in: info()) == "0.2.0")
        #expect(Updates.version(in: [:]) == nil)
        #expect(Updates.version(in: ["CFBundleShortVersionString": ""]) == nil)
    }

    /// The tests run outside an app bundle, as `swift run` does: updates are off, and
    /// nothing of Sparkle's is started.
    @Test func outsideAnAppBundleUpdatesAreOff() {
        let updates = Updates(bundle: .main)
        #expect(!updates.isOn)
        #expect(!updates.canCheck)
        #expect(!updates.checksAutomatically)
        updates.check()
    }
}
