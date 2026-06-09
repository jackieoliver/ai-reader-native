import Foundation

public enum AIReaderAppIdentityKind: String, Codable, Sendable {
  case official
  case dev
}

public struct AIReaderAppIdentity: Equatable, Sendable {
  public static let infoPlistKey = "AIReaderAppIdentity"
  public static let preferencesDomainInfoPlistKey = "AIReaderPreferencesDomain"
  public static let buildTimestampInfoPlistKey = "AIReaderBuildTimestamp"

  public let kind: AIReaderAppIdentityKind
  public let displayName: String
  public let appBundleName: String
  public let bundleIdentifier: String
  public let preferencesDomain: String

  public var userDefaults: UserDefaults {
    if Bundle.main.bundleIdentifier == preferencesDomain {
      return .standard
    }
    return UserDefaults(suiteName: preferencesDomain) ?? .standard
  }

  public static let official = AIReaderAppIdentity(
    kind: .official,
    displayName: "AI Reader",
    appBundleName: "AI Reader",
    bundleIdentifier: "com.hapticasensorics.AIReader",
    preferencesDomain: "com.hapticasensorics.AIReader"
  )

  public static let dev = AIReaderAppIdentity(
    kind: .dev,
    displayName: "AI Reader Dev",
    appBundleName: "AI Reader Dev",
    bundleIdentifier: "com.hapticasensorics.AIReader.dev",
    preferencesDomain: "com.hapticasensorics.AIReader.dev"
  )

  public static func devPermissionTest(suffix rawSuffix: String) -> AIReaderAppIdentity {
    let suffix = normalizePermissionTestSuffix(rawSuffix)
    let bundleIdentifier = "\(devPermissionBundleIdentifierPrefix)\(suffix)"
    let displayName = "AI Reader Dev - \(suffix)"
    return AIReaderAppIdentity(
      kind: .dev,
      displayName: displayName,
      appBundleName: displayName,
      bundleIdentifier: bundleIdentifier,
      preferencesDomain: bundleIdentifier
    )
  }

  public static func from(_ rawValue: String?) -> AIReaderAppIdentity? {
    guard let rawValue else { return nil }
    let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if raw.hasPrefix(devPermissionPrefix) {
      return devPermissionTest(suffix: String(raw.dropFirst(devPermissionPrefix.count)))
    }

    switch raw {
    case "official", "release", "prod", "production", "public":
      return .official
    case "dev", "development", "debug", "local":
      return .dev
    case let value where value.hasPrefix("dev-permission:"):
      return .dev
    default:
      return nil
    }
  }

  public static func fromBundleIdentifier(_ bundleIdentifier: String?) -> AIReaderAppIdentity? {
    if let suffix = permissionTestSuffix(fromBundleIdentifier: bundleIdentifier) {
      return devPermissionTest(suffix: suffix)
    }

    switch bundleIdentifier {
    case dev.bundleIdentifier:
      return .dev
    case official.bundleIdentifier:
      return .official
    default:
      if bundleIdentifier?.hasPrefix("\(dev.bundleIdentifier).") == true {
        return .dev
      }
      return nil
    }
  }

  public static func current(mainBundle: Bundle = .main) -> AIReaderAppIdentity {
    current(
      infoDictionary: mainBundle.infoDictionary ?? [:],
      bundleIdentifier: mainBundle.bundleIdentifier
    )
  }

  public static func current(
    infoDictionary: [String: Any],
    bundleIdentifier: String?
  ) -> AIReaderAppIdentity {
    let base = from(stringValue(infoDictionary[infoPlistKey]))
      ?? fromBundleIdentifier(bundleIdentifier)
      ?? .official

    return AIReaderAppIdentity(
      kind: base.kind,
      displayName: stringValue(infoDictionary["CFBundleDisplayName"]) ?? base.displayName,
      appBundleName: stringValue(infoDictionary["CFBundleName"]) ?? base.appBundleName,
      bundleIdentifier: stringValue(infoDictionary["CFBundleIdentifier"]) ?? bundleIdentifier ?? base.bundleIdentifier,
      preferencesDomain: stringValue(infoDictionary[preferencesDomainInfoPlistKey]) ?? base.preferencesDomain
    )
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static let devPermissionPrefix = "dev-permission:"
  private static let devPermissionBundleIdentifierPrefix = "com.hapticasensorics.AIReader.dev.permission."

  private static func permissionTestSuffix(fromBundleIdentifier bundleIdentifier: String?) -> String? {
    guard let bundleIdentifier,
      bundleIdentifier.hasPrefix(devPermissionBundleIdentifierPrefix)
    else {
      return nil
    }
    return String(bundleIdentifier.dropFirst(devPermissionBundleIdentifierPrefix.count))
  }

  private static func normalizePermissionTestSuffix(_ raw: String) -> String {
    let normalized = raw
      .lowercased()
      .map { character -> Character in
        character.isLetter || character.isNumber ? character : "-"
      }
    let collapsed = String(normalized)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return collapsed.isEmpty ? "local" : String(collapsed.prefix(40))
  }
}
