import Foundation
import Testing
@testable import HermesKit

struct MessageActionsTests {
    private func row(_ json: String) throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    }

    @Test func reactionsAreReadFromTheRowsDisplayMetadata() throws {
        let kept = try row(#"{"id": 3, "role": "assistant", "content": "hi", "display_metadata": {"reactions": [{"emoji": "👍", "author": "user", "at": 1}, {"emoji": "✅", "author": "agent"}, {"emoji": ""}]}}"#)
        #expect(kept.reactions == [Reaction(emoji: "👍", author: "user"), Reaction(emoji: "✅", author: "agent")])
        // Older stores write the metadata out as a string.
        let written = try row(#"{"id": 3, "role": "user", "content": "hi", "display_metadata": "{\"reactions\": [{\"emoji\": \"❤️\", \"author\": \"agent\"}]}"}"#)
        #expect(written.reactions == [Reaction(emoji: "❤️", author: "agent")])
        #expect(try row(#"{"id": 3, "role": "user", "content": "hi", "display_metadata": "not json"}"#).reactions.isEmpty)
    }

    @Test func onlyTheGatewaysOwnTurnsOfThePersonCount() throws {
        #expect(try row(#"{"id": 1, "role": "user", "content": "hi"}"#).isPersons)
        #expect(try row(#"{"id": 1, "role": "user", "content": "more", "display_kind": "steer"}"#).isPersons)
        #expect(try !row(#"{"id": 1, "role": "user", "content": "[page]", "display_kind": "hidden"}"#).isPersons)
        #expect(try !row(#"{"id": 1, "role": "assistant", "content": "hi"}"#).isPersons)
        #expect(try !row(#"{"id": 1, "role": "assistant", "content": "hi", "display_kind": "steer"}"#).isPersons)
    }

    @Test func retryOnTheOlderRouteConsentsToOneCutAtTheRow() {
        let fields = Rewind(rowID: 42, emptiesChat: false).submitFields
        #expect(fields == ["confirm_truncate": .bool(true), "truncate_before_row_id": .number(42)])
        #expect(Rewind(rowID: 1, emptiesChat: true).submitFields["confirm_empty_truncate"] == .bool(true))
    }
}
