import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Choosing a bot's model and how hard it thinks, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ModelTests {
    private func open(_ pretend: SendingTests.Pretend) async -> RosterModel {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        return roster
    }

    @Test func onlySignedInProvidersAreOfferedWithWhatEachModelCanDo() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let options = try #require(await roster.modelOptions(for: garden))
        #expect(options.providers.map(\.slug) == ["northwind", "lumen", "relay"])
        #expect(options.current == ModelChoice(provider: "northwind", model: "orbit-mini"))
        // A model its provider says is not to be had is not offered.
        #expect(options.providers.last?.models.contains("kite/vision-20") == false)
        let max = try #require(options.capabilities(of: ModelChoice(provider: "northwind", model: "orbit-max")))
        #expect(max.reasoning && !max.canTurnOffReasoning)
        #expect(options.capabilities(of: ModelChoice(provider: "northwind", model: "orbit-lite"))?.reasoning == false)
        // A model the gateway says nothing about is not taken to think.
        #expect(options.capabilities(of: ModelChoice(provider: "relay", model: "acme/chat-1")) == nil)
    }

    @Test func aModelIsSavedOnTheBotAndShownFromTheGateway() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.setModel(ModelChoice(provider: "lumen", model: "lumen-6"), for: garden) == .saved)
        #expect(roster.bots.first { $0.name == "garden" }?.model == "lumen-6")
        // The bot's, not the main one's.
        #expect(roster.mainBot?.model == "orbit-mini")
        let again = await open(pretend)
        #expect(again.bots.first { $0.name == "garden" }?.model == "lumen-6")
    }

    /// Changed on another device, or in Hermes's own app, while this app's roster still holds
    /// the old model: the pane goes by what the gateway says when it opens.
    @Test func aModelChangedElsewhereIsShownAndTheOldOneCanBeChosenAgain() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let elsewhere = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await elsewhere.setModel(ModelChoice(provider: "lumen", model: "lumen-6"), for: garden) == .saved)
        // Not read again here: nothing tells this app the bot changed.
        let held = try #require(roster.bots.first { $0.name == "garden" })
        #expect(held.model == "orbit-mini")

        let read = try #require(await roster.modelsRead(for: garden))
        let shown = DetailsPanel.savedModel(held: held, models: read.options, readIsNewest: roster.modelSaves(of: garden) == read.savesBefore)
        let lumen = ModelChoice(provider: "lumen", model: "lumen-6")
        #expect(shown == lumen)
        // What the newer model can do is what decides the Reasoning row.
        #expect(read.options.capabilities(of: try #require(shown))?.canTurnOffReasoning == true)

        // The old one is a change, and is saved.
        let mini = ModelChoice(provider: "northwind", model: "orbit-mini")
        #expect(mini != shown)
        #expect(await roster.setModel(mini, for: garden) == .saved)
        // Saved here after the list was read: the roster holds the newer word.
        let after = DetailsPanel.savedModel(
            held: try #require(roster.bots.first { $0.name == "garden" }), models: read.options,
            readIsNewest: roster.modelSaves(of: garden) == read.savesBefore)
        #expect(after == mini)
        // Nor does the older read come back where the roster has no full word on the bot.
        let unnamed = try JSONDecoder().decode(Bot.self, from: Data(#"{"name":"garden"}"#.utf8))
        #expect(DetailsPanel.savedModel(held: unnamed, models: read.options, readIsNewest: false) == nil)
        #expect(DetailsPanel.savedModel(held: unnamed, models: read.options, readIsNewest: true) == lumen)
        #expect(await open(pretend).bots.first { $0.name == "garden" }?.model == "orbit-mini")
    }

    @Test func aCostlyModelWaitsForThePersonToAgree() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let costly = ModelChoice(provider: "northwind", model: "orbit-max")
        guard case .needsConfirming(let said) = await roster.setModel(costly, for: garden) else {
            Issue.record("Saved without asking")
            return
        }
        #expect(said.contains("five times"))
        // Nothing was saved yet.
        #expect(roster.bots.first { $0.name == "garden" }?.model == "orbit-mini")
        #expect(await roster.setModel(costly, for: garden, confirmed: true) == .saved)
        #expect(roster.bots.first { $0.name == "garden" }?.model == "orbit-max")
    }

    @Test func aModelTheGatewayDidNotSaveIsAFailure() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        // A provider the gateway is not signed in to: it answers, and says it saved nothing.
        let outcome = await roster.setModel(ModelChoice(provider: "nimbus", model: "nimbus-1"), for: garden)
        #expect(outcome == .failed(GatewayClient.modelNotSaved))
        #expect(roster.bots.first { $0.name == "garden" }?.model == "orbit-mini")
    }

    @Test func reasoningIsReadAndSavedOnTheBot() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let main = try #require(roster.mainBot)
        #expect(await roster.reasoning(of: garden) == .medium)
        #expect(await roster.setReasoning(.xhigh, for: garden) == nil)
        #expect(await roster.reasoning(of: garden) == .xhigh)
        #expect(await roster.reasoning(of: main) == .medium)
        #expect(await roster.setReasoning(.off, for: garden) == nil)
        #expect(await open(pretend).reasoning(of: garden) == .off)
    }

    @Test func reasoningFixedByAnAdministratorSaysSoPlainly() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let books = try #require(roster.bots.first { $0.name == "books" })
        let trouble = try #require(await roster.setReasoning(.high, for: books))
        #expect(trouble.contains("administrator"))
        #expect(!roster.cannotSetReasoning)
    }

    @Test func aGatewayWithoutModelsHidesTheControlsAndStopsAsking() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-models")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.modelOptions(for: garden) == nil)
        #expect(roster.cannotPickModel)
        #expect(await roster.reasoning(of: garden) == nil)
        #expect(roster.cannotSetReasoning)
        // The model is still there to show as words.
        #expect(garden.model == "orbit-mini")
    }

    /// Hermes before 0.21.6 reads and writes the main bot's settings whichever is named.
    @Test func reasoningIsNotOfferedWhereItWouldChangeTheMainBot() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "unscoped")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.reasoning(of: garden) == nil)
        #expect(roster.cannotSetReasoning)
        // The model is still offered: it is saved by the bot's name, which every gateway keeps to.
        // But the list's word on which is the bot's is the main bot's there, so it is left out.
        let options = try #require(await roster.modelOptions(for: garden))
        #expect(options.current == nil)
    }

    @Test func reasoningIsNotOfferedWhereTheSessionAuthorityHandlesChats() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.reasoning(of: garden) == nil)
        #expect(roster.cannotSetReasoning)
    }

    @Test func aPaneOpenedDuringASaveReadsWhatItSaved() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let saving = Task { await roster.setReasoning(.high, for: garden) }
        let modelSaving = Task { await roster.setModel(ModelChoice(provider: "lumen", model: "lumen-6"), for: garden) }
        // Asked at once, as a pane reopened straight away does: read after the saves.
        await Task.yield()
        #expect(await roster.reasoning(of: garden) == .high)
        #expect(await roster.modelOptions(for: garden)?.current == ModelChoice(provider: "lumen", model: "lumen-6"))
        #expect(await saving.value == nil)
        #expect(await modelSaving.value == .saved)
    }

    @Test func theListPutsFeaturedFirstAndFindsAcrossProviders() {
        let options = ModelOptions(providers: [
            .init(slug: "northwind", name: "Northwind", models: ["orbit-mini", "orbit-max"], featured: ["orbit-max"]),
            .init(slug: "relay", name: "Relay", models: ["kite/orbit-clone", "zephyr/chat"]),
        ], current: ModelChoice(provider: "northwind", model: "orbit-mini"))
        let all = ModelList.sections(options, query: "")
        #expect(all.map(\.title) == ["Featured", "Northwind", "Relay"])
        #expect(all[0].rows.map(\.detail) == ["Northwind"])
        // Every row can be told apart, though a featured one is listed twice.
        let ids = all.flatMap(\.rows).map(\.id)
        #expect(Set(ids).count == ids.count)
        let found = ModelList.sections(options, query: "ORBIT  m")
        #expect(found.map(\.title) == ["Northwind"])
        #expect(found[0].rows.map(\.choice.model) == ["orbit-mini", "orbit-max"])
        // The provider's name counts as a word too.
        #expect(ModelList.sections(options, query: "relay zephyr").flatMap(\.rows).map(\.choice.model) == ["zephyr/chat"])
        #expect(ModelList.sections(options, query: "nothing like it").isEmpty)
        let rows = all.flatMap(\.rows)
        #expect(ModelList.lit(nil, current: options.current, in: rows)?.choice == options.current)
        #expect(ModelList.step(-1, from: rows.first?.id, in: rows) == rows.first)
    }

    @Test func offIsOfferedOnlyWhereThinkingCanBeTurnedOff() {
        let either = ModelCapabilities(reasoning: true, canTurnOffReasoning: true)
        let always = ModelCapabilities(reasoning: true, canTurnOffReasoning: false)
        #expect(ReasoningLevel.choices(for: either, keeping: .medium) == [.off, .low, .medium, .high, .xhigh])
        #expect(ReasoningLevel.choices(for: always, keeping: .medium) == [.low, .medium, .high, .xhigh])
        // A level the bot already has is kept among them, in its place; Off only where it can be had.
        #expect(ReasoningLevel.choices(for: always, keeping: .minimal) == [.minimal, .low, .medium, .high, .xhigh])
        #expect(ReasoningLevel.choices(for: always, keeping: .off) == [.low, .medium, .high, .xhigh])
        #expect(ReasoningLevel(word: "False") == .off)
        #expect(ReasoningLevel(word: "hgih") == nil)
    }
}
