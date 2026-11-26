import HermesBotUI
import HermesKit
import SwiftUI

/// Everything about a bot beyond its chat, in a pane beside the chat.
struct DetailsPanel: View {
    let bot: Bot
    let roster: RosterModel
    /// Counts asks to rename. One this pane has not yet answered puts the caret in the name.
    let renameAsks: Int
    @Binding var renamesAnswered: Int
    let close: () -> Void
    @State private var name: String
    /// The name as last asked for, so leaving the field and closing the pane ask once.
    @State private var asked: String
    @State private var look: AvatarLook
    /// The face as last asked for, as `asked` is for the name.
    @State private var askedLook: AvatarLook
    /// Saves of the name and of the face still on their way.
    @State private var namesSaving = 0
    /// Counts renames asked for, to tell the latest from an earlier one for the same name.
    @State private var renames = 0
    @State private var looksSaving = 0
    @State private var isPickingFace = false
    @State private var isOverFace = false
    @State private var isOverName = false
    @State private var routines: [Routine]?
    @State private var problem: String?
    /// The models the bot could run on. Nil until read, and when there are none to offer:
    /// the model is then shown as words, as before it could be chosen.
    @State private var models: ModelOptions?
    /// How many model saves of this app's had been made when `models` was asked for.
    @State private var modelSavesAtRead = 0
    /// A model chosen here and not yet known to be refused: on its way, or saved and not
    /// yet read back from the gateway.
    @State private var chosenModel: ModelChoice?
    /// How hard the bot thinks as last read or saved, and as chosen here and on its way.
    @State private var savedReasoning: ReasoningLevel?
    @State private var chosenReasoning: ReasoningLevel?
    /// Saves of the model and of reasoning still on their way.
    @State private var modelsSaving = 0
    @State private var reasoningsSaving = 0
    @State private var isPickingModel = false
    /// A model Hermes wants the person to agree to before it is saved.
    @State private var confirming: Confirming?
    /// What went wrong saving the model or reasoning, said under the Connection card.
    @State private var settingProblem: String?
    /// Count the choices of model and of reasoning, so only the latest says how it went.
    @State private var modelChoices = 0
    @State private var reasoningChoices = 0
    @FocusState private var isNaming: Bool
    /// The line saying what the bot is for, kept as the name is: as typed, as last asked
    /// for, and how many saves of it are on their way.
    @State private var about: String
    @State private var askedAbout: String
    @State private var aboutsSaving = 0
    @State private var describes = 0
    @State private var isOverAbout = false
    @FocusState private var isDescribing: Bool
    /// The bot's soul as shown: last read, saved, or on its way. Nil until read, and if it can't be.
    @State private var soul: String?
    /// The soul the gateway is known to hold, which a failed save goes back to.
    @State private var savedSoul: String?
    /// The soul being written, while the card is open for writing.
    @State private var draftSoul: String?
    @State private var soulSaves = 0
    @State private var soulNote: String?
    @State private var isOverSoul = false
    @FocusState private var isWritingSoul: Bool
    @State private var usage: ChatUsage?
    /// Counts reads of the usage, so only the latest is shown.
    @State private var usageReads = 0
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 300

    /// Counts asks to open the model picker, as `renameAsks` does for the name.
    let modelAsks: Int
    @Binding var modelAsksAnswered: Int
    /// The models have been asked for, whatever came of it.
    @State private var modelsAsked = false
    /// An ask to open the model picker, taken by this pane and waiting for the models.
    @State private var picksWhenRead = false

    init(
        bot: Bot, roster: RosterModel, renameAsks: Int, renamesAnswered: Binding<Int>,
        modelAsks: Int = 0, modelAsksAnswered: Binding<Int> = .constant(0), close: @escaping () -> Void
    ) {
        self.bot = bot
        self.roster = roster
        self.renameAsks = renameAsks
        _renamesAnswered = renamesAnswered
        self.modelAsks = modelAsks
        _modelAsksAnswered = modelAsksAnswered
        self.close = close
        // Known from the first frame, so the pane never opens on a blank name or the wrong face.
        _name = State(initialValue: bot.title)
        _asked = State(initialValue: bot.title)
        _look = State(initialValue: roster.look(for: bot))
        _askedLook = State(initialValue: roster.look(for: bot))
        _about = State(initialValue: bot.description)
        _askedAbout = State(initialValue: bot.description)
    }

