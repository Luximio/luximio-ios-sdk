# Token recovery integration

This guide describes unpublished release candidate `0.1.0-rc.2`. Validate the
reviewed SDK-only local Git mirror as described in the [README](../README.md).
Its candidate tag is not a public release. The public repository's issued
`0.1.0-rc.1` remains unchanged and does not expose scoped erasure.
Customer setup and production recovery remain disabled pending their separate
rollout.

Use one registered project, HTTPS invocation host, full-app bundle ID, child
Clip bundle ID and App Group in both targets and canonical server records.
The iOS publication must explicitly select `recoveryProfile: "token_v1"`;
omission retains the separate attested profile. Configure the matching Apple
association data, associated-domain entitlements, Clip/parent relationship and
signed App Group access for the actual app. Example identities below are
placeholders; configuration values are public identities, never credentials.

Create the paired session on the main actor in each role:

```swift
import Foundation
import LuximioLinks

@MainActor
func makeTokenSession(role: LinksConfiguration.Role) throws
    -> (LinksConfiguration, TokenRecoverySession) {
    let scope = LinkScope(projectID: "customer-project",
        fullAppBundleID: "com.example.customer",
        clipBundleID: "com.example.customer.Clip")
    let configuration = LinksConfiguration(scope: scope, role: role,
        trustedHosts: ["links.example.com"],
        appGroupIdentifier: "group.com.example.customer")
    try configuration.validate(bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    let session = try TokenRecoverySession(configuration: configuration,
        containerURL: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier))
    return (configuration, session)
}
```

Use the returned journal and backend together. Missing or invalid containers
fail closed. Do not substitute a temporary directory or override the actual
bundle identifier. The token namespace never imports an older profile's state.
Retain the coordinator for its role's lifetime. In the full app, supply your
synchronous main-actor `route: (LinkDelivery) -> LinkDisposition` callback:

```swift
let (configuration, session) = try makeTokenSession(role: .fullApp)
let links = try LuximioLinks(configuration: configuration,
    journal: session.journal, backend: session.backend, route: route)
```

In the Clip, link `LuximioLinksAppClip` and still import `LuximioLinks`:

```swift
let (configuration, session) = try makeTokenSession(role: .appClip)
let clip = try LuximioClipLinks(configuration: configuration,
    journal: session.journal, backend: session.backend)
```

Forward fresh Clip invocation URLs to `try await clip.capture(url)`; show capture
success only after it returns. `try await clip.retryCapture()` retries the saved
action without changing its token, operation or original deadline.

The full-app route callback returns `.hold` while onboarding/authentication or
authorization is unresolved, `.discard` for denied/unsupported actions, and
`.applied` only after installing navigation state. Check the current account's
resource permissions through your own app/backend. Use `delivery.id` for
idempotent application. Treat destination data and original query context as
untrusted; a recovery capability grants no resource access.

Call `links.resume(.activation)` on activation and
`links.resume(.readinessChanged)` after readiness/account changes. Activation
does not release an existing hold. Use `links.resume(.userRetry)` for an explicit
retry. Fresh full-app URLs go to `try links.receive(url)`, which invalidates
older recovery first. Before newer manual navigation, call
`try links.cancelPending()` and handle failure before promising cancellation.

For `.uncertainApplication(id)`, obtain explicit user confirmation before
`links.resume(.confirmedContinue(id))` for that delivery. Never auto-confirm it
on restart. Keep completion-sync warnings separate from the visible route.
Holds gate navigation, not collection: capture/resolve can occur before login.
Gate SDK work separately if your app requires a choice before collection.

Verify signed Clip-to-full-app handoff, restart/holds, offline retry, current
permissions, cancellation and replay on the customer's actual setup. Review
[privacy and retention](privacy.md); never log tokens or whole link contexts.

## Erase one completed local handoff

RC2 adds the following main-actor operation:

```swift
let result = try session.eraseCompleted(invocationID: completedInvocationID)
```

Use the session's original project/app/host configuration. Before calling,
verify the case's authority, coordinate the appropriate server handling and stop
new collection/writers for the affected integration. The selected entry must
have a pinned receipt, an applied/discarded phase and no pending acknowledgement.
A normal cancellation or successful ACK is not itself local erasure.

The result is `.erased`, `.alreadyErased` or `.notFound`; absence in this journal
is not an all-system absence result. Active or unacknowledged state fails with
`.busy`; do not clear outboxes or fabricate pins merely to bypass the guard.
The operation does not cancel a different pending handoff or drain all app work.

**Upgrade both roles before enabling this call.** First erasure writes schema 3
into the same journal file, and the earlier SDK rejects it. The minimal replay
marker follows the original invocation expiry, including when a receipt had a
shorter expiry. See [local erasure](local-erasure.md) for error handling,
retention, rollback limits and the required device/writer validation.
