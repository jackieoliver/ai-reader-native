import AIReaderCore
import XCTest

final class SummaryHistoryContextTests: XCTestCase {
  func testMessagesWithoutHistoryUseOnlySourceText() {
    let messages = SummaryHistoryContext.messages(
      sourceText: " highlighted text ",
      priorMessages: []
    )

    XCTAssertEqual(messages, [
      AnthropicChatMessage(role: .user, content: "highlighted text")
    ])
  }

  func testMessagesWithHistoryCombinePriorChatAndHighlightedText() throws {
    let messages = SummaryHistoryContext.messages(
      sourceText: "new highlighted text",
      priorMessages: [
        AnthropicChatMessage(role: .assistant, content: "first summary"),
        AnthropicChatMessage(role: .user, content: "follow-up question"),
        AnthropicChatMessage(role: .assistant, content: "follow-up answer"),
      ]
    )

    let message = try XCTUnwrap(messages.first)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(message.role, .user)
    XCTAssertTrue(message.content.contains("spoken-word playback"))
    XCTAssertTrue(message.content.contains("Claude: first summary"))
    XCTAssertTrue(message.content.contains("User: follow-up question"))
    XCTAssertTrue(message.content.contains("Claude: follow-up answer"))
    XCTAssertTrue(message.content.contains("new highlighted text"))
  }

  func testMessagesWithHistoryIgnoreEmptyPriorMessages() throws {
    let messages = SummaryHistoryContext.messages(
      sourceText: "new text",
      priorMessages: [
        AnthropicChatMessage(role: .assistant, content: " "),
        AnthropicChatMessage(role: .user, content: "useful context"),
      ]
    )

    let message = try XCTUnwrap(messages.first)
    XCTAssertFalse(message.content.contains("Claude:"))
    XCTAssertTrue(message.content.contains("User: useful context"))
  }
}
