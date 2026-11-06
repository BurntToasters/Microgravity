import XCTest
@testable import Microgravity

final class IntegrationSecurityTests: XCTestCase {
    func testSigningRequirementsRejectUnknownIdentifierAndInjectedTeam() {
        XCTAssertNil(SigningIdentity.requirement(for: "other", team: "ABCDE12345"))
        XCTAssertNil(SigningIdentity.requirement(for: appSigningIdentifier, team: "ABC\" or true"))
        XCTAssertNil(SigningIdentity.requirement(for: appSigningIdentifier, team: ""))
        let requirement = SigningIdentity.requirement(for: appSigningIdentifier, team: "ABCDE12345")
        XCTAssertTrue(requirement?.contains("anchor apple generic") == true)
        XCTAssertTrue(requirement?.contains("identifier \"run.rosie.microgravity\"") == true)
        XCTAssertTrue(requirement?.contains("subject.OU] = \"ABCDE12345\"") == true)
    }
    func testInvalidVersionOversizeAndBadAuthorizationFailClosed() throws {
        let target = HelperTarget(pid: 42, seconds: 1, microseconds: 2, owner: 501, protected: false)
        let wrong = try JSONEncoder().encode(HelperTerminationRequest(version: 99, target: target, force: false))
        let valid = try JSONEncoder().encode(HelperTerminationRequest(version: helperProtocolVersion, target: target, force: false))
        let badAuthorization = Data(repeating: 0, count: 32)
        XCTAssertEqual(TerminationService.perform(wrong, authorization: badAuthorization, clientPID: 5), "invalidRequest")
        XCTAssertEqual(TerminationService.perform(Data(repeating: 0, count: 4097), authorization: badAuthorization, clientPID: 5), "invalidRequest")
        XCTAssertNotEqual(TerminationService.perform(valid, authorization: badAuthorization, clientPID: 5), "signalSent")
    }
    func testAuthorizationFormIsSingleUseAndDistinctFormsRemainUsable() {
        let first = Data(repeating: 0xA7, count: 32)
        let second = Data(repeating: 0x5C, count: 32)
        XCTAssertTrue(TerminationService.consumeAuthorizationForm(first))
        XCTAssertFalse(TerminationService.consumeAuthorizationForm(first))
        XCTAssertTrue(TerminationService.consumeAuthorizationForm(second))
        XCTAssertFalse(TerminationService.consumeAuthorizationForm(second))
    }
    func testRejectedTargetDoesNotConsumeAuthorizationForm() {
        let form = Data(repeating: 0x6B, count: 32)
        let requested = HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3)
        let stale = HelperTarget(pid: 42, seconds: 9, microseconds: 3, owner: 501, protected: false)
        let valid = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        XCTAssertEqual(TerminationService.authorizeTarget(requested, authorization: form, clientPID: 50,
                                                          observed: { _ in stale }), .targetRejected)
        XCTAssertEqual(TerminationService.authorizeTarget(requested, authorization: form, clientPID: 50,
                                                          observed: { _ in valid }), .allowed(valid))
        XCTAssertEqual(TerminationService.authorizeTarget(requested, authorization: form, clientPID: 50,
                                                          observed: { _ in valid }), .authorizationDenied)
    }
    func testConsumedAuthorizationFormExpires() {
        let form = Data(repeating: 0x3D, count: 32)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(TerminationService.consumeAuthorizationForm(form, now: start))
        XCTAssertFalse(TerminationService.consumeAuthorizationForm(form, now: start.addingTimeInterval(599)))
        XCTAssertTrue(TerminationService.consumeAuthorizationForm(form, now: start.addingTimeInterval(601)))
    }
    func testMinimalTerminationPayloadOmitsDerivedTargetFields() throws {
        let payload = HelperTerminationPayload(version: helperProtocolVersion,
                                               target: HelperTargetIdentity(pid: 42, seconds: 1, microseconds: 2),
                                               force: false)
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["target"] as? [String: Any])
        XCTAssertEqual(Set(target.keys), Set(["pid", "seconds", "microseconds"]))
        XCTAssertEqual(TerminationService.perform(data, authorization: Data(repeating: 0, count: 32), clientPID: 5), "authorizationDenied")

        // The previous full-target encoding still decodes; the helper ignores
        // client-supplied owner/protected values.
        let legacyTarget = HelperTarget(pid: 42, seconds: 1, microseconds: 2, owner: 501, protected: false)
        let legacy = try JSONEncoder().encode(HelperTerminationRequest(version: helperProtocolVersion, target: legacyTarget, force: false))
        XCTAssertEqual(TerminationService.perform(legacy, authorization: Data(repeating: 0, count: 32), clientPID: 5), "authorizationDenied")
    }
}
