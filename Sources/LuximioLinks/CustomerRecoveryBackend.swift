import Foundation

/// Native customer recovery. Configured identifiers select scope; only native
/// App Attest evidence, verified by the service, establishes the installed identity.
@MainActor
public final class CustomerRecoveryBackend: ContinuationBackend, CustomerRecoveryProofClient {
    private let configuration: LinksConfiguration
    private let transport: any ContinuationHTTPTransport
    private let now: @MainActor () -> Date
    private let keyManager: CustomerRecoveryKeyManager
    private let directBackend: HTTPContinuationBackend

    public init(configuration: LinksConfiguration, containerURL: URL?,
                appAttest: any RecoveryAppAttestProviding = SystemRecoveryAppAttestProvider(),
                transport: any ContinuationHTTPTransport = OwnedContinuationHTTPTransport(responseLimit: .customerRecovery),
                now: @escaping @MainActor () -> Date = { Date() }) throws {
        let bundleID = configuration.role == .fullApp ? configuration.scope.fullAppBundleID : configuration.scope.clipBundleID
        try configuration.validate(bundleIdentifier: bundleID)
        self.configuration = configuration
        self.transport = transport
        self.now = now
        self.keyManager = try CustomerRecoveryKeyManager(configuration: configuration, containerURL: containerURL,
                                                        provider: appAttest, now: now)
        self.directBackend = try HTTPContinuationBackend(configuration: configuration, transport: transport, now: now)
    }

    /// Private prototype inspection is synchronous and opt-in. Events contain
    /// only a closed purpose, stage and safe failure classifications.
    @_spi(PrivatePrototype)
    public func observeProofDiagnostics(_ observer: @escaping @MainActor (CustomerRecoveryProofDiagnostic) -> Void) {
        keyManager.observeProofDiagnostics(observer)
    }

