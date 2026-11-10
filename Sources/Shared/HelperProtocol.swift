import Foundation
import Security

let helperMachService = "run.rosie.microgravity.helper"
let helperProtocolVersion = 1
let appSigningIdentifier = "run.rosie.microgravity"
let helperSigningIdentifier = "run.rosie.microgravity.helper"

@objc protocol HelperProtocol {
    func sample(_ request: Data, reply: @escaping (Data) -> Void)
    func terminate(_ request: Data, authorization: Data, reply: @escaping (String) -> Void)
    func capabilities(_ reply: @escaping (Int, [String]) -> Void)
}

enum SigningIdentity {
    static func requirement(for identifier: String) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return requirement(for: identifier, team: team)
    }
    /// Release builds are strict: Developer ID chain, and no entitlements that allow code
    /// injection or disabled library validation. Debug builds keep the team-only form so
    /// development-signed builds still connect.
    static var strictByDefault: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
    static func requirement(for identifier: String, team: String, strict: Bool = strictByDefault) -> String? {
        guard identifier == appSigningIdentifier || identifier == helperSigningIdentifier,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        if strict {
            return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\" and !(entitlement[\"com.apple.security.get-task-allow\"] exists) and !(entitlement[\"com.apple.security.cs.disable-library-validation\"] exists) and !(entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists)"
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
