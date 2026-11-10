import Darwin
import Security
import XCTest
@testable import Microgravity

final class IntegrationSecurityTests: XCTestCase {
    func testSigningRequirementsRejectUnknownIdentifierAndInjectedTeam() {
        for strict in [false, true] {
            XCTAssertNil(SigningIdentity.requirement(for: "other", team: "ABCDE12345", strict: strict))
            XCTAssertNil(SigningIdentity.requirement(for: appSigningIdentifier, team: "ABC\" or true", strict: strict))
            XCTAssertNil(SigningIdentity.requirement(for: appSigningIdentifier, team: "", strict: strict))
        }
        let loose = SigningIdentity.requirement(for: appSigningIdentifier, team: "ABCDE12345", strict: false)
        XCTAssertTrue(loose?.contains("anchor apple generic") == true)
        XCTAssertTrue(loose?.contains("identifier \"run.rosie.microgravity\"") == true)
        XCTAssertTrue(loose?.contains("subject.OU] = \"ABCDE12345\"") == true)
        XCTAssertFalse(loose?.contains("field.1.2.840.113635.100.6.2.6") == true)
        XCTAssertFalse(loose?.contains("field.1.2.840.113635.100.6.1.13") == true)

        let strict = SigningIdentity.requirement(for: appSigningIdentifier, team: "ABCDE12345", strict: true)
        XCTAssertTrue(strict?.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists") == true)
        XCTAssertTrue(strict?.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists") == true)
        XCTAssertTrue(strict?.contains("subject.OU] = \"ABCDE12345\"") == true)
        XCTAssertTrue(strict?.contains("identifier \"run.rosie.microgravity\"") == true)
        for key in ["com.apple.security.get-task-allow",
                    "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-dyld-environment-variables"] {
            XCTAssertTrue(strict?.contains("!(entitlement[\"\(key)\"] exists)") == true)
        }
        // A malformed requirement would make Release reject every client, so both forms must parse.
        for requirement in [loose, strict] {
            guard let text = requirement else { return XCTFail("requirement must be produced") }
            var compiled: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &compiled), errSecSuccess)
        }
    }
    func testConsumedAuthorizationIsReportedUntilItExpires() {
        let form = Data(repeating: 0x9E, count: 32)
        let now = Date()
        XCTAssertTrue(TerminationService.consumeAuthorizationForm(form, now: now))
        XCTAssertTrue(TerminationService.hasUnexpiredConsumedAuthorizations(now: now))
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
    func testAllowedTargetSignalsRequestedPIDExactlyOnce() {
        let form = Data(repeating: 0x2F, count: 32)
        let requested = HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3)
        let valid = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        guard case let .allowed(target) = TerminationService.authorizeTarget(
            requested, authorization: form, clientPID: 50, observed: { _ in valid }) else {
            return XCTFail("a validated target must be allowed")
        }

        var sent: [(pid: pid_t, signal: Int32)] = []
        let outcome = TerminationService.deliverSignal(to: target.pid, force: true) { pid, signal in
            sent.append((pid, signal))
            return 0
        }
        XCTAssertEqual(outcome, "signalSent")
        XCTAssertEqual(sent.count, 1, "exactly one kill call per authorized termination")
        XCTAssertEqual(sent.first?.pid, pid_t(requested.pid))
        XCTAssertEqual(sent.first?.signal, SIGKILL)
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

    /// Creates a real external form with no rights (no UI). The reference must stay alive
    /// while perform runs, as the app keeps it alive until the helper replies.
    private func makeAuthorization() throws -> (reference: AuthorizationRef, form: Data) {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        XCTAssertEqual(created, errAuthorizationSuccess)
        let ref = try XCTUnwrap(reference)
        var external = AuthorizationExternalForm()
        let exported = AuthorizationMakeExternalForm(ref, &external)
        XCTAssertEqual(exported, errAuthorizationSuccess)
        return (ref, withUnsafeBytes(of: &external) { Data($0) })
    }

    private func payload(_ target: HelperTargetIdentity, force: Bool = false) throws -> Data {
        try JSONEncoder().encode(HelperTerminationPayload(version: helperProtocolVersion, target: target, force: force))
    }

    func testRejectedTargetNeverPromptsAndDoesNotConsumeForm() throws {
        let (reference, form) = try makeAuthorization()
        defer { AuthorizationFree(reference, []) }
        let stale = HelperTarget(pid: 42, seconds: 9, microseconds: 3, owner: 501, protected: false)
        let data = try payload(HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3))
        var prompted = false
        var signalled = false
        let result = TerminationService.perform(data, authorization: form, clientPID: 50,
            lookup: { _ in stale },
            authorize: { _, _ in prompted = true; return .granted },
            send: { _, _ in signalled = true; return 0 })
        XCTAssertEqual(result, "targetRejected")
        XCTAssertFalse(prompted, "a rejected target must never reach the approval dialog")
        XCTAssertFalse(signalled)
        XCTAssertTrue(TerminationService.consumeAuthorizationForm(form), "a rejected target must leave the form unused")
    }

