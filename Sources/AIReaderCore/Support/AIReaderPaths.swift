import Foundation

public enum AIReaderPaths {
  public static func projectRoot(
    bundle: Bundle = .main,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    if let rawPath = environment["AI_READER_PROJECT_ROOT"], !rawPath.isEmpty {
      return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    if let rawPath = bundle.object(forInfoDictionaryKey: "AIReaderProjectRoot") as? String,
      !rawPath.isEmpty
    {
      return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    let bundleURL = bundle.bundleURL
    if bundleURL.pathExtension == "app" {
      let distDirectory = bundleURL.deletingLastPathComponent()
      if distDirectory.lastPathComponent == "dist" {
        return distDirectory.deletingLastPathComponent()
      }
    }

    var current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    for _ in 0..<5 {
      if fileManager.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        break
      }
      current = parent
    }

    return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
  }

  public static func envFileURL() -> URL {
    projectRoot().appendingPathComponent(".env")
  }

  public static func envExampleURL() -> URL {
    projectRoot().appendingPathComponent(".env.example")
  }

  public static func promptsDirectoryURL() -> URL {
    projectRoot().appendingPathComponent("prompts", isDirectory: true)
  }
}
