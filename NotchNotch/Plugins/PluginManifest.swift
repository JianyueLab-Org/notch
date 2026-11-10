//
//  PluginManifest.swift
//  NotchNotch
//
//  `<plugin dir>/manifest.json`. Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated struct PluginManifest: Equatable, Sendable {
    enum Kind: String, Sendable {
        case managed    // the core launches `executable`
        case external   // another program runs it; the core only registers it
    }

    static let currentAPIVersion = 1

    let id: String
    let name: [String: String]
    let version: String
    let kind: Kind
    let executable: String?
    let apiVersion: Int

    func displayName(isChinese: Bool) -> String {
        (isChinese ? name["zh-Hans"] : nil) ?? name["en"] ?? id
    }

    static func load(from url: URL) -> Result<PluginManifest, PluginManifestError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return decode(data)
    }

    static func decode(_ data: Data) -> Result<PluginManifest, PluginManifestError> {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        guard let id = dict["id"] as? String else { return .failure(.missingField("id")) }
        guard id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            return .failure(.badID(id))
        }
        guard let name = dict["name"] as? [String: String] else { return .failure(.missingField("name")) }
        guard name["en"]?.isEmpty == false else { return .failure(.missingField("name.en")) }
        guard let version = dict["version"] as? String else { return .failure(.missingField("version")) }
        guard let rawKind = dict["kind"] as? String else { return .failure(.missingField("kind")) }
        guard let kind = Kind(rawValue: rawKind) else { return .failure(.badKind(rawKind)) }
        guard let apiVersion = dict["apiVersion"] as? Int else { return .failure(.missingField("apiVersion")) }
        guard apiVersion == currentAPIVersion else { return .failure(.unsupportedAPI(apiVersion)) }

        let executable = dict["executable"] as? String
        if kind == .managed {
            guard let executable, !executable.isEmpty else { return .failure(.managedWithoutExecutable) }
            // A plain file name inside the plugin directory, never a path out of it.
            guard !executable.contains("/"), executable != ".", executable != ".." else {
                return .failure(.executableEscapes(executable))
            }
        }
        return .success(PluginManifest(
            id: id, name: name, version: version, kind: kind,
            executable: kind == .managed ? executable : nil,
            apiVersion: apiVersion
        ))
    }
}

nonisolated enum PluginManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable
    case invalidJSON
    case missingField(String)
    case badID(String)
    case badKind(String)
    case unsupportedAPI(Int)
    case managedWithoutExecutable
    case executableEscapes(String)
    case duplicateID(String)

    var description: String {
        switch self {
        case .unreadable: return "manifest.json missing or unreadable"
        case .invalidJSON: return "manifest.json is not a JSON object"
        case .missingField(let field): return "missing field \(field)"
        case .badID(let id): return "invalid id \(id)"
        case .badKind(let kind): return "unknown kind \(kind)"
        case .unsupportedAPI(let version): return "apiVersion \(version) is not supported (expected \(PluginManifest.currentAPIVersion))"
        case .managedWithoutExecutable: return "managed plugin without executable"
        case .executableEscapes(let path): return "executable must be a file name, got \(path)"
        case .duplicateID(let id): return "duplicate id \(id)"
        }
    }
}
