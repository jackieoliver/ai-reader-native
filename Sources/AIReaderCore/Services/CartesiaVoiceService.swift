import Foundation

public struct CartesiaVoiceListInput: Equatable, Sendable {
  public var apiKey: String
  public var version: String
  public var language: String?
  public var gender: String?
  public var query: String?
  public var limit: Int

  public init(
    apiKey: String,
    version: String = ProviderConfiguration.defaultCartesiaVersion,
    language: String? = nil,
    gender: String? = nil,
    query: String? = nil,
    limit: Int = 50
  ) {
    self.apiKey = apiKey
    self.version = version
    self.language = language
    self.gender = gender
    self.query = query
    self.limit = limit
  }
}

public struct CartesiaVoice: Decodable, Equatable, Identifiable, Sendable {
  public var id: String
  public var isOwner: Bool?
  public var isPublic: Bool?
  public var name: String
  public var description: String?
  public var gender: String?
  public var language: String?
  public var country: String?
  public var previewFileURL: URL?

  public var displayName: String {
    let details = [gender, country].compactMap { $0 }.filter { !$0.isEmpty }
    guard !details.isEmpty else { return name }
    return "\(name) (\(details.joined(separator: ", ")))"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case isOwner = "is_owner"
    case isPublic = "is_public"
    case name
    case description
    case gender
    case language
    case country
    case previewFileURL = "preview_file_url"
  }
}

public final class CartesiaVoiceService: @unchecked Sendable {
  private let session: URLSession
  private let endpoint: URL

  public init(
    session: URLSession = .shared,
    endpoint: URL = URL(string: "https://api.cartesia.ai/voices")!
  ) {
    self.session = session
    self.endpoint = endpoint
  }

  public func listVoices(_ input: CartesiaVoiceListInput) async throws -> [CartesiaVoice] {
    let request = try makeRequest(input)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProviderAPIError.invalidResponse(provider: "Cartesia")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw ProviderAPIError.httpError(
        provider: "Cartesia",
        statusCode: httpResponse.statusCode,
        body: String(data: data, encoding: .utf8) ?? ""
      )
    }

    return try JSONDecoder().decode(CartesiaVoiceListResponse.self, from: data).data
  }

  public func makeRequest(_ input: CartesiaVoiceListInput) throws -> URLRequest {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    var queryItems = [
      URLQueryItem(name: "limit", value: "\(min(max(input.limit, 1), 100))"),
    ]

    if let language = input.language?.nonEmptyForQuery {
      queryItems.append(URLQueryItem(name: "language", value: language))
    }
    if let gender = input.gender?.nonEmptyForQuery {
      queryItems.append(URLQueryItem(name: "gender", value: gender))
    }
    if let query = input.query?.nonEmptyForQuery {
      queryItems.append(URLQueryItem(name: "q", value: query))
    }

    components?.queryItems = queryItems

    guard let url = components?.url else {
      throw ProviderAPIError.invalidResponse(provider: "Cartesia")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(input.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(input.version, forHTTPHeaderField: "Cartesia-Version")
    return request
  }
}

private struct CartesiaVoiceListResponse: Decodable {
  var data: [CartesiaVoice]
}

private extension String {
  var nonEmptyForQuery: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
