import Foundation

/// Validate before entering Google Sign-In, which raises Objective-C exceptions
/// for missing configuration and unsupported callback schemes.
public struct GoogleSignInSettings: Sendable {
    public enum Issue: Error, Equatable {
        case missingClientID
        case invalidClientID
        case missingCallbackScheme
        case invalidCallbackSchemes
    }

    public let clientID: String
    public let callbackScheme: String

    public init(infoDictionary: [String: Any]) throws {
        guard let clientID = infoDictionary["GIDClientID"] as? String,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Issue.missingClientID
        }
        guard clientID.range(of: #"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,
                             options: .regularExpression) != nil,
              clientID == clientID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Issue.invalidClientID
        }
        let callbackScheme = clientID.components(separatedBy: ".").reversed()
            .joined(separator: ".").lowercased()
        let urlTypes: [[String: Any]]
        if let rawTypes = infoDictionary["CFBundleURLTypes"] {
            guard let types = rawTypes as? [[String: Any]] else { throw Issue.invalidCallbackSchemes }
            urlTypes = types
        } else {
            urlTypes = []
        }
        var supportedSchemes: [String] = []
        for urlType in urlTypes {
            guard let rawSchemes = urlType["CFBundleURLSchemes"] else { continue }
            guard let schemes = rawSchemes as? [String] else { throw Issue.invalidCallbackSchemes }
            supportedSchemes.append(contentsOf: schemes.map { $0.lowercased() })
        }
        guard supportedSchemes.contains(callbackScheme) else {
            throw Issue.missingCallbackScheme
        }
        self.clientID = clientID
        self.callbackScheme = callbackScheme
    }
}
