import Foundation
import Observation
import MuesliCore

private actor MeetingChatWorker {
    let store: MeetingChatStore
    let retrieval: MeetingChatRetrieval
    init(databaseURL: URL) { store = .init(databaseURL: databaseURL); retrieval = .init(databaseURL: databaseURL) }
    func interruptPendingTurns() throws { try store.interruptPendingTurns() }
    func createChat(scope: MeetingChatScope) throws -> MeetingChatSession { try store.createSession(scope: scope, title: "New chat") }
    func updateSession(id: UUID, title: String? = nil, scope: MeetingChatScope? = nil) throws { try store.updateSession(id: id, title: title, scope: scope) }
    func beginTurn(sessionID: UUID, question: String, scope: MeetingChatScope, config: AppConfig, attemptID: UUID) throws -> MeetingChatTurn {
        try store.beginTurn(sessionID: sessionID, question: question, scope: scope,
            provider: MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).label,
            model: MeetingTextGenerationClient.model(config), attemptID: attemptID)
    }
    func restartTurn(id: UUID, config: AppConfig) throws -> MeetingChatTurn? {
        try store.restartTurn(id: id, provider: MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).label, model: MeetingTextGenerationClient.model(config))
    }
    func setTurnState(id: UUID, state: MeetingChatTurnState, error: String? = nil, attemptID: UUID?) throws {
        try store.setTurnState(id: id, state: state, error: error, attemptID: attemptID)
    }
    func deleteChat(id: UUID) throws { try store.deleteSession(id: id) }
    func saveDraft(turnID: UUID, text: String) throws { try store.saveDraft(turnID: turnID, text: text) }
    func warmIndex() throws { try retrieval.prepareIndex() }
    func choices() throws -> [MeetingChatSourceChoice] { try warmIndex(); return try store.sourceChoices() }
    func source(_ id: Int64) throws -> MeetingChatSourceSnapshot? { try store.sourceSnapshots(scope: .init(selection: .meetings([id]))).first }
    func evidence(for turn: MeetingChatTurn) throws -> (MeetingChatEvidence, [MeetingChatTurn]) {
        let session = try store.sessions().first { $0.id == turn.sessionID }
        let history = try store.turns(sessionID: turn.sessionID).filter {
            $0.ordinal < turn.ordinal && $0.ordinal >= (session?.contextStartOrdinal ?? 0) && $0.scope == turn.scope && $0.state == .completed
        }
        let broadIntent = ["recap", "summar", "decisions", "decide", "next steps", "action items", "follow-up"].contains { turn.question.localizedCaseInsensitiveContains($0) }
        // Every question gets lexical relevance first. Broad vocabulary never disables a topic match.
        var evidence = try retrieval.retrieve(question: turn.question, scope: turn.scope, priorQuestions: history.map(\.question))
        if broadIntent {
            let representative = try retrieval.retrieve(question: turn.question, scope: turn.scope, broadRecap: true)
            var selected: [MeetingChatPassage] = []; var seen = Set<String>(); var bytes = 0; var packetBytes = 0
            for var passage in evidence.passages where bytes + passage.excerpt.utf8.count <= 6_000 {
                passage.sourceKey = "S\(selected.count + 1)"
                let footprint = MeetingChatPassages.promptByteCount(passage)
                if packetBytes + footprint <= 5_000, seen.insert(passage.id).inserted {
                    selected.append(passage); bytes += passage.excerpt.utf8.count; packetBytes += footprint
                }
            }
            for var passage in representative.passages where bytes + passage.excerpt.utf8.count <= 12_000 {
                passage.sourceKey = "S\(selected.count + 1)"
                let footprint = MeetingChatPassages.promptByteCount(passage)
                if packetBytes + footprint <= 10_000, seen.insert(passage.id).inserted {
                    selected.append(passage); bytes += passage.excerpt.utf8.count; packetBytes += footprint
                }
            }
            for index in selected.indices { selected[index].sourceKey = "S\(index + 1)" }
            let represented = Set(selected.map(\.meetingID))
            evidence = .init(scope: turn.scope, passages: selected,
                dependencies: Array(Set(selected.map { MeetingChatDependency(meetingID: $0.meetingID, revision: $0.revision) })),
                coverage: .init(eligibleMeetingCount: representative.coverage.eligibleMeetingCount, evidenceMeetingCount: represented.count,
                    isPartialRecap: representative.coverage.isPartialRecap || represented.count < representative.coverage.eligibleMeetingCount),
                metrics: .init(sourceSnapshotCount: evidence.metrics.sourceSnapshotCount + representative.metrics.sourceSnapshotCount,
                    reindexedMeetingCount: evidence.metrics.reindexedMeetingCount + representative.metrics.reindexedMeetingCount,
                    decodedCandidateCount: evidence.metrics.decodedCandidateCount + representative.metrics.decodedCandidateCount))
        }
        // Include exactly the history that fits the same budget used by prompt construction.
        var selected: [MeetingChatTurn] = []; var bytes = 0
        for previous in history.reversed() {
            let inherited = try store.dependencies(turnID: previous.id)
            guard try store.dependenciesAreCurrent(inherited) else { continue }
            let block = "Question: \(previous.question)\nHistorical answer (not evidence): \(previous.originalAnswer ?? "")"
            guard bytes + block.utf8.count <= 4_000 else { continue }
            bytes += block.utf8.count; selected.insert(previous, at: 0)
            evidence.dependencies += inherited
        }
        evidence.dependencies = Array(Set(evidence.dependencies))
        try store.attachEvidence(turnID: turn.id, dependencies: evidence.dependencies, attemptID: turn.attemptID)
        return (evidence, selected)
    }
    func finish(turn: MeetingChatTurn, answer: MeetingChatAnswer, dependencies: [MeetingChatDependency], isDraft: Bool) throws -> Bool {
        try store.finishTurn(turnID: turn.id, answer: answer.markdown, citations: answer.citations, dependencies: dependencies, coverage: answer.coverage, isDraft: isDraft, attemptID: turn.attemptID)
    }
}

