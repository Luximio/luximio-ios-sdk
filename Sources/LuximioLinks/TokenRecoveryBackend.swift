import Foundation

/// Explicit capability recovery. Possessing the token does not attest an app,
/// device or person and never authorizes customer resources. Construct this
/// adapter with TokenRecoverySession so it is paired with its own journal.
@MainActor
public final class TokenRecoveryBackend: ContinuationBackend {
    private let configuration: LinksConfiguration
    private let journal: ContinuationJournal
    private let transport: any ContinuationHTTPTransport
    private let now: @MainActor () -> Date
    private let directBackend: HTTPContinuationBackend
    private static let root = "/api/v1/token-recovery"

    init(configuration: LinksConfiguration, journal: ContinuationJournal,
         transport: any ContinuationHTTPTransport, now: @escaping @MainActor () -> Date) throws {
        self.configuration = configuration
        self.journal = journal
        self.transport = transport
        self.now = now
        directBackend = try HTTPContinuationBackend(configuration: configuration, transport: transport, now: now)
    }

    public func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        try Task.checkCancellation()
        try invocation.validate(configuration: configuration, now: now())
        let entry = try stored(invocation)
        guard entry.phase == .captured, entry.receipt == nil else { throw LinkFailure.unverifiedContext }
        let body = try CustomerRecoveryWire.envelope(payload: CustomerRecoveryWire.createPayload(invocation: invocation), proof: .null)
        let data = try await send(path: Self.root, invocation: invocation, body: body, success: [200, 201])
        return try CustomerRecoveryWire.preparedReceipt(data, invocation: invocation,
            configuration: configuration, expected: nil, now: now())
    }

    public func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt {
        try Task.checkCancellation()
        try receipt.validate(configuration: configuration, now: now())
        let entry = try stored(receipt.invocation)
        guard entry.receipt == receipt, [.pinned, .held].contains(entry.phase),
              try journal.pending()?.invocation.id == receipt.invocation.id else { throw LinkFailure.unverifiedContext }
        let body = try CustomerRecoveryWire.envelope(payload: CustomerRecoveryWire.resolvePayload(receipt: receipt), proof: .null)
        let data = try await send(path: Self.root + "/resolve", invocation: receipt.invocation, body: body, success: [200])
        return try CustomerRecoveryWire.preparedReceipt(data, invocation: receipt.invocation,
            configuration: configuration, expected: receipt, now: now())
    }

    public func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        try Task.checkCancellation()
        try receipt.validate(configuration: configuration, now: now())
        guard acknowledgement.receiptID == receipt.id, acknowledgement.deliveryID == receipt.deliveryID else {
            throw LinkFailure.conflict
        }
        let entry = try stored(receipt.invocation)
        let phase: JournalPhase = acknowledgement.outcome == .applied ? .applied : .discarded
        guard entry.receipt == receipt, entry.phase == phase, entry.acknowledgement == acknowledgement else {
            throw LinkFailure.unverifiedContext
        }
        let body = try CustomerRecoveryWire.envelope(payload:
            CustomerRecoveryWire.acknowledgementPayload(acknowledgement, scope: configuration.scope), proof: .null)
        let data = try await send(path: Self.root + "/acknowledge", invocation: receipt.invocation,
                                  body: body, success: [200])
        try CustomerRecoveryWire.validateAcknowledgement(data, expected: acknowledgement)
    }

    public func resolveDirect(_ url: URL) async throws -> LinkDestination {
        try await directBackend.resolveDirect(url)
    }

    private func stored(_ invocation: CapturedInvocation) throws -> JournalEntry {
        guard let entry = try journal.entry(id: invocation.id), entry.invocation == invocation else {
            throw LinkFailure.unverifiedContext
        }
        return entry
    }

    private func origin(_ invocation: CapturedInvocation) throws -> URL {
        guard let original = URL(string: invocation.originalURL) else { throw LinkFailure.untrustedURL }
        try configuration.validateURL(original)
        guard let parts = URLComponents(url: original, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.fragment == nil,
              let host = parts.host, invocation.originalURL.hasPrefix("https://" + host + "/"),
              !invocation.originalURL.unicodeScalars.contains(where: {
                  $0.value <= 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x5c
              }), let path = parts.percentEncodedPath.removingPercentEncoding else { throw LinkFailure.wrongScope }
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty, normalized.utf16.count <= 200, !path.contains("//"),
              normalized.range(of: #"^[A-Za-z0-9][A-Za-z0-9/_-]*\z"#, options: .regularExpression) != nil,
              normalized != "api", normalized != "healthz", !normalized.hasPrefix("api/"),
              !parts.percentEncodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let origin = URL(string: "https://" + host) else { throw LinkFailure.wrongScope }
        return origin
    }

    private func send(path: String, invocation: CapturedInvocation, body: Data,
                      success: Set<Int>) async throws -> Data {
        do {
            try Task.checkCancellation()
            // This includes the canonical unpadded 32-byte capability check.
            try invocation.validate(configuration: configuration, now: now())
            let origin = try origin(invocation)
            guard body.count <= CustomerRecoveryWire.maximumBodyBytes,
                  [Self.root, Self.root + "/resolve", Self.root + "/acknowledge"].contains(path),
                  let endpoint = URL(string: origin.absoluteString + path) else { throw LinkFailure.invalidData }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + invocation.token, forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.mimeType == "application/json", data.count <= CustomerRecoveryWire.maximumBodyBytes,
                  response.expectedContentLength <= Int64(CustomerRecoveryWire.maximumBodyBytes) else {
                throw LinkFailure.invalidData
            }
            if success.contains(response.statusCode) { return data }
            guard (400...599).contains(response.statusCode) else { throw LinkFailure.invalidData }
            throw try CustomerRecoveryWire.rejection(data, status: response.statusCode)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? LinkFailure { throw failure }
            throw LinkFailure.network
        }
    }
}
