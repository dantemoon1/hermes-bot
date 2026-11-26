import Foundation
import SwiftUI
import Testing
@testable import HermesBotUI

/// These faces are what existing bots already show. If this test fails, the seeding changed
/// and every bot without a saved look would get a new face.
@Test func seededLooksNeverChange() {
    #expect(AvatarLook(seed: "health") == AvatarLook(shape: .flower, color: .blue))
    #expect(AvatarLook(seed: "work") == AvatarLook(shape: .cloud, color: .brown))
    #expect(AvatarLook(seed: "") == AvatarLook(shape: .blob, color: .brown))
}

@Test func savedLookRoundTripsAndABrokenOneIsRejected() throws {
    let saved = try JSONEncoder().encode(AvatarLook(shape: .heart, color: .teal))
    #expect(try JSONDecoder().decode(AvatarLook.self, from: saved) == AvatarLook(shape: .heart, color: .teal))
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(AvatarLook.self, from: Data(#"{"shape":"heart"}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(AvatarLook.self, from: Data(#"{"shape":"dragon","color":"teal"}"#.utf8))
    }
}

@Test func everyShapeHasAnOutlineInsideItsFrame() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    for shape in AvatarShape.allCases {
        let bounds = AvatarSilhouette(shape).path(in: frame).cgPath.boundingBoxOfPath
        #expect(!bounds.isEmpty, "\(shape)")
        #expect(frame.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "\(shape) spills out: \(bounds)")
    }
}

/// At rest and looking as far as they go in every direction, the eyes stay on the body as it
/// is drawn: the outline inset by the avatar's padding, thickened by its stroke.
@Test func eyesStayOnTheBodyWhereverTheyLook() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    for shape in AvatarShape.allCases {
        let outline = AvatarSilhouette(shape).path(in: frame.insetBy(dx: 3.5, dy: 3.5))
        let edge = outline.strokedPath(StrokeStyle(lineWidth: 7, lineJoin: .round))
        var centers = [shape.eyeAnchor]
        for step in 0..<16 {
            let angle = Double(step) * .pi / 8
            centers.append(CGSize(width: cos(angle) * shape.eyeReach, height: sin(angle) * shape.eyeReach))
        }
        for center in centers {
            for point in EyeMetrics.eyeTips(at: center, in: frame) {
                #expect(outline.contains(point) || edge.contains(point), "\(shape) eye off its body looking at \(center)")
            }
        }
    }
}

@Test func eyesStayOnTheBodyWhenTheFaceSwingsUpright() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    for shape in AvatarShape.allCases {
        // The body turned out of its lean, about its middle, as it is drawn when watched.
        let turn = CGAffineTransform(translationX: 50, y: 50).rotated(by: -shape.lean * .pi / 180).translatedBy(x: -50, y: -50)
        let outline = AvatarSilhouette(shape).path(in: frame.insetBy(dx: 3.5, dy: 3.5)).applying(turn)
        let edge = outline.strokedPath(StrokeStyle(lineWidth: 7, lineJoin: .round))
        var centers = [CGSize(width: 0, height: 0.02)]
        for step in 0..<16 {
            let angle = Double(step) * .pi / 8
            centers.append(CGSize(width: cos(angle) * shape.eyeReach, height: sin(angle) * shape.eyeReach))
        }
        for center in centers {
            for point in EyeMetrics.eyeTips(at: center, in: frame, tilt: 0) {
                #expect(outline.contains(point) || edge.contains(point), "\(shape) upright eye off its body looking at \(center)")
            }
        }
    }
}

@Test func chatDateReadsLikeTheReference() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    let locale = Locale(identifier: "en_US")
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 17))!
    func text(_ components: DateComponents) -> String {
        ChatDate.text(for: calendar.date(from: components)!, now: now, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(text(DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 46)) == "Today 2:46 PM")
    #expect(text(DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 40)) == "Fri, Nov 20 10:40 AM")
    #expect(text(DateComponents(year: 2025, month: 12, day: 31, hour: 9, minute: 5)) == "Wed, Dec 31, 2025 9:05 AM")
}

@Test func toolSummaryNamesEachToolOnceAndCountsTheRest() {
    #expect(ToolSummary.text(for: ["calendar"]) == "Used calendar")
    #expect(ToolSummary.text(for: ["calendar", "weather", "calendar"]) == "Used calendar and weather")
    #expect(ToolSummary.text(for: ["web_search", "browser", "email", "calendar", "notes"])
        == "Used web search, browser, email, and 2 more")
}

@Test func commonSchedulesReadPlainlyAndOddOnesAreShownAsWritten() {
    let us = Locale(identifier: "en_US")
    func words(_ schedule: String) -> String {
        RoutineSchedule.text(for: schedule, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(words("*/3 * * * *") == "Every 3 minutes")
    #expect(words("* * * * *") == "Every minute")
    #expect(words("15 * * * *") == "Every hour")
    #expect(words("0 */6 * * *") == "Every 6 hours")
    #expect(words("30 5 * * *") == "Daily at 5:30 AM")
    #expect(words("0 9,21 * * *") == "Daily at 9:00 AM and 9:00 PM")
    #expect(words("0 13 * * 1-5") == "Weekdays at 1:00 PM")
    #expect(words("0 8 * * 1") == "Monday at 8:00 AM")
    #expect(words("0 8 * * 0,6") == "Sunday and Saturday at 8:00 AM")
    // Not guessed at.
    #expect(words("0 9 1 * *") == "0 9 1 * *")
    #expect(words("0 9-17 * * *") == "0 9-17 * * *")
    #expect(words("75 * * * *") == "75 * * * *")
    #expect(words("0 8 * * 5-1") == "0 8 * * 5-1")
    #expect(words("every other day") == "every other day")
    // Hermes's own short form, and days by name.
    #expect(words("every 2h") == "Every 2 hours")
    #expect(words("every 30m") == "Every 30 minutes")
    #expect(words("every 1d") == "Every day")
    #expect(words("0 13 * * MON-FRI") == "Weekdays at 1:00 PM")
    #expect(words("0 8 * * mon,wed") == "Monday and Wednesday at 8:00 AM")
    #expect(words("0 8 * * 7") == "Sunday at 8:00 AM")
    #expect(words("0 8 * * 0-6") == "Daily at 8:00 AM")
    #expect(words("0 8 * * 0-7") == "Daily at 8:00 AM")
    #expect(words("0 8 * * 6-7") == "Saturday and Sunday at 8:00 AM")
    #expect(words("") == "")
}