@MainActor @Observable
final class MeetingChatCoordinator {
    let store: MeetingChatStore
    @ObservationIgnored private let worker: MeetingChatWorker
    @ObservationIgnored private let generator: any MeetingTextGenerating
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var initialization: Task<Void, Never>?
    private var selectionVersion = UUID()
    private(set) var sessions: [MeetingChatSession] = []
    private(set) var hasChatHistory = false
    private(set) var turns: [MeetingChatTurn] = []
    private(set) var selectedSessionID: UUID?
    private(set) var activeRequestID: UUID?
    private(set) var activeTurnID: UUID?
    private var activeSessionID: UUID?
    private(set) var phase = ""
    private var composerDrafts: [UUID?: String] = [:]
    var composerDraft: String {
        get { composerDrafts[selectedSessionID] ?? "" }
        set { composerDrafts[selectedSessionID] = newValue }
    }
    var errorMessage: String?
    var fastAnswers = true
    var scrollAnchors: [UUID: UUID] = [:]
    private(set) var sourceMutationVersion: Int64 = 0
    private(set) var sourceChoices: [MeetingChatSourceChoice] = []
    var scope: MeetingChatScope { sessions.first { $0.id == selectedSessionID }?.scope ?? .init() }
    var isBusy: Bool { activeRequestID != nil }
    private(set) var isUpdatingChat = false