    var body: some View {
        let theme = Theme(scheme)
        ScrollView {
            VStack(spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.2)) { isPickingFace.toggle() } } label: {
                    BotAvatar(look, size: 64, isWorking: roster.isWorking(bot))
                        .avatarsFollowPointer()
                        .scaleEffect(isOverFace ? 1.05 : 1)
                        .animation(.easeOut(duration: 0.15), value: isOverFace)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!roster.cannotEditBots)
                .accessibilityHidden(roster.cannotEditBots)
                .onHover { isOverFace = $0 && !roster.cannotEditBots }
                .accessibilityLabel("Change face")
                .help("Change face")

                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .focused($isNaming)
                    .onSubmit { isNaming = false }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    // A sign that the name can be typed over.
                    .background(theme.bubble.opacity(isOverName || isNaming ? 1 : 0), in: RoundedRectangle(cornerRadius: 8))
                    .onHover { isOverName = $0 && !roster.cannotEditBots }
                    // Still there to read and copy, but not to type over.
                    .allowsHitTesting(!roster.cannotEditBots)
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
                    .accessibilityLabel("Bot name")

                // Under the name and kept the same way. Left out when there is none and
                // none can be given.
                if !roster.cannotEditBots || !about.isEmpty {
                    TextField("Add a description", text: $about)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .focused($isDescribing)
                        .onSubmit { isDescribing = false }
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(theme.bubble.opacity(isOverAbout || isDescribing ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
                        .onHover { isOverAbout = $0 && !roster.cannotEditBots }
                        .allowsHitTesting(!roster.cannotEditBots)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .accessibilityLabel("Bot description")
                }

                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                if isPickingFace {
                    FacePicker(look: $look, isCompact: true)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(theme.control, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.hairline))
                        .padding(.top, 14)
                        .transition(.opacity)
                }

                // Left out when there is none and none can be given.
                if let soul, !roster.cannotEditBots || !Self.trimmed(soul).isEmpty || draftSoul != nil {
                    section("Personality", theme)
                    personality(soul, theme)
                    if let soulNote {
                        Text(soulNote)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                    }
                }

                section("Suggested", theme)
                card(theme) {
                    WhenHovered { isHovered in
                    Button {
                        // As the reference does: the question goes in the composer, to send or
                        // change. Words already there are the person's and stay.
                        roster.chat(for: bot).suggest("What's a routine and how do I set one up?")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.secondaryText)
                            Text("Create a routine")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(theme.hover.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    }
                    .buttonStyle(.plain)
                }

                if let routines, !routines.isEmpty {
                    section("Routines", theme)
                    card(theme) {
                        VStack(spacing: 0) {
                            ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
                                if index > 0 { theme.hairline.frame(height: 1).padding(.leading, 14) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.name)
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(2)
                                        // Stepped back, while when it would run stays readable.
                                        .opacity(routine.isEnabled ? 1 : 0.55)
                                    Text(Self.when(routine))
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                }

                section("Connection", theme)
                card(theme) {
                    VStack(spacing: 0) {
                        row("Gateway", roster.gatewayName ?? "", theme)
                        if let models, !roster.cannotPickModel {
                            theme.hairline.frame(height: 1).padding(.leading, 14)
                            modelRow(shownModel, models, theme)
                            if let shown = shownModel, let capabilities = models.capabilities(of: shown), capabilities.reasoning,
                               let reasoning = chosenReasoning ?? savedReasoning, !roster.cannotSetReasoning {
                                theme.hairline.frame(height: 1).padding(.leading, 14)
                                reasoningRow(reasoning, capabilities, theme)
                            }
                        } else if let model = bot.model, !model.isEmpty {
                            theme.hairline.frame(height: 1).padding(.leading, 14)
                            row("Model", model, theme)
                        }
                    }
                }
                if let note = modelsSaving + reasoningsSaving > 0 ? "Saving…"
                    : settingProblem ?? (models != nil && !roster.cannotPickModel ? "Saved on \(bot.title)" : nil) {
                    // That a choice here lasts, and is the bot's; that it is on its way; or why
                    // it didn't stay, even where the control has gone because of it.
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                }

                if let usage, usage.contextFraction != nil || usage.tokens != nil {
                    section("Usage", theme)
                    card(theme) { usageRows(usage, theme) }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 60)
            .padding(.bottom, 20)
            // Being deleted: nothing more about it can be changed.
            .opacity(isGoing ? 0.4 : 1)
            .disabled(isGoing)
        }
        // Over the top of what scrolls, as the name floats over the chat.
        .overlay(alignment: .topTrailing) {
            WhenHovered { isHovered in
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text)
                        .frame(width: 34, height: 34)
                        .background(isHovered ? theme.controlHover : theme.control, in: Circle())
                        .overlay(Circle().strokeBorder(theme.hairline))
                        .shadow(color: theme.floatShadow, radius: 6, y: 2)
                        .contentShape(Circle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
            .help("Close")
            .padding(.top, 13)
            .padding(.trailing, 13)
        }
        .frame(width: Self.width)
        .background(theme.canvas)
        .task {
            if renameAsks != renamesAnswered {
                // Answered now, so no other pane takes the ask if this one goes first.
                renamesAnswered = renameAsks
                // Once the pane has slid in; sooner and the field does not take the caret.
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                isNaming = true
            }
            if let read = await roster.personality(of: bot) {
                // Read as the gateway holds it, unless something was written meanwhile.
                if soul == nil { (soul, savedSoul) = (read.soul, read.soul) }
                // A soul whose save failed after its pane had gone is offered back to write.
                if draftSoul == nil, !roster.cannotEditBots, let unsaved = roster.unsavedSouls[bot.id] {
                    draftSoul = unsaved
                    soulNote = "This wasn't saved."
                }
                if describes == 0, !isDescribing, about == askedAbout, about == bot.description {
                    (about, askedAbout) = (read.description, read.description)
                }
            }
            routines = await roster.routines(of: bot)
        }
        .task {
            // Taken now, not once the models come: a pane closed meanwhile leaves no ask to
            // open the picker by surprise in the next.
            takeModelAsk()
            // Beside the routines, not after them: either can be slow.
            async let models = roster.modelsRead(for: bot)
            async let reasoning = roster.reasoning(of: bot)
            let (read, level) = await (models, reasoning)
            (self.models, self.modelSavesAtRead, self.savedReasoning) = (read?.options, read?.savesBefore ?? 0, level)
            modelsAsked = true
            if picksWhenRead { openModelPicker() }
        }
        .onChange(of: modelAsks) {
            takeModelAsk()
            if modelsAsked, picksWhenRead { openModelPicker() }
        }
        // Saved from the message box (`/reasoning high`) while this pane is open.
        .onChange(of: roster.reasoningSaved[bot.id]) { _, saved in
            if let saved, reasoningsSaving == 0 { savedReasoning = saved }
        }
        .alert(
            confirming.map { "Switch \(bot.title) to \($0.choice.model)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { asked in
            // Cancel is what Return does: a quick keypress never agrees to a costlier model.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Switch Model") { switchModel(to: asked.choice, confirmed: true) }
        } message: { asked in
            Text([asked.message, "This is saved on \(bot.title)."]
                .filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        .task { readUsage() }
        .onChange(of: roster.isWorking(bot)) {
            // A turn of this app's has ended: the chat holds more now.
            if !roster.isWorking(bot) { readUsage() }
        }
        .onChange(of: bot.chat?.lastActive) {
            // The chat moved on, from here or anywhere else.
            readUsage()
        }
        .onChange(of: renameAsks) { startRenaming() }
        .onChange(of: roster.cannotEditBots) {
            // Found out by trying: the picker and the caret go, the note stays.
            isPickingFace = false
            isNaming = false
            isDescribing = false
            draftSoul = nil
        }
        .onChange(of: isDescribing) {
            if !isDescribing { describe() }
        }
        .onChange(of: isNaming) {
            // Leaving the field keeps the new name; an empty one goes back to what it was.
            if !isNaming { rename() }
        }
        // So does closing the pane or turning to another bot with a name half typed.
        .onDisappear {
            rename()
            describe()
            saveSoul()
        }
        .onChange(of: bot.description) { old, new in
            // Changed from somewhere else, with nothing of this pane's typed or on its way.
            if aboutsSaving == 0, about == old, askedAbout == old { (about, askedAbout) = (new, new) }
        }
        .onChange(of: bot.title) { old, new in
            // Renamed from somewhere else while this is open, with nothing of this pane's
            // typed or on its way.
            if namesSaving == 0, name == old, asked == old { (name, asked) = (new, new) }
        }
        .onChange(of: roster.look(for: bot)) { old, new in
            // The same for the face, as when a save begun before this pane opened lands.
            if looksSaving == 0, look == old, askedLook == old { (look, askedLook) = (new, new) }
        }
        .onChange(of: look) {
            guard look != askedLook else { return }
            let chosen = look
            askedLook = chosen
            looksSaving += 1
            Task {
                let trouble = await roster.update(bot, look: chosen)
                looksSaving -= 1
                // A newer choice is not put back because an older one failed.
                guard askedLook == chosen else { return }
                problem = trouble
                if trouble != nil {
                    askedLook = roster.look(for: bot)
                    look = askedLook
                }
            }
        }
    }

    private var isGoing: Bool { roster.deleting.contains(bot.id) }

    private func takeModelAsk() {
        guard modelAsks != modelAsksAnswered else { return }
        modelAsksAnswered = modelAsks
        picksWhenRead = true
    }

    /// Opens the model picker as asked, once the models are read. Where there are none to
    /// choose from the model shows as words, as without the ask.
    private func openModelPicker() {
        picksWhenRead = false
        guard models != nil, !roster.cannotPickModel, !isGoing else { return }
        Task {
            // Once the pane has slid in; a popover asked for sooner is not shown.
            try? await Task.sleep(for: .milliseconds(300))
            isPickingModel = true
        }
    }

    struct Confirming: Equatable {
        let choice: ModelChoice
        let message: String
    }

    private var savedModel: ModelChoice? {
        Self.savedModel(
            held: roster.bots.first { $0.id == bot.id } ?? bot, models: models,
            readIsNewest: roster.modelSaves(of: bot) == modelSavesAtRead)
    }

    /// The model the bot runs on as the gateway last said. The list of models was read when
    /// the pane opened, and what it names as the bot's wins over the roster, which may not
    /// have been read since the bot was changed elsewhere; unless this app has saved a model
    /// since that read (`readIsNewest` false), which the roster then holds.
    static func savedModel(held: Bot, models: ModelOptions?, readIsNewest: Bool) -> ModelChoice? {
        if readIsNewest, let current = models?.current { return current }
        if let model = held.model, !model.isEmpty, let provider = held.provider, !provider.isEmpty {
            let choice = ModelChoice(provider: provider, model: model)
            return models?.listed(choice) ?? choice
        }
        // A read made before this app's own save is not the bot's word any longer.
        return readIsNewest ? models?.current : nil
    }

    /// The model the row shows: as chosen here, or else as saved.
    private var shownModel: ModelChoice? { chosenModel ?? savedModel }

    private func modelRow(_ shown: ModelChoice?, _ models: ModelOptions, _ theme: Theme) -> some View {
        // A bot whose settings name no provider can still be given a model.
        let value = shown?.model ?? (bot.model.flatMap { $0.isEmpty ? nil : $0 } ?? "Choose")
        return WhenHovered { isHovered in
            Button { isPickingModel.toggle() } label: {
                HStack(spacing: 12) {
                    Text("Model")
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        Text(value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(theme.hover.opacity(isHovered || isPickingModel ? 1 : 0))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(value)
        .help("Choose the model \(bot.title) runs on")
        .popover(isPresented: $isPickingModel, arrowEdge: .leading) {
            ModelPicker(options: models, current: shown) { choice in
                isPickingModel = false
                switchModel(to: choice, confirmed: false)
            }
        }
    }

    private func reasoningRow(_ level: ReasoningLevel, _ capabilities: ModelCapabilities, _ theme: Theme) -> some View {
        WhenHovered { isHovered in
            Menu {
                ForEach(ReasoningLevel.choices(for: capabilities, keeping: level), id: \.self) { choice in
                    Toggle(choice.title, isOn: Binding(get: { choice == level }, set: { if $0 { think(choice) } }))
                }
            } label: {
                HStack(spacing: 12) {
                    Text("Reasoning")
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        Text(level.title)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 40)
                // A control waiting does not answer the pointer.
                .background(theme.hover.opacity(isHovered && modelsSaving == 0 ? 1 : 0))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // Not while a model is on its way: what it can do is not settled until then.
            .disabled(modelsSaving > 0)
            .accessibilityLabel("Reasoning")
            .accessibilityValue(level.title)
            .help("How hard \(bot.title) thinks before answering")
        }
    }

    /// Saves the model chosen, showing it at once and going back if it isn't saved.
    private func switchModel(to choice: ModelChoice, confirmed: Bool) {
        guard confirmed || choice != shownModel else { return }
        chosenModel = choice
        settingProblem = nil
        modelChoices += 1
        modelsSaving += 1
        let this = modelChoices
        Task {
            let outcome = await roster.setModel(choice, for: bot, confirmed: confirmed)
            modelsSaving -= 1
            // A later choice says how it went for itself. What an earlier one saved shows
            // through the roster, which is read again after every save.
            guard modelChoices == this else { return }
            switch outcome {
            case .saved:
                // Shown from the roster once it has it, so a change made elsewhere later shows too.
                if savedModel == choice { chosenModel = nil }
            case .needsConfirming(let said):
                chosenModel = nil
                // Not while the picker is still going: an alert asked for then is never shown.
                try? await Task.sleep(for: .milliseconds(400))
                guard modelChoices == this else { return }
                confirming = Confirming(choice: choice, message: said)
            case .failed(let trouble):
                chosenModel = nil
                settingProblem = trouble
            }
        }
    }

    /// Saves how hard the bot thinks, showing it at once and going back if it isn't saved.
    private func think(_ level: ReasoningLevel) {
        guard level != (chosenReasoning ?? savedReasoning) else { return }
        chosenReasoning = level
        settingProblem = nil
        reasoningChoices += 1
        reasoningsSaving += 1
        let this = reasoningChoices
        Task {
            let trouble = await roster.setReasoning(level, for: bot)
            reasoningsSaving -= 1
            // Saves go one at a time and in order, so the last one saved is the bot's.
            if trouble == nil { savedReasoning = level }
            guard reasoningChoices == this else { return }
            chosenReasoning = nil
            settingProblem = trouble
        }
    }

    /// The bot's name as the roster has it now, which is the last one known to be saved.
    private var savedTitle: String { roster.bots.first { $0.id == bot.id }?.title ?? bot.title }

    private func startRenaming() {
        renamesAnswered = renameAsks
        isNaming = true
    }

    private func rename() {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted != asked, !isGoing, !roster.cannotEditBots else {
            name = asked
            return
        }
        (name, asked) = (wanted, wanted)
        namesSaving += 1
        renames += 1
        let this = renames
        Task {
            let trouble = await roster.update(bot, title: wanted)
            namesSaving -= 1
            // Only while this is still the latest rename asked for.
            guard renames == this else { return }
            problem = trouble
            if trouble != nil {
                // Back to the name that is saved, leaving alone anything typed since.
                asked = savedTitle
                if name == wanted { name = asked }
            }
        }
    }

    /// The line saying what the bot is for, saved as the name is. An empty one is allowed.
    private func describe() {
        let wanted = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wanted != askedAbout, !isGoing, !roster.cannotEditBots else {
            about = askedAbout
            return
        }
        (about, askedAbout) = (wanted, wanted)
        aboutsSaving += 1
        describes += 1
        let this = describes
        Task {
            let outcome = await roster.update(bot, description: wanted).value
            aboutsSaving -= 1
            guard describes == this else { return }
            problem = outcome.said
            if !outcome.saved {
                askedAbout = savedDescription
                if about == wanted { about = askedAbout }
            }
        }
    }

    /// The description as the roster has it now, which is the last one known to be saved.
    private var savedDescription: String { roster.bots.first { $0.id == bot.id }?.description ?? bot.description }

    /// Saves the soul being written, if it changed. Asked for by Save, and when the pane
    /// closes or another bot is picked, so words written are never dropped by leaving.
    private func saveSoul() {
        guard let draft = draftSoul else { return }
        draftSoul = nil
        guard let shown = soul, Self.trimmed(draft) != Self.trimmed(shown), !isGoing, !roster.cannotEditBots else {
            // Left as it is: nothing is left unsaved.
            if let shown = soul, Self.trimmed(draft) == Self.trimmed(shown) {
                roster.discardUnsavedSoul(for: bot)
                soulNote = nil
            }
            return
        }
        soul = draft
        soulNote = nil
        soulSaves += 1
        let this = soulSaves
        // Taken in hand now, before the pane can go, so the next message waits for it.
        let save = roster.update(bot, soul: draft)
        Task {
            let outcome = await save.value
            if outcome.saved { savedSoul = draft }
            guard soulSaves == this else { return }
            soulNote = outcome.said
            if !outcome.saved {
                // Back to what the gateway holds, and open again with the words, to try
                // again or copy.
                soul = savedSoul
                if draftSoul == nil, !roster.cannotEditBots { draftSoul = draft }
            }
        }
    }

    /// The soul: a few lines at rest, opened in place to write, with Cancel and Save so
    /// paragraphs are not changed by a stray click.
    @ViewBuilder
    private func personality(_ soul: String, _ theme: Theme) -> some View {
        if let draft = draftSoul {
            VStack(alignment: .trailing, spacing: 0) {
                TextEditor(text: Binding(get: { draftSoul ?? draft }, set: { draftSoul = $0 }))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 260)
                    .padding(.horizontal, 9)
                    .padding(.top, 10)
                    .focused($isWritingSoul)
                    // Escape here only: elsewhere it belongs to whatever else is open.
                    .onExitCommand { cancelSoul() }
                    .accessibilityLabel("Personality")
                HStack(spacing: 6) {
                    pill("Cancel", isProminent: false, theme) { cancelSoul() }
                    pill("Save", isProminent: true, theme) { saveSoul() }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
        } else {
            Button {
                soulNote = nil
                draftSoul = soul
                // Once the editor is there to take the caret.
                Task { isWritingSoul = true }
            } label: {
                Text(Self.trimmed(soul).isEmpty ? "Say how this bot should talk" : Self.trimmed(soul))
                    .font(.system(size: 13))
                    .foregroundStyle(Self.trimmed(soul).isEmpty ? theme.secondaryText : theme.text)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(theme.hover.opacity(isOverSoul ? 1 : 0), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isOverSoul = $0 && !roster.cannotEditBots }
            // Still there to read, but not to change.
            .allowsHitTesting(!roster.cannotEditBots)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
            .accessibilityLabel("Personality")
            .accessibilityValue(soul)
            .help(roster.cannotEditBots ? "" : "Change personality")
        }
    }

    private func pill(_ title: String, isProminent: Bool, _ theme: Theme, action: @escaping () -> Void) -> some View {
        WhenHovered { isHovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isProminent ? theme.canvas : theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(
                        isProminent ? theme.text.opacity(isHovered ? 0.85 : 1) : (isHovered ? theme.raisedHover : theme.raised),
                        in: Capsule())
                    .overlay(Capsule().strokeBorder(isProminent ? .clear : theme.hairline))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    /// Lets go of the soul being written, and of one offered back after failing to save.
    private func cancelSoul() {
        draftSoul = nil
        soulNote = nil
        roster.discardUnsavedSoul(for: bot)
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Reads the chat's usage. The latest read is the one shown, and one that finds the
    /// chat can no longer say clears the card.
    private func readUsage() {
        usageReads += 1
        let this = usageReads
        Task {
            let read = await roster.usage(of: bot)
            if usageReads == this { usage = read }
        }
    }

    /// How full the chat is, and what the bot has used.
    @ViewBuilder
    private func usageRows(_ usage: ChatUsage, _ theme: Theme) -> some View {
        VStack(spacing: 0) {
            if let fraction = usage.contextFraction, let used = usage.contextUsed, let max = usage.contextMax {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Context")
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 8)
                        Text("\(Self.count(used)) / \(Self.count(max)) · \(Int((fraction * 100).rounded()))%")
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                    // Grey, and the colour of the words when nearly full: never red or amber.
                    GeometryReader { space in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.hairline)
                            Capsule()
                                .fill(fraction >= 0.85 ? theme.text : theme.secondaryText)
                                .frame(width: Swift.max(4, space.size.width * fraction))
                        }
                    }
                    .frame(height: 4)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent full")
            }
            if let tokens = usage.tokens {
                if usage.contextFraction != nil { theme.hairline.frame(height: 1).padding(.leading, 14) }
                row("Tokens used", Self.count(tokens), theme)
                    .help("Since the bot's chat last started on the gateway")
            }
        }
    }

    /// A count of tokens, shortened: 68K, 1.2M.
    static func count(_ tokens: Int) -> String {
        tokens.formatted(.number.notation(.compactName))
    }

    /// When a routine runs, in words. A paused one still says when it would.
    static func when(_ routine: Routine) -> String {
        let schedule = RoutineSchedule.text(for: routine.schedule)
        if routine.isEnabled { return schedule }
        return schedule.isEmpty ? "Paused" : "Paused · \(schedule)"
    }

    private func section(_ title: String, _ theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .padding(.leading, 6)
    }

    private func card(_ theme: Theme, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            // A row's hover fill keeps to the card's corners.
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
    }

    private func row(_ label: String, _ value: String, _ theme: Theme) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}
