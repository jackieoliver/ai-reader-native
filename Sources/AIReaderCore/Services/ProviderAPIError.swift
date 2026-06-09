import Foundation

public enum ProviderAPIError: LocalizedError, Equatable, Sendable {
  case invalidResponse(provider: String)
  case httpError(provider: String, statusCode: Int, body: String)
  case emptyResponse(provider: String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let provider):
      return "\(provider) returned an invalid response."
    case .httpError(let provider, let statusCode, let body):
      let detail = body.isEmpty ? "No response body." : body
      return "\(provider) returned HTTP \(statusCode): \(detail)"
    case .emptyResponse(let provider):
      return "\(provider) returned an empty response."
    }
  }
}