    init(databaseURL: URL, generator: any MeetingTextGenerating = MeetingTextGenerationClient()) {
        store = .init(databaseURL: databaseURL); worker = .init(databaseURL: databaseURL); self.generator = generator
        reload()
        sourceMutationVersion = (try? store.sourceMutationVersion()) ?? 0
        let worker = worker
        initialization = Task {
            do { try await worker.interruptPendingTurns(); reload() }
            catch { errorMessage = "Could not recover meeting chat history." }
        }
        Task {
            await initialization?.value
            do { sourceChoices = try await worker.choices() }
            catch { errorMessage = "Could not prepare meeting search. Retry by asking a question." }
        }
    }
    func reload() {
        do {
            sessions = try store.sessions()
            hasChatHistory = try store.hasChatHistory()
            let sessionIDs = Set(sessions.map(\.id))
            composerDrafts = composerDrafts.filter { $0.key == nil || sessionIDs.contains($0.key!) }
            if let id = selectedSessionID, sessions.contains(where: { $0.id == id }) { turns = try store.turns(sessionID: id) }
            else { selectedSessionID = nil; turns = [] }
        } catch { errorMessage = "Could not load meeting chat history." }
    }
    @discardableResult
    func createChat(scope: MeetingChatScope) async -> UUID? {
        guard !isUpdatingChat else { return nil }
        isUpdatingChat = true
        defer { isUpdatingChat = false }
        let version = UUID(); selectionVersion = version
        await initialization?.value
        do {
            let session = try await worker.createChat(scope: scope)
            if selectionVersion == version { selectedSessionID = session.id; errorMessage = nil }
            reload()
            return session.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    func selectChat(id: UUID) { selectionVersion = UUID(); selectedSessionID = id; errorMessage = nil; reload() }
    @discardableResult
    func setScope(_ newScope: MeetingChatScope) async -> UUID? {
        if selectedSessionID == nil { return await createChat(scope: newScope) }
        guard let id = selectedSessionID, !isUpdatingChat else { return nil }
        isUpdatingChat = true
        defer { isUpdatingChat = false }
        do { try await worker.updateSession(id: id, scope: newScope); reload(); return id }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func applyPreparedPrompt(_ prompt: MeetingChatPreparedPrompt) async -> Bool {
        let target: UUID?
        if prompt.scope != scope {
            guard let id = await setScope(prompt.scope) else { return false }
            target = id
        } else { target = selectedSessionID }
        guard selectedSessionID == target else { return false }
        composerDraft = prompt.text
        return true
    }
    func renameChat(id: UUID, title: String) async {
        do { try await worker.updateSession(id: id, title: title); reload() } catch { errorMessage = error.localizedDescription }
    }
    func send(question: String, config: AppConfig, isDraft: Bool = false) async {
        guard !isBusy, !isUpdatingChat else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard question.count <= 2_000 else { errorMessage = MeetingChatError.questionTooLong.localizedDescription; return }
        let requestID = UUID()
        activeRequestID = requestID; phase = "Saving question"
        let draftKey = selectedSessionID; let submittedDraft = composerDraft
        activeSessionID = draftKey
        let requestScope = scope; let isFirstQuestion = turns.isEmpty
        defer {
            if activeRequestID == requestID, tasks[requestID] == nil {
                activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""
            }
        }
        await initialization?.value
        guard activeRequestID == requestID, !Task.isCancelled else { return }
        var requestSessionID = draftKey
        var submittedDraftKey = draftKey
        if requestSessionID == nil {
            guard selectedSessionID == nil else { return }
            requestSessionID = await createChat(scope: requestScope)
            if let id = requestSessionID {
                submittedDraftKey = id
                // An implicit first send turns the untitled composer into this chat.
                // Move its latest text, including edits or a Stop during registration.
                if composerDrafts[id] == nil {
                    composerDrafts[id] = composerDrafts[nil]
                    composerDrafts[nil] = nil
                }
            }
        }
        guard activeRequestID == requestID, !Task.isCancelled, let id = requestSessionID else { return }
        activeSessionID = id
        do {
            let requestConfig = fastAnswers ? MeetingTextGenerationClient.fastConfiguration(config) : config
            let turn = try await worker.beginTurn(sessionID: id, question: question, scope: requestScope, config: requestConfig, attemptID: requestID)
            guard activeRequestID == requestID, !Task.isCancelled else {
                try? await worker.setTurnState(id: turn.id, state: .stopped, attemptID: requestID)
                reload(); return
            }
            activeTurnID = turn.id
            if isFirstQuestion { try await worker.updateSession(id: id, title: String(question.prefix(64))) }
            guard activeRequestID == requestID, !Task.isCancelled else {
                try? await worker.setTurnState(id: turn.id, state: .stopped, attemptID: requestID)
                reload(); return
            }
            if composerDrafts[submittedDraftKey] == submittedDraft, submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines) == question { composerDrafts[submittedDraftKey] = nil }
            errorMessage = nil; reload(); launch(turn, config: requestConfig, isDraft: isDraft)
        } catch {
            guard activeRequestID == requestID else { return }
            if let turnID = activeTurnID { try? await worker.setTurnState(id: turnID, state: .failed, error: error.localizedDescription, attemptID: requestID) }
            guard activeRequestID == requestID else { return }
            activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""
            errorMessage = error.localizedDescription; reload()
        }
    }
    func retry(turnID: UUID, config: AppConfig) async {
        guard !isBusy, !isUpdatingChat else { return }
        let reservation = UUID(); activeRequestID = reservation; phase = "Saving question"
        activeSessionID = turns.first(where: { $0.id == turnID })?.sessionID
        defer {
            if activeRequestID == reservation { activeRequestID = nil; activeSessionID = nil; phase = "" }
        }
        do {
            let requestConfig = fastAnswers ? MeetingTextGenerationClient.fastConfiguration(config) : config
            guard let turn = try await worker.restartTurn(id: turnID, config: requestConfig) else {
                if activeRequestID == reservation { activeRequestID = nil; phase = "" }; return
            }
            guard activeRequestID == reservation, !Task.isCancelled else {
                try? await worker.setTurnState(id: turn.id, state: .stopped, attemptID: turn.attemptID)
                reload(); return
            }
            reload(); launch(turn, config: requestConfig, isDraft: turn.isDraft)
        } catch {
            if activeRequestID == reservation { activeRequestID = nil; phase = ""; errorMessage = error.localizedDescription }
        }
    }
    private func launch(_ turn: MeetingChatTurn, config: AppConfig, isDraft: Bool) {
        let requestID = turn.attemptID ?? UUID(); activeRequestID = requestID; activeTurnID = turn.id; activeSessionID = turn.sessionID; phase = "Finding meeting context"
        let worker = worker; let generator = generator
        tasks[requestID] = Task {
            defer {
                tasks.removeValue(forKey: requestID)
                if activeRequestID == requestID { activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = "" }
                reload()
            }
            do {
                let (evidence, history) = try await worker.evidence(for: turn)
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                phase = "Writing answer"
                let answer: MeetingChatAnswer
                if evidence.passages.isEmpty {
                    answer = .init(markdown: "I couldn’t find supporting information in the selected saved meetings. Try a meeting title, specific term, or a narrower scope.", citations: [], insufficientEvidence: true, coverage: evidence.coverage)
                } else { answer = try await MeetingChatClient.answer(question: turn.question, evidence: evidence, history: history, config: config, generator: generator) }
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                guard try await worker.finish(turn: turn, answer: answer, dependencies: evidence.dependencies, isDraft: isDraft) else { throw MeetingChatError.sourceChanged }
            } catch {
                guard activeRequestID == requestID else { return }
                let stopped = Task.isCancelled || error is CancellationError
                let message = stopped ? nil : (error is MeetingChatError || error is MeetingTextGenerationError ? error.localizedDescription : "Meeting AI request failed. Please retry or check your connection settings.")
                try? await worker.setTurnState(id: turn.id, state: stopped ? .stopped : .failed, error: message, attemptID: turn.attemptID)
            }
        }
    }
    func stop() {
        guard let id = activeRequestID else { return }
        tasks[id]?.cancel()
        if let turnID = activeTurnID {
            let cleanupID = UUID(); let worker = worker
            tasks[cleanupID] = Task {
                defer { tasks.removeValue(forKey: cleanupID); reload() }
                try? await worker.setTurnState(id: turnID, state: .stopped, attemptID: id)
            }
            if let index = turns.firstIndex(where: { $0.id == turnID && $0.state.isPending }) { turns[index].state = .stopped }
        }
        activeRequestID = nil; activeTurnID = nil; activeSessionID = nil; phase = ""
    }
    func deleteChat(id: UUID) async {
        if activeSessionID == id { stop() }
        do { try await worker.deleteChat(id: id); composerDrafts[id] = nil; reload() } catch { errorMessage = error.localizedDescription }
    }
    func saveDraft(turnID: UUID, text: String) async {
        do { try await worker.saveDraft(turnID: turnID, text: text); reload() } catch { errorMessage = error.localizedDescription }
    }
    func refreshChoices() async { do { sourceChoices = try await worker.choices() } catch { errorMessage = error.localizedDescription } }
    func source(_ id: Int64) async -> MeetingChatSourceSnapshot? { try? await worker.source(id) }
    func waitForIdle() async { await initialization?.value; while let task = tasks.values.first { await task.value } }
    func refreshForSourceChanges() {
        guard let version = try? store.sourceMutationVersion(), version != sourceMutationVersion else { return }
        sourceMutationVersion = version
        if let sessionID = activeSessionID, let turnID = activeTurnID {
            let current = try? store.turns(sessionID: sessionID).first { $0.id == turnID }
            if current == nil || current?.state == .sourceDeleted { stop() }
        }
        reload()
        Task { await refreshChoices() }
    }
}
