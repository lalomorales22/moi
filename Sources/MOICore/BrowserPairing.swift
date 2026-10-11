import Foundation
import Security

public struct BrowserInvitation: Equatable, Sendable {
    let code: String
    public let expiresAt: Date

    public func url(base: URL) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        // Fragments stay out of HTTP request targets and are erased by the browser client.
        parts?.fragment = "pair=" + code
        return parts?.url
    }
}

/// Station-scoped credentials. The permanent API key never enters this store.
final class BrowserPairing {
    static let invitationLifetime: TimeInterval = 120
    static let sessionLifetime: TimeInterval = 8 * 60 * 60
    static let maximumSessions = 16
    private let now: () -> Date
    private(set) var invitation: BrowserInvitation?
    private var sessions: [String: Date] = [:]

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    var sessionCount: Int { prune(); return sessions.count }

    @discardableResult func refresh() throws -> Bool {
        prune()
        if let invitation, invitation.expiresAt > now() { return false }
        invitation = try newInvitation()
        return true
    }

    func exchange(_ authorization: String?) throws -> String {
        prune()
        guard let invitation, invitation.expiresAt > now(),
              APIJSON.authorized(authorization, key: invitation.code) else {
            throw MOIError(401, "This pairing code expired or was already used. Scan the current QR in MOI → Connect.")
        }
        guard sessions.count < Self.maximumSessions else {
            throw MOIError(429, "MOI has 16 paired browser sessions. Tap Disconnect paired browsers on the iPhone, then scan again.")
        }
        let token = try Self.randomToken(prefix: "moi_browser_")
        let next = try newInvitation()
        // No suspension between consuming the code and issuing the new invitation.
        self.invitation = next
        sessions[token] = now().addingTimeInterval(Self.sessionLifetime)
        return token
    }

    func authorized(_ authorization: String?) -> Bool {
        prune()
        return sessions.keys.contains { APIJSON.authorized(authorization, key: $0) }
    }

    func revoke(_ authorization: String?) {
        sessions = sessions.filter { !APIJSON.authorized(authorization, key: $0.key) }
    }

    func reset() { invitation = nil; sessions.removeAll() }

    private func prune() { sessions = sessions.filter { $0.value > now() } }
    private func newInvitation() throws -> BrowserInvitation {
        BrowserInvitation(code: try Self.randomToken(prefix: ""), expiresAt: now().addingTimeInterval(Self.invitationLifetime))
    }
    private static func randomToken(prefix: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MOIError(500, "Could not create a pairing code. Stop and restart serving.")
        }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