    public func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        try Task.checkCancellation()
        try invocation.validate(configuration: configuration, now: now())
        let origin = try invocationOrigin(invocation)
        let payload = try CustomerRecoveryWire.createPayload(invocation: invocation)
        return try await keyManager.withProof(purpose: .create, invocation: invocation, payload: payload, client: self) { assertion in
            let body = try CustomerRecoveryWire.envelope(payload: payload, proof: CustomerRecoveryWire.assertion(assertion))
            let data = try await self.send(path: CustomerRecoveryPurpose.create.path, origin: origin,
                                           bearer: invocation.token, body: body, success: [200, 201])
            return try CustomerRecoveryWire.preparedReceipt(data, invocation: invocation,
                configuration: self.configuration, expected: nil, now: self.now())
        }
    }

    public func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt {
        try Task.checkCancellation()
        try receipt.validate(configuration: configuration, now: now())
        let origin = try invocationOrigin(receipt.invocation)
        let payload = try CustomerRecoveryWire.resolvePayload(receipt: receipt)
        return try await keyManager.withProof(purpose: .resolve, invocation: receipt.invocation, payload: payload, client: self) { assertion in
            let body = try CustomerRecoveryWire.envelope(payload: payload, proof: CustomerRecoveryWire.assertion(assertion))
            let data = try await self.send(path: CustomerRecoveryPurpose.resolve.path, origin: origin,
                                           bearer: receipt.invocation.token, body: body, success: [200])
            return try CustomerRecoveryWire.preparedReceipt(data, invocation: receipt.invocation,
                configuration: self.configuration, expected: receipt, now: self.now())
        }
    }

    public func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        try Task.checkCancellation()
        try receipt.validate(configuration: configuration, now: now())
        guard acknowledgement.receiptID == receipt.id, acknowledgement.deliveryID == receipt.deliveryID else { throw LinkFailure.conflict }
        let origin = try invocationOrigin(receipt.invocation)
        let payload = try CustomerRecoveryWire.acknowledgementPayload(acknowledgement, scope: configuration.scope)
        try await keyManager.withProof(purpose: .acknowledge, invocation: receipt.invocation, payload: payload, client: self) { assertion in
            let body = try CustomerRecoveryWire.envelope(payload: payload, proof: CustomerRecoveryWire.assertion(assertion))
            let data = try await self.send(path: CustomerRecoveryPurpose.acknowledge.path, origin: origin,
                                           bearer: receipt.invocation.token, body: body, success: [200])
            try CustomerRecoveryWire.validateAcknowledgement(data, expected: acknowledgement)
        }
    }

    public func resolveDirect(_ url: URL) async throws -> LinkDestination {
        try await directBackend.resolveDirect(url)
    }

    func operationChallenge(purpose: CustomerRecoveryPurpose, invocation: CapturedInvocation,
                            payload: Data) async throws -> CustomerRecoveryChallenge {
        try invocation.validate(configuration: configuration, now: now())
        return try await challenge(purpose: purpose.rawValue, payload: payload, bearer: invocation.token,
                                   origin: invocationOrigin(invocation))
    }

    func registrationChallenge(keyID: String, bearer: String, origin: URL) async throws -> CustomerRecoveryChallenge {
        let payload = try CustomerRecoveryWire.registrationPayload(keyID: keyID, scope: configuration.scope)
        return try await challenge(purpose: "register", payload: payload, bearer: bearer, origin: origin)
    }

    func submitRegistration(keyID: String, evidence: CustomerRecoveryRegistrationEvidence,
                            bearer: String, origin: URL) async throws -> CustomerRecoveryRegisteredKey {
        guard !evidence.attestationObject.isEmpty, evidence.attestationObject.count <= 16_384 else { throw LinkFailure.invalidData }
        let payload = try CustomerRecoveryWire.registrationPayload(keyID: keyID, scope: configuration.scope)
        let body = try CustomerRecoveryWire.envelope(payload: payload, proof: .object([
            "challengeID": .string(evidence.challengeID.uuidString.lowercased()),
            "attestationObject": .string(evidence.attestationObject.base64EncodedString())]))
        let data = try await send(path: CustomerRecoveryWire.rootPath + "/register", origin: origin,
                                  bearer: bearer, body: body, success: [200, 201])
        return try CustomerRecoveryWire.registeredKey(data, keyID: keyID, now: now())
    }

    private func challenge(purpose: String, payload: Data, bearer: String, origin: URL) async throws -> CustomerRecoveryChallenge {
        let challengePayload = try CustomerRecoveryWire.challengePayload(purpose: purpose, payload: payload, scope: configuration.scope)
        let body = try CustomerRecoveryWire.envelope(payload: challengePayload, proof: .null)
        let data = try await send(path: CustomerRecoveryWire.rootPath + "/challenges", origin: origin,
                                  bearer: bearer, body: body, success: [201])
        return try CustomerRecoveryWire.validateChallenge(data, purpose: purpose, payload: payload, bearer: bearer,
                                                          origin: origin, scope: configuration.scope, now: now())
    }

    private func invocationOrigin(_ invocation: CapturedInvocation) throws -> URL {
        guard let url = URL(string: invocation.originalURL) else { throw LinkFailure.untrustedURL }
        try configuration.validateURL(url)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.port == nil, components.fragment == nil,
              let host = components.host, invocation.originalURL.hasPrefix("https://" + host + "/"),
              !invocation.originalURL.unicodeScalars.contains(where: {
                  $0.value <= 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x5c
              }),
              let decoded = components.percentEncodedPath.removingPercentEncoding else { throw LinkFailure.wrongScope }
        let path = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, path.utf16.count <= 200, !decoded.contains("//"),
              path.range(of: #"^[A-Za-z0-9][A-Za-z0-9/_-]*\z"#, options: .regularExpression) != nil,
              path != "api", path != "healthz", !path.hasPrefix("api/"),
              !components.percentEncodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let origin = URL(string: "https://" + host) else { throw LinkFailure.wrongScope }
        return origin
    }

    private func send(path: String, origin: URL, bearer: String, body: Data, success: Set<Int>) async throws -> Data {
        do {
            try Task.checkCancellation()
            try configuration.validateURL(origin)
            guard origin.absoluteString == "https://" + (origin.host ?? ""),
                  body.count <= CustomerRecoveryWire.maximumBodyBytes else { throw LinkFailure.invalidData }
            // Reuse captured-invocation token validation without persisting or
            // exposing the registration capability in any JSON body.
            let encodedBearer = bearer.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let bytes = try CustomerRecoveryWire.base64(encodedBearer + "=", maximumBytes: 32, exactBytes: 32)
            guard bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == bearer,
                  let endpoint = URL(string: origin.absoluteString + path) else { throw LinkFailure.invalidData }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.mimeType == "application/json", data.count <= CustomerRecoveryWire.maximumBodyBytes,
                  response.expectedContentLength <= Int64(CustomerRecoveryWire.maximumBodyBytes) else { throw LinkFailure.invalidData }
            if success.contains(response.statusCode) { return data }
            guard (400...599).contains(response.statusCode) else { throw LinkFailure.invalidData }
            throw try CustomerRecoveryWire.rejection(data, status: response.statusCode)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let failure = error as? LinkFailure { throw failure }
            throw LinkFailure.network
        }
    }
}
