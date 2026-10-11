import XCTest
@testable import MOICore

final class BrowserPairingTests: XCTestCase {
    func testSingleUseExpiryAndRevocation() throws {
        var time = Date(timeIntervalSince1970: 1_000_000)
        let pairing = BrowserPairing(now: { time })
        try pairing.refresh()
        let invitation = try XCTUnwrap(pairing.invitation)
        let link = try XCTUnwrap(invitation.url(base: URL(string: "http://192.0.2.1:8080/")!))
        XCTAssertEqual(link.path, "/")
        XCTAssertNil(URLComponents(url: link, resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(link.fragment, "pair=" + invitation.code)
        XCTAssertFalse(try pairing.refresh(), "Reading/redrawing must not invalidate a live QR")
        let token = try pairing.exchange("Bearer " + invitation.code)
        XCTAssertNotEqual(token, invitation.code)
        XCTAssertTrue(pairing.authorized("Bearer " + token))
        XCTAssertFalse(pairing.authorized("Bearer " + invitation.code))
        XCTAssertNotEqual(pairing.invitation, invitation)
        XCTAssertThrowsError(try pairing.exchange("Bearer " + invitation.code), "Replayed QR must fail")
        pairing.revoke("Bearer " + token)
        XCTAssertFalse(pairing.authorized("Bearer " + token))
        let expiring = try XCTUnwrap(pairing.invitation)
        time = expiring.expiresAt
        XCTAssertThrowsError(try pairing.exchange("Bearer " + expiring.code), "Expiry boundary must reject")
        try pairing.refresh()
        let next = try pairing.exchange("Bearer " + XCTUnwrap(pairing.invitation).code)
        time = time.addingTimeInterval(BrowserPairing.sessionLifetime)
        XCTAssertFalse(pairing.authorized("Bearer " + next))
        XCTAssertEqual(pairing.sessionCount, 0)
    }

    func testBoundedSessionsAndStationReset() throws {
        let pairing = BrowserPairing()
        try pairing.refresh()
        var tokens: [String] = []
        for _ in 0..<BrowserPairing.maximumSessions {
            tokens.append(try pairing.exchange("Bearer " + XCTUnwrap(pairing.invitation).code))
        }
        XCTAssertEqual(pairing.sessionCount, 16)
        let fullInvitation = try XCTUnwrap(pairing.invitation)
        XCTAssertThrowsError(try pairing.exchange("Bearer " + fullInvitation.code))
        XCTAssertEqual(pairing.invitation, fullInvitation)
        pairing.reset()
        XCTAssertNil(pairing.invitation)
        XCTAssertEqual(pairing.sessionCount, 0)
        for token in tokens { XCTAssertFalse(pairing.authorized("Bearer " + token)) }
        try pairing.refresh()
        XCTAssertThrowsError(try pairing.exchange("Bearer " + fullInvitation.code))
    }
}
