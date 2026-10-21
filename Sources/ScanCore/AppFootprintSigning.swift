import Foundation
import Security

public struct AppSigning: Sendable, Equatable {
    public var teamID: String?
    public var appGroups: [String]

    public init(teamID: String?, appGroups: [String]) {
        self.teamID = teamID
        self.appGroups = appGroups
    }

    /// Reads a static signature without checking its validity. Nil means the signature could not be read.
    public static func read(bundlePath: String) -> AppSigning? {
        var code: SecStaticCode?
        let url = URL(fileURLWithPath: bundlePath) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return AppSigning(teamID: teamID, appGroups: groups)
    }
}
