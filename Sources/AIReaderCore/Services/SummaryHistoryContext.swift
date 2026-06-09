import Foundation

public enum SummaryHistoryContext {
  public static func messages(
    sourceText: String,
    priorMessages: [AnthropicChatMessage]
  ) -> [AnthropicChatMessage] {
    let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let history = priorMessages.compactMap(transcriptLine)

    guard !history.isEmpty else {
      return [
        AnthropicChatMessage(role: .user, content: trimmedSource)
      ]
    }

    return [
      AnthropicChatMessage(
        role: .user,
        content: historyAwarePrompt(sourceText: trimmedSource, historyTranscript: history.joined(separator: "\n\n"))
      )
    ]
  }

  private static func transcriptLine(_ message: AnthropicChatMessage) -> String? {
    let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      return nil
    }

    let speaker: String
    switch message.role {
    case .user:
      speaker = "User"
    case .assistant:
      speaker = "Claude"
    }

    return "\(speaker): \(content)"
  }

  private static func historyAwarePrompt(sourceText: String, historyTranscript: String) -> String {
    """
    The user enabled History in AI Reader. Use the prior Claude Summary chat and the newly highlighted text together.

    Write the next summary response for spoken-word playback. It should sound natural when read aloud, favor what is new in the highlighted text, and carry forward useful context from prior Claude responses and user messages. Do not quote the prior chat at length.

    Prior Claude Summary chat:

    \(historyTranscript)

    Newly highlighted text:

    \(sourceText)
    """
  }
}
