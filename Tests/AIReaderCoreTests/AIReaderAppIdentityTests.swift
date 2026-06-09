import AIReaderCore
import XCTest

final class AIReaderAppIdentityTests: XCTestCase {
  func testDevAndOfficialIdentitiesStaySeparated() {
    XCTAssertEqual(AIReaderAppIdentity.official.bundleIdentifier, "com.hapticasensorics.AIReader")
    XCTAssertEqual(AIReaderAppIdentity.official.preferencesDomain, "com.hapticasensorics.AIReader")
    XCTAssertEqual(AIReaderAppIdentity.dev.bundleIdentifier, "com.hapticasensorics.AIReader.dev")
    XCTAssertEqual(AIReaderAppIdentity.dev.preferencesDomain, "com.hapticasensorics.AIReader.dev")
    XCTAssertNotEqual(AIReaderAppIdentity.official.bundleIdentifier, AIReaderAppIdentity.dev.bundleIdentifier)
    XCTAssertNotEqual(AIReaderAppIdentity.official.preferencesDomain, AIReaderAppIdentity.dev.preferencesDomain)
  }

  func testIdentityResolvesFromGeneratedInfoPlistValues() {
    let identity = AIReaderAppIdentity.current(
      infoDictionary: [
        AIReaderAppIdentity.infoPlistKey: "dev",
        "CFBundleDisplayName": "AI Reader Dev",
        "CFBundleName": "AI Reader Dev",
        "CFBundleIdentifier": "com.hapticasensorics.AIReader.dev",
        AIReaderAppIdentity.preferencesDomainInfoPlistKey: "com.hapticasensorics.AIReader.dev",
      ],
      bundleIdentifier: nil
    )

    XCTAssertEqual(identity.kind, .dev)
    XCTAssertEqual(identity.displayName, "AI Reader Dev")
    XCTAssertEqual(identity.appBundleName, "AI Reader Dev")
    XCTAssertEqual(identity.bundleIdentifier, "com.hapticasensorics.AIReader.dev")
    XCTAssertEqual(identity.preferencesDomain, "com.hapticasensorics.AIReader.dev")
  }

  func testIdentityFallsBackToBundleIdentifier() {
    XCTAssertEqual(
      AIReaderAppIdentity.current(infoDictionary: [:], bundleIdentifier: "com.hapticasensorics.AIReader.dev"),
      .dev
    )
    XCTAssertEqual(
      AIReaderAppIdentity.current(infoDictionary: [:], bundleIdentifier: "com.hapticasensorics.AIReader"),
      .official
    )
  }

  func testPermissionTestIdentityUsesSuffixSpecificDomain() {
    let identity = AIReaderAppIdentity.from("dev-permission:Smoke Run")

    XCTAssertEqual(identity?.kind, .dev)
    XCTAssertEqual(identity?.displayName, "AI Reader Dev - smoke-run")
    XCTAssertEqual(identity?.bundleIdentifier, "com.hapticasensorics.AIReader.dev.permission.smoke-run")
    XCTAssertEqual(identity?.preferencesDomain, "com.hapticasensorics.AIReader.dev.permission.smoke-run")
    XCTAssertEqual(
      AIReaderAppIdentity.fromBundleIdentifier("com.hapticasensorics.AIReader.dev.permission.smoke-run"),
      identity
    )
  }
}
