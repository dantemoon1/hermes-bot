import Foundation

/// The time stamp between messages: "Today 2:46 PM", or "Fri, Nov 20 10:40 AM".
public enum ChatDate {
    public static func text(for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        timeStyle.calendar = calendar
        timeStyle.timeZone = calendar.timeZone
        let time = date.formatted(timeStyle)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        var day = Date.FormatStyle(locale: locale).weekday(.abbreviated).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        return "\(date.formatted(day)) \(time)"
    }
}

/// The quiet line for a run of tool work: "Used calendar and weather".
public enum ToolSummary {
    public static func text(for tools: [String]) -> String {
        var names: [String] = []
        for tool in tools.map({ $0.replacingOccurrences(of: "_", with: " ") }) where !names.contains(tool) {
            names.append(tool)
        }
        var listed = Array(names.prefix(3))
        if names.count > listed.count { listed.append("\(names.count - listed.count) more") }
        return "Used \(listed.formatted(.list(type: .and).locale(Locale(identifier: "en_US"))))"
    }
}

/// When a routine runs, in words, from the five cron fields the gateway holds.
public enum RoutineSchedule {
    /// Common schedules read plainly; anything else is shown as the gateway wrote it,
    /// rather than guessed at.
    public static func text(for schedule: String, locale: Locale = .current) -> String {
        let fields = schedule.split(separator: " ").map(String.init)
        if let interval = interval(fields) { return interval }
        guard fields.count == 5 else { return schedule }
        let (minute, hour, day, month) = (fields[0], fields[1], fields[2], fields[3])
        guard day == "*", month == "*" else { return schedule }
        // Days as numbers, Sunday 0, whether written as numbers, names, a list or a range.
        guard let days = weekdays(fields[4]) else { return schedule }
        let everyDay = days.count == 7

        if hour == "*", everyDay {
            if minute == "*" { return "Every minute" }
            if minute.hasPrefix("*/"), let every = Int(minute.dropFirst(2)), (1..<60).contains(every) {
                return every == 1 ? "Every minute" : "Every \(every) minutes"
            }
            if let minute = Int(minute), (0..<60).contains(minute) { return "Every hour" }
            return schedule
        }
        if minute == "0", hour.hasPrefix("*/"), let every = Int(hour.dropFirst(2)), (1..<24).contains(every), everyDay {
            return every == 1 ? "Every hour" : "Every \(every) hours"
        }
        guard let minute = Int(minute), (0..<60).contains(minute) else { return schedule }
        let hours = hour.split(separator: ",").compactMap { Int($0) }
        guard !hours.isEmpty, hours.count == hour.split(separator: ",").count, hours.allSatisfy({ (0..<24).contains($0) }) else { return schedule }
        let times = hours.map { time($0, minute, locale) }.formatted(.list(type: .and).locale(locale))

        if everyDay { return "Daily at \(times)" }
        if days == [1, 2, 3, 4, 5] { return "Weekdays at \(times)" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = days.map { calendar.weekdaySymbols[$0] }.formatted(.list(type: .and).locale(locale))
        return "\(names) at \(times)"
    }

    /// Hermes's own short way of writing a repeat: `every 30m`, `every 2h`, `every 1d`.
    private static func interval(_ fields: [String]) -> String? {
        guard fields.count == 2, fields[0].lowercased() == "every", let unit = fields[1].last,
              let count = Int(fields[1].dropLast()), count > 0 else { return nil }
        let word: String
        switch unit {
        case "m": word = "minute"
        case "h": word = "hour"
        case "d": word = "day"
        default: return nil
        }
        return count == 1 ? "Every \(word)" : "Every \(count) \(word)s"
    }

    /// The days a cron weekday field names, in the order written, or nil when it is not
    /// one this reads. `*` is all seven.
    private static func weekdays(_ field: String) -> [Int]? {
        if field == "*" { return Array(0..<7) }
        let named = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]
        func day(_ text: Substring) -> Int? {
            // Sunday is 0, and also 7 so that a week can be written Monday to Sunday.
            if let number = Int(text) { return (0...7).contains(number) ? number : nil }
            return named[text.uppercased()]
        }
        var days: [Int] = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            if ends.count == 1, let one = day(ends[0]) {
                days.append(one)
            } else if ends.count == 2, let first = day(ends[0]), let last = day(ends[1]), first <= last {
                days.append(contentsOf: first...last)
            } else {
                return nil
            }
        }
        var seen = Set<Int>()
        days = days.map { $0 % 7 }.filter { seen.insert($0).inserted }
        return days.isEmpty ? nil : days
    }

    private static func time(_ hour: Int, _ minute: Int, _ locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? .distantPast
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        style.locale = locale
        return date.formatted(style)
    }
}
