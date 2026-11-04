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
    static func requirement(for identifier: String, team: String) -> String? {
        guard identifier == appSigningIdentifier || identifier == helperSigningIdentifier,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
