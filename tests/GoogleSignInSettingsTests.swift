import Foundation

@main
enum GoogleSignInSettingsTests {
    static func main() throws {
        let clientID = "123456789-example.apps.googleusercontent.com"
        let scheme = "com.googleusercontent.apps.123456789-example"
        func info(_ client: Any? = nil, schemes: Any? = nil) -> [String: Any] {
            ["GIDClientID": client ?? clientID, "CFBundleURLTypes": [["CFBundleURLSchemes": schemes ?? [scheme]]]]
        }
        var count = 0
        func expectIssue(_ name: String, _ info: [String: Any], _ expected: GoogleSignInSettings.Issue) throws {
            do {
                _ = try GoogleSignInSettings(infoDictionary: info)
                fatalError("\(name): invalid settings accepted")
            } catch let issue as GoogleSignInSettings.Issue {
                precondition(issue == expected, "\(name): unexpected issue \(issue)")
                count += 1
            }
        }
        try expectIssue("missing client", [:], .missingClientID)
        try expectIssue("empty PoC client", info("", schemes: ["io.github.pin0o.ccviewer-poc.google"]), .missingClientID)
        try expectIssue("whitespace client", info(" \n"), .missingClientID)
        try expectIssue("non-string client", info(123), .missingClientID)
        try expectIssue("unexpanded build setting", info("$(GIDClientID)"), .invalidClientID)
        try expectIssue("invalid client", info("example.com"), .invalidClientID)
        try expectIssue("trailing newline", info(clientID + "\n"), .invalidClientID)
        try expectIssue("missing URL types", ["GIDClientID": clientID], .missingCallbackScheme)
        try expectIssue("placeholder callback", info(schemes: ["io.github.pin0o.ccviewer-poc.google"]), .missingCallbackScheme)
        try expectIssue("different client's callback", info(schemes: ["com.googleusercontent.apps.other-client"]), .missingCallbackScheme)
        try expectIssue("malformed schemes", info(schemes: 123), .invalidCallbackSchemes)
        try expectIssue("malformed URL types", ["GIDClientID": clientID, "CFBundleURLTypes": "invalid"], .invalidCallbackSchemes)
        try expectIssue("mixed scheme types", info(schemes: [scheme, 123] as [Any]), .invalidCallbackSchemes)
        let malformedSiblingTypes: [[String: Any]] = [
            ["CFBundleURLSchemes": [scheme]], ["CFBundleURLSchemes": 123],
        ]
        try expectIssue("malformed sibling entry", [
            "GIDClientID": clientID,
            "CFBundleURLTypes": malformedSiblingTypes,
        ], .invalidCallbackSchemes)

        let valid = try GoogleSignInSettings(infoDictionary: info())
        precondition(valid.clientID == clientID && valid.callbackScheme == scheme)
        count += 1
        let uppercase = try GoogleSignInSettings(infoDictionary: info(schemes: [scheme.uppercased()]))
        precondition(uppercase.callbackScheme == scheme)
        count += 1
        var multipleProviders = info(schemes: ["io.github.pin0o.ccviewer-poc.dropbox"])
        multipleProviders["CFBundleURLTypes"] = [
            ["CFBundleURLSchemes": ["io.github.pin0o.ccviewer-poc.dropbox"]],
            ["CFBundleURLSchemes": [scheme]],
        ]
        _ = try GoogleSignInSettings(infoDictionary: multipleProviders)
        count += 1
        print("Google sign-in settings: \(count) regression cases passed")
    }
}
