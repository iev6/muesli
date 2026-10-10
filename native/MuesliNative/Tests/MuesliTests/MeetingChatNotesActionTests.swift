import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat cited notes actions")
struct MeetingChatNotesActionTests {
    private let generated = "## Decision\nLaunch Friday."
    private let manual = "# Launch\n\nMy written reminder."

    private func fixture() throws -> (MuesliController, DictationStore, MeetingRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-notes-actions-\(UUID())")
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "Launch Friday.", formattedNotes: generated, micAudioPath: nil, systemAudioPath: nil)
        try store.updateMeetingManualNotes(id: id, manualNotes: manual)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        return (controller, store, try #require(controller.meeting(id: id)))
    }

    private func citation(for meeting: MeetingRecord, kind: MeetingChatSourceKind, meetingID: Int64? = nil) -> MeetingChatCitation {
        MeetingChatCitation(sourceKey: "S1", meetingID: meetingID ?? meeting.id, title: meeting.title, startDate: Date(),
            kind: kind, excerpt: "My written reminder.", range: .init(location: 10, length: 20), revision: "fixture")
    }

    @Test func manualCitationEditsAndCopiesTheDisplayedNotes() throws {
        let (_, _, meeting) = try fixture()
        let source = citation(for: meeting, kind: .manualNotes)
        #expect(MeetingDetailView.notesContent(for: meeting, citation: source) == "# Launch\n\nMy written reminder.")
        let copied = MeetingDetailView.copyContent(for: meeting, content: .notes, citation: source)
        #expect(copied.hasSuffix("\n# Launch\n\nMy written reminder."))
        #expect(!copied.contains("Launch Friday."))
    }

    @Test func manualCitationCopyPreservesEditedHeadingForUnstructuredMeeting() {
        let meeting = MeetingRecord(id: 7, title: "Launch", startTime: "2026-10-11T10:00:00Z", durationSeconds: 0,
            rawTranscript: "Original transcript", formattedNotes: "", wordCount: 2, folderID: nil, manualNotes: manual)
        let copied = MeetingDetailView.copyContent(for: meeting, content: .notes,
            editedText: "# Launch\n\nEdited reminder.", citation: citation(for: meeting, kind: .manualNotes))
        #expect(copied.hasSuffix("\n# Launch\n\nEdited reminder."))
    }

    @Test func manualCitationSavePreservesGeneratedNotes() throws {
        let (controller, _, meeting) = try fixture()
        MeetingDetailView.saveNotes(for: meeting, notes: "Revised written reminder.",
            citation: citation(for: meeting, kind: .manualNotes), controller: controller)
        let saved = try #require(controller.meeting(id: meeting.id))
        #expect(saved.manualNotes == "Revised written reminder.")
        #expect(saved.formattedNotes == "## Decision\nLaunch Friday.")
    }

    @Test func unrelatedManualCitationDoesNotChangeNotesActions() throws {
        let (controller, _, meeting) = try fixture()
        let otherSource = citation(for: meeting, kind: .manualNotes, meetingID: meeting.id + 1)
        #expect(MeetingDetailView.notesContent(for: meeting, citation: otherSource) == "## Decision\nLaunch Friday.")
        #expect(MeetingDetailView.copyContent(for: meeting, content: .notes, citation: otherSource).hasSuffix("\n## Decision\nLaunch Friday."))
        MeetingDetailView.saveNotes(for: meeting, notes: "Generated revision", citation: otherSource, controller: controller)
        let saved = try #require(controller.meeting(id: meeting.id))
        #expect(saved.manualNotes == "# Launch\n\nMy written reminder.")
        #expect(saved.formattedNotes == "Generated revision")
    }

    @Test func generatedCitationRetainsGeneratedNotesActions() throws {
        let (controller, _, meeting) = try fixture()
        let source = citation(for: meeting, kind: .generatedNotes)
        #expect(MeetingDetailView.notesContent(for: meeting, citation: source) == "## Decision\nLaunch Friday.")
        #expect(MeetingDetailView.copyContent(for: meeting, content: .notes, citation: source).hasSuffix("\n## Decision\nLaunch Friday."))
        MeetingDetailView.saveNotes(for: meeting, notes: "Updated generated notes", citation: source, controller: controller)
        let saved = try #require(controller.meeting(id: meeting.id))
        #expect(saved.formattedNotes == "Updated generated notes")
        #expect(saved.manualNotes == "# Launch\n\nMy written reminder.")
    }
}
