import Testing
@testable import HermesBot

@Suite struct SearchTests {
    private let bots = [
        Palette.Entry(id: "default", title: "Hermes", preview: "Anytime."),
        Palette.Entry(id: "garden", title: "Garden", preview: "After your last frost, in May."),
        Palette.Entry(id: "cafe", title: "Café Orders", preview: "The bakery order moved to Friday."),
    ]

    @Test func nothingTypedShowsEverything() {
        let found = Palette.items(for: "  ", bots: bots)
        #expect(found.bots == [.bot("default"), .bot("garden"), .bot("cafe")])
        #expect(found.actions == [.newBot, .rename, .details, .settings])
    }

    @Test func botsAreFoundByNameFirstThenByWhatWasLastSaid() {
        // "fr" is in nobody's name; it is in what two bots last said.
        #expect(Palette.items(for: "fr", bots: bots).bots == [.bot("garden"), .bot("cafe")])
        #expect(Palette.items(for: "gar", bots: bots).bots == [.bot("garden")])
        // "gard" names Garden and is in what another bot last said: the one named comes first.
        let more = bots + [Palette.Entry(id: "tools", title: "Tools", preview: "The garden shed is tidy.")]
        #expect(Palette.items(for: "gard", bots: [more[3]] + bots).bots == [.bot("garden"), .bot("tools")])
        // Capitals and accents make no difference, and every word must answer.
        #expect(Palette.items(for: "CAFE", bots: bots).bots == [.bot("cafe")])
        #expect(Palette.items(for: "cafe friday", bots: bots).bots == [.bot("cafe")])
        #expect(Palette.items(for: "cafe frost", bots: bots).bots.isEmpty)
    }

    @Test func actionsAnswerToTheirNamesAndNewBotOnlyWhereBotsCanBeMade() {
        #expect(Palette.items(for: "set", bots: bots).actions == [.settings])
        #expect(Palette.items(for: "bot", bots: bots).actions == [.newBot, .rename, .details])
        #expect(Palette.items(for: "bot", bots: bots, offer: Palette.Offer(canMakeBots: false)).actions == [.rename, .details])
        // With no bot showing there is none to rename or see the details of.
        #expect(Palette.items(for: "", bots: [], offer: Palette.Offer(hasBot: false)).actions == [.newBot, .settings])
        #expect(Palette.items(for: "", bots: bots, offer: Palette.Offer(canRename: false)).actions == [.newBot, .details, .settings])
        // The details action says what it will do.
        #expect(Palette.items(for: "hide", bots: bots, offer: Palette.Offer(showsDetails: true)).actions == [.details])
        #expect(Palette.items(for: "hide", bots: bots).actions.isEmpty)
        #expect(Palette.items(for: "zzz", bots: bots).actions.isEmpty)
    }

    @Test func aBotAlsoAnswersToItsNameOnTheGateway() {
        let renamed = [Palette.Entry(id: "meal-plans", title: "Suppers", preview: "", also: "meal-plans Plans the week's dinners")]
        #expect(Palette.items(for: "meal", bots: renamed).bots == [.bot("meal-plans")])
        #expect(Palette.items(for: "dinners", bots: renamed).bots == [.bot("meal-plans")])
    }

    @Test func theChoiceStaysOnItsItemWhenTheListChangesUnderIt() {
        let before: [PaletteItem] = [.bot("a"), .bot("b"), .settings]
        // Nothing chosen yet: the first is lit, and Down goes to the second.
        #expect(Palette.chosen(nil, in: before) == .bot("a"))
        #expect(Palette.step(1, from: nil, in: before) == .bot("b"))
        #expect(Palette.step(-1, from: nil, in: before) == .settings)
        #expect(Palette.step(1, from: PaletteItem.settings.id, in: before) == .bot("a"))
        // A bot arrives above it, or one goes: the choice is still Settings.
        #expect(Palette.chosen(PaletteItem.settings.id, in: [.bot("z")] + before) == .settings)
        #expect(Palette.chosen(PaletteItem.settings.id, in: [.bot("b"), .settings]) == .settings)
        // What was chosen has gone: the first, never whatever took its place.
        #expect(Palette.chosen(PaletteItem.bot("b").id, in: [.bot("a"), .settings]) == .bot("a"))
        #expect(Palette.chosen("x", in: []) == nil)
        #expect(Palette.step(1, from: nil, in: []) == nil)
    }
}
