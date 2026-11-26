import HermesBotUI
import HermesKit
import SwiftUI

/// The models offered in the picker, in the order shown, for what has been typed.
enum ModelList {
    struct Row: Identifiable, Equatable {
        /// Unique across the list: a featured model is listed again under its provider.
        let id: String
        let choice: ModelChoice
        /// Said on the right: the provider, where the section does not already say it.
        let detail: String
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        /// How many of the provider's models are listed. Nil for Featured.
        let count: Int?
        let rows: [Row]
    }

    /// With nothing typed: the gateway's featured models first, then every provider's.
    /// With words typed: the models whose name, or provider's name, holds every word, by
    /// provider. Capitals and accents make no difference.
    static func sections(_ options: ModelOptions, query: String) -> [Section] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var sections: [Section] = []
        if words.isEmpty {
            let featured = options.providers.flatMap { provider in
                provider.featured.map { Row(id: "featured \(provider.slug) \($0)", choice: ModelChoice(provider: provider.slug, model: $0), detail: provider.name) }
            }
            if !featured.isEmpty { sections.append(Section(id: "featured", title: "Featured", count: nil, rows: featured)) }
        }
        for provider in options.providers {
            let models = provider.models.filter { model in
                words.allSatisfy { "\(provider.name) \(model)".range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            guard !models.isEmpty else { continue }
            sections.append(Section(
                id: provider.slug, title: provider.name, count: models.count,
                rows: models.map { Row(id: "\(provider.slug) \($0)", choice: ModelChoice(provider: provider.slug, model: $0), detail: "") }))
        }
        return sections
    }

    /// The row to light: the one `id` names while it is still listed, else the bot's own
    /// model, else the first.
    static func lit(_ id: String?, current: ModelChoice?, in rows: [Row]) -> Row? {
        rows.first { $0.id == id } ?? rows.first { $0.choice == current } ?? rows.first
    }

    /// The row `step` away, stopping at the ends.
    static func step(_ step: Int, from id: String?, in rows: [Row]) -> Row? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return rows.first }
        return rows[min(max(index + step, 0), rows.count - 1)]
    }

    /// The model's name with the words typed in it in bold, as found.
    static func marked(_ model: String, words: [String]) -> AttributedString {
        var text = AttributedString(model)
        for word in words {
            guard let found = model.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]),
                  let start = AttributedString.Index(found.lowerBound, within: text),
                  let end = AttributedString.Index(found.upperBound, within: text)
            else { continue }
            text[start..<end].font = .system(size: 13, weight: .semibold)
        }
        return text
    }
}

/// Choosing the model a bot runs on: a search field over the models of the providers its
/// gateway is signed in to, featured ones first.
struct ModelPicker: View {
    let options: ModelOptions
    let current: ModelChoice?
    let choose: (ModelChoice) -> Void
    @State private var query = ""
    @State private var litID: String?
    /// The row to bring into sight, when the keyboard or typing chose it. Not the pointer:
    /// a row half in sight under it would jump.
    @State private var scrollTarget: String?
    /// Counts asks to scroll, so the same row asked for again is still brought into sight.
    @State private var scrollAsks = 0
    @FocusState private var isSearching: Bool
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 344

    private var total: Int { options.providers.reduce(0) { $0 + $1.models.count } }

    var body: some View {
        let theme = Theme(scheme)
        let sections = ModelList.sections(options, query: query)
        let rows = sections.flatMap(\.rows)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Words typed light the first found; with none, the bot's own model.
        let lit = ModelList.lit(litID, current: words.isEmpty ? current : nil, in: rows)
        // Ticked once, where it first comes: a second tick below reads as a second choice.
        let ticked = rows.first { $0.choice == current }?.id
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                TextField("Search \(total) models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .focused($isSearching)
                    .onSubmit { if let lit { choose(lit.choice) } }
                    .onKeyPress(.downArrow) { goTo(ModelList.step(1, from: lit?.id, in: rows)); return .handled }
                    .onKeyPress(.upArrow) { goTo(ModelList.step(-1, from: lit?.id, in: rows)); return .handled }
                    .accessibilityLabel("Search models")
                if !words.isEmpty {
                    Text("\(rows.count) found")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.hairline))
            .padding(8)

            if rows.isEmpty {
                Text("No models found")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                HStack {
                                    Text(section.title)
                                    Spacer()
                                    if let count = section.count { Text("\(count)").monospacedDigit() }
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                ForEach(section.rows) { row in
                                    self.row(row, isLit: row == lit, isTicked: row.id == ticked, words: words, theme)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: scrollAsks) {
                        if let scrollTarget { scroller.scrollTo(scrollTarget) }
                    }
                    .onAppear {
                        // Opens on the bot's own model, in sight.
                        if let lit { scroller.scrollTo(lit.id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // The app's own card colour, not the system's tinted material.
        .presentationBackground(theme.control)
        .onChange(of: query) {
            litID = nil
            // What is now lit (the first found, or with nothing typed the bot's own model),
            // brought into sight.
            let typed = !query.split(whereSeparator: \.isWhitespace).isEmpty
            scrollTarget = ModelList.lit(nil, current: typed ? nil : current, in: ModelList.sections(options, query: query).flatMap(\.rows))?.id
            scrollAsks += 1
        }
        .task {
            // Once the popover is on screen; sooner and the field does not take the caret.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            isSearching = true
        }
    }

    private func goTo(_ row: ModelList.Row?) {
        litID = row?.id
        scrollTarget = row?.id
        scrollAsks += 1
    }

    private func row(_ row: ModelList.Row, isLit: Bool, isTicked: Bool, words: [String], _ theme: Theme) -> some View {
        Button { choose(row.choice) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .opacity(isTicked ? 1 : 0)
                    .frame(width: 14)
                Text(ModelList.marked(row.choice.model, words: words))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(theme.chosen.opacity(isLit ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // The caret stays in the field, so typing and the arrow keys always work.
        .focusable(false)
        // The pointer lights a row as the arrow keys do, so only one is ever lit.
        .onHover { if $0 { litID = row.id } }
        .id(row.id)
        .accessibilityLabel(row.detail.isEmpty ? row.choice.model : "\(row.choice.model), \(row.detail)")
        .accessibilityAddTraits(isTicked ? .isSelected : [])
    }
}

extension ReasoningLevel {
    /// The level in words.
    var title: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }

    /// The levels to offer for a model, with the bot's own among them when it is one
    /// outside the usual ones (Off only where the model's thinking can be turned off).
    static func choices(for capabilities: ModelCapabilities, keeping current: ReasoningLevel?) -> [ReasoningLevel] {
        var levels = offered.filter { $0 != .off || capabilities.canTurnOffReasoning }
        if let current, current != .off, !levels.contains(current) {
            levels.append(current)
            levels.sort { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
        }
        return levels
    }
}
