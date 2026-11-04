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
}
