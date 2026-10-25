import Foundation
import Testing
@testable import LuximioLinks

struct LinkTypesTests {
    private let scope = LinkScope(projectID: "project-test", fullAppBundleID: "app.test.full",
                                  clipBundleID: "app.test.full.Clip")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var configuration: LinksConfiguration {
        LinksConfiguration(scope: scope, role: .appClip, trustedHosts: ["links.example.com"],
                           appGroupIdentifier: "group.app.test.full")
    }

    @Test func valuesUsePlainJSONAndPreserveFutureFields() throws {
        let json = Data(#"{"route":"places/detail","data":{"id":"north","future":{"enabled":true,"items":[null,2.5,"text"]}}}"#.utf8)
        let destination = try JSONDecoder().decode(LinkDestination.self, from: json)
        try destination.validate()
        #expect(destination.data["future"] == .object([
            "enabled": .bool(true), "items": .array([.null, .number(2.5), .string("text")])
        ]))
        #expect(try JSONDecoder().decode(LinkDestination.self, from: JSONEncoder().encode(destination)) == destination)
    }

    @Test(arguments: ["https://example.com/a", "places/../detail", "places/./detail", "places//detail",
                      "places/detail/", "places/detail?x=1", "places/detail#top", "places/detail\n", "", String(repeating: "a", count: 201)])
    func rejectsUnsafeRoutes(_ route: String) {
        #expect(throws: LinkFailure.invalidData) { try LinkDestination(route: route, data: [:]).validate() }
    }

    @Test(arguments: ["__proto__", "constructor", "prototype", "", String(repeating: "k", count: 65)])
    func rejectsInvalidJSONKeys(_ key: String) {
        #expect(throws: LinkFailure.invalidData) {
            try LinkDestination(route: "places/detail", data: [key: .null]).validate()
        }
    }

    @Test func rejectsExcessiveBytesNodesDepthAndNonfiniteNumbers() {
        #expect(throws: LinkFailure.invalidData) {
            try LinkDestination(route: "place", data: ["text": .string(String(repeating: "x", count: 4_096))]).validate()
        }
        #expect(throws: LinkFailure.invalidData) {
            try LinkDestination(route: "place", data: ["values": .array(Array(repeating: .null, count: 256))]).validate()
        }
        var deep: LinkValue = .null
        for _ in 0..<7 { deep = .array([deep]) }
        #expect(throws: LinkFailure.invalidData) {
            try LinkDestination(route: "place", data: ["value": deep]).validate()
        }
        #expect(throws: LinkFailure.invalidData) {
            try JSONEncoder().encode(LinkValue.number(.infinity))
        }
    }

    @Test(arguments: ["http://links.example.com/north", "https://evil.links.example.com/north",
                      "https://links.example.com.evil.test/north", "https://user:pass@links.example.com/north",
                      "https://links.example.com:8443/north", "https://links.example.com./north"])
    func onlyExactHTTPSOriginsAreTrusted(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(throws: LinkFailure.untrustedURL) { try configuration.validateURL(url) }
    }

    @Test func roleMustMatchBundleMetadata() {
        #expect(throws: LinkFailure.configuration) { try configuration.validate(bundleIdentifier: scope.fullAppBundleID) }
        #expect(throws: Never.self) { try configuration.validate(bundleIdentifier: scope.clipBundleID) }
    }

    @Test func capturePreservesExactPlatformURLAndUsesFiniteOriginalDeadline() throws {
        let url = try #require(URL(string: "https://links.example.com/north?future=x%2By&utm_source=one&utm_source=two"))
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: now)
        #expect(invocation.originalURL == url.absoluteString)
        #expect(invocation.token.utf8.count == 43)
        #expect(invocation.expiresAt == now.addingTimeInterval(CapturedInvocation.lifetime))
        #expect(throws: LinkFailure.expired) {
            try invocation.validate(configuration: configuration, now: invocation.expiresAt)
        }
        #expect(invocation.debugDescription.contains(url.absoluteString) == false)
        let tokenIsRedacted = invocation.debugDescription.contains(invocation.token) == false
        #expect(tokenIsRedacted)
    }

    @Test func receiptCannotExtendCaptureExpiryOrChangeScope() throws {
        let url = try #require(URL(string: "https://links.example.com/north"))
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: now)
        let receipt = PinnedReceipt(id: UUID(), deliveryID: UUID(), invocation: invocation, canonicalLinkID: "link-1",
                                    destination: LinkDestination(route: "places/detail", data: ["id": .string("north")]),
                                    expiresAt: invocation.expiresAt.addingTimeInterval(1))
        #expect(throws: LinkFailure.invalidData) { try receipt.validate(configuration: configuration, now: now) }
        #expect(throws: LinkFailure.wrongScope) {
            try invocation.validate(scope: LinkScope(projectID: "different", fullAppBundleID: scope.fullAppBundleID,
                                                     clipBundleID: scope.clipBundleID), now: now)
        }
    }
}
