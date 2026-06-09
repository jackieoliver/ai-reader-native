import Foundation

public struct EnvFile: Equatable, Sendable {
  public var values: [String: String]

  public init(values: [String: String]) {
    self.values = values
  }

  public static func load(from url: URL) throws -> EnvFile {
    let contents = try String(contentsOf: url, encoding: .utf8)
    return EnvFile(values: parse(contents))
  }

  public static func writeMerged(
    values newValues: [String: String],
    removingKeys keysToRemove: Set<String> = [],
    to url: URL
  ) throws {
    let existingValues: [String: String]
    if FileManager.default.fileExists(atPath: url.path) {
      existingValues = try load(from: url).values
    } else {
      existingValues = [:]
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var merged = existingValues
    keysToRemove.forEach { merged.removeValue(forKey: $0) }
    for (key, value) in newValues {
      let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedValue.isEmpty {
        merged.removeValue(forKey: key)
      } else {
        merged[key] = trimmedValue
      }
    }

    let contents = serialize(merged)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  public static func parse(_ contents: String) -> [String: String] {
    var parsed: [String: String] = [:]

    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      guard let equals = line.firstIndex(of: "=") else { continue }

      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty else { continue }

      var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        let first = value.first,
        let last = value.last,
        (first == "\"" && last == "\"") || (first == "'" && last == "'")
      {
        value.removeFirst()
        value.removeLast()
        if first == "\"" {
          value = unescapeDoubleQuoted(value)
        }
      }

      parsed[key] = value
    }

    return parsed
  }

  public static func serialize(_ values: [String: String]) -> String {
    let preferredOrder = [
      "CARTESIA_MODEL",
      "CARTESIA_VOICE_ID",
      "CARTESIA_LANGUAGE",
      "CARTESIA_VERSION",
      "ANTHROPIC_MODEL",
      "ANTHROPIC_VERSION",
      "ANTHROPIC_MAX_TOKENS",
    ]
    let orderedKeys = preferredOrder.filter { values[$0] != nil }
      + values.keys.filter { !preferredOrder.contains($0) }.sorted()

    var lines = [
      "# AI Reader local provider configuration.",
      "# API keys entered in the app are saved here for local development.",
      "",
    ]
    lines.append(contentsOf: orderedKeys.map { key in
      "\(key)=\(escape(values[key] ?? ""))"
    })
    lines.append("")
    return lines.joined(separator: "\n")
  }

  public func value(for key: String) -> String? {
    guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func escape(_ value: String) -> String {
    if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      !value.contains("#"),
      !value.contains("\""),
      !value.contains("'")
    {
      return value
    }

    return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  private static func unescapeDoubleQuoted(_ value: String) -> String {
    var result = ""
    var isEscaping = false

    for character in value {
      if isEscaping {
        if character == "\\" || character == "\"" {
          result.append(character)
        } else {
          result.append("\\")
          result.append(character)
        }
        isEscaping = false
      } else if character == "\\" {
        isEscaping = true
      } else {
        result.append(character)
      }
    }

    if isEscaping {
      result.append("\\")
    }

    return result
  }
}