    func testDeniedApprovalNeverSignals() throws {
        let (reference, form) = try makeAuthorization()
        defer { AuthorizationFree(reference, []) }
        let valid = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        let data = try payload(HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3))
        var signalled = false
        let result = TerminationService.perform(data, authorization: form, clientPID: 50,
            lookup: { _ in valid },
            authorize: { _, _ in .denied },
            send: { _, _ in signalled = true; return 0 })
        XCTAssertEqual(result, "authorizationDenied")
        XCTAssertFalse(signalled)
    }

    func testTargetChangedOrExitedDuringApprovalIsRejected() throws {
        let valid = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        let reused = HelperTarget(pid: 42, seconds: 11, microseconds: 3, owner: 501, protected: false)
        let data = try payload(HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3))
        for replacement in [reused, nil] as [HelperTarget?] {
            let (reference, form) = try makeAuthorization()
            defer { AuthorizationFree(reference, []) }
            // The first two lookups see the valid target; the approval then changes what the helper observes.
            var observed: HelperTarget? = valid
            var signalled = false
            let result = TerminationService.perform(data, authorization: form, clientPID: 50,
                lookup: { _ in observed },
                authorize: { _, _ in observed = replacement; return .granted },
                send: { _, _ in signalled = true; return 0 })
            XCTAssertEqual(result, "targetRejected")
            XCTAssertFalse(signalled, "no signal may be sent after the target changed")
        }
    }

    func testApprovedUnchangedTargetSignalsRequestedPIDOnce() throws {
        let (reference, form) = try makeAuthorization()
        defer { AuthorizationFree(reference, []) }
        let valid = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        let data = try payload(HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3), force: true)
        var prompts: [String] = []
        var sent: [(pid: pid_t, signal: Int32)] = []
        let result = TerminationService.perform(data, authorization: form, clientPID: 50,
            lookup: { _ in valid },
            authorize: { _, prompt in prompts.append(prompt); return .granted },
            send: { pid, signal in sent.append((pid, signal)); return 0 })
        XCTAssertEqual(result, "signalSent")
        XCTAssertEqual(sent.count, 1, "exactly one kill call per approved termination")
        XCTAssertEqual(sent.first?.pid, 42)
        XCTAssertEqual(sent.first?.signal, SIGKILL)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.first?.contains("(PID 42)") == true)
    }

    func testLateApprovalOrDisconnectedClientNeverSignals() throws {
        let valid = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        let data = try payload(HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3))
        let start = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(elapsed: TimeInterval, connected: Bool, expected: String)] = [
            (TerminationService.approvalDeadline + 1, true, "approvalExpired"),
            (1, false, "approvalExpired"),
            (TerminationService.approvalDeadline, true, "signalSent"),
        ]
        for testCase in cases {
            let (reference, form) = try makeAuthorization()
            defer { AuthorizationFree(reference, []) }
            var approved = false
            var sent = 0
            let result = TerminationService.perform(data, authorization: form, clientPID: 50,
                lookup: { _ in valid },
                authorize: { _, _ in approved = true; return .granted },
                send: { _, _ in sent += 1; return 0 },
                clientConnected: { testCase.connected },
                now: { approved ? start.addingTimeInterval(testCase.elapsed) : start })
            XCTAssertEqual(result, testCase.expected, "elapsed \(testCase.elapsed) connected \(testCase.connected)")
            XCTAssertEqual(sent, testCase.expected == "signalSent" ? 1 : 0)
        }
    }

    func testStoredRuleMustKeepSecuritySettings() {
        XCTAssertTrue(TerminationService.ruleMatches(TerminationService.terminationRule))
        var withoutAllowRoot = TerminationService.terminationRule
        withoutAllowRoot.removeValue(forKey: "allow-root")
        XCTAssertTrue(TerminationService.ruleMatches(withoutAllowRoot), "absent allow-root defaults to false")
        for (key, value) in [("allow-root", true as Any), ("shared", true), ("timeout", 300), ("group", "staff"),
                             ("class", "allow"), ("authenticate-user", false)] {
            var weakened = TerminationService.terminationRule
            weakened[key] = value
            XCTAssertFalse(TerminationService.ruleMatches(weakened), "\(key) = \(value) must not match")
        }
        for key in ["shared", "timeout"] {
            var missing = TerminationService.terminationRule
            missing.removeValue(forKey: key)
            XCTAssertFalse(TerminationService.ruleMatches(missing), "absent \(key) must not match")
        }
    }

    func testApprovalTextNamesTheProcessTheHelperLookedUp() throws {
        // A real child gives the helper a live lookup. It is never signalled because the approval is denied.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let pid = child.processIdentifier
        let live = try XCTUnwrap(HelperTerminationPolicy.lookupTarget(pid: pid))
        let (reference, form) = try makeAuthorization()
        defer { AuthorizationFree(reference, []) }
        let data = try payload(HelperTargetIdentity(pid: live.pid, seconds: live.seconds, microseconds: live.microseconds))
        var prompts: [String] = []
        var signalled = false
        let result = TerminationService.perform(data, authorization: form, clientPID: 50,
            authorize: { _, prompt in prompts.append(prompt); return .denied },
            send: { _, _ in signalled = true; return 0 })
        XCTAssertEqual(result, "authorizationDenied")
        XCTAssertFalse(signalled)
        XCTAssertEqual(TerminationService.processName(pid: pid), "sleep")
        XCTAssertTrue(prompts.first?.contains("“sleep” (PID \(pid))") == true, "prompt was \(prompts)")
    }

    func testApprovalTextStripsControlAndFormatCharactersAndCapsTheName() {
        let hostile = "evil\u{7}\n\u{202E}name"
        let text = TerminationService.terminationPrompt(pid: 42, name: hostile)
        XCTAssertTrue(text.contains("“evilname” (PID 42)"), "prompt was \(text)")
        XCTAssertTrue(text.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        })
        let long = String(repeating: "a", count: 100)
        let capped = TerminationService.terminationPrompt(pid: 42, name: long)
        XCTAssertTrue(capped.contains("“" + String(repeating: "a", count: 64) + "”"))
        XCTAssertFalse(capped.contains(String(repeating: "a", count: 65)))
        XCTAssertTrue(TerminationService.terminationPrompt(pid: 42, name: nil).contains("“unknown process”"))
        XCTAssertTrue(TerminationService.terminationPrompt(pid: 42, name: " \n\t").contains("“unknown process”"))
    }

    func testTerminationRightIsNotGrantedWithoutInteraction() throws {
        // Flags without interactionAllowed: authd may not show UI, and nothing is written to the database.
        let (reference, _) = try makeAuthorization()
        defer { AuthorizationFree(reference, []) }
        let status = TerminationService.copyTerminationRight(reference, flags: [], prompt: "Test")
        XCTAssertTrue(status == errAuthorizationDenied || status == errAuthorizationInteractionNotAllowed,
                      "a non-interactive check must not grant the right, got \(status)")
    }
}
