# iOS SDK privacy inventory

Prepared **30 October 2026** for unpublished candidate **`0.1.0-rc.2`**. This inventory
describes implemented SDK behavior. It is an input to the app owner's review, not submitted App Store
answers or a claim that production recovery is enabled.

## Profiles and declarations

The selected candidate composition in [integration](integration.md) uses
`TokenRecoverySession`. It preserves original URL/context and recovery outcomes
without generating App Attest keys, requesting native proofs or creating
attestation key/challenge records. A copied capability can recover or prematurely
complete its handoff; it does not authenticate a user or establish attribution.

The package still includes the attested adapter. Its unchanged cumulative
[privacy manifest](../Sources/LuximioLinks/Resources/PrivacyInfo.xcprivacy)
declares:

| Apple category | SDK data | Linked | Tracking | Purpose |
| --- | --- | --- | --- | --- |
| Device ID | Attested adapter's installation-specific App Attest key metadata | Yes | No | App Functionality |
| Product Interaction | Invocation, route, times and applied/discarded outcomes | Yes | No | App Functionality |
| Other Data Types | Remaining continuation context and security/replay metadata | Yes | No | App Functionality |

It also declares file-timestamp reason `C617.1`, no tracking domains and no
advertising/analytics purpose. Token mode does not remove the Device ID entry
from this multi-adapter package. Verify the SDK resource bundle in both the full
app and embedded Clip, and reconcile the complete app's actual data use.

### Required-reason API review

The journal, token namespace and retained key vault use `fstat`/`lstat` to check
their own files' type, owner, permissions, identity and bounded size. Apple lists
these calls in the File Timestamp category; `C617.1` covers app/app-group file
metadata. The integrating app must supply its own configured App Group
container, not an unrelated user-selected storage location. See
[Apple's categories and reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

The reviewed main source contains no UserDefaults, system-boot-time, disk-space,
active-keyboard, IDFA/vendor-ID or clipboard API use. Clock dates, fresh random
capabilities and hashes of invocation data are not a device-fingerprint matching
implementation. The attested manager's internal `fingerprint` name means a
hash of an invocation, not a device profile. No manifest category was removed
or added for this RC.

## Transfers and storage

Clip capture sends the original URL/query and invocation/scope information to
the configured recovery origin. Recovery exchanges use a finite capability in
an HTTPS Authorization header, with receipt/delivery identifiers and outcomes.
Direct resolution sends the complete original URL to `/api/resolve?url=...`.
The SDK emits no separate app-open analytics event or client crash/performance
upload and requests no contacts, advertising identifier or location access.

Token state is stored in protected App Group files excluded from backup,
isolated by protocol and scope. It includes original link context, capability,
receipt and completion state. On iOS the file/directory protection uses
`completeUntilFirstUserAuthentication`; Unix ownership/permissions and
no-follow checks also apply. The SDK adds no separate application-layer
encryption. The macOS build does not apply the iOS file-protection class.

Expiry is enforced during use. Raw journal entries use their receipt expiry,
or original invocation expiry before pinning. Purge runs when subsequent SDK
work calls it; simple journal reads do not purge. An inactive app can retain
expired files until that work succeeds. Completion clears the queued
acknowledgement, not immediately every saved capability/context byte.

RC2's [scoped local erasure](local-erasure.md) can remove one pinned, terminal,
ACK-cleared entry's raw URL, capability, receipt/destination and completion
payload. It retains only the invocation/create-operation IDs, project/app scope,
a capability hash and original capture/expiry dates. These can still be linkable,
pseudonymous records. The marker follows **original invocation expiry**, up to
the original seven-day capture lifetime, even if receipt expiry was shorter.
It shares the 32-record capacity limit, is never renewed by retry/erasure and
is physically removed only by a later successful purge. No background deletion
job is added. The new local marker fields are not sent to a provider by this
operation.

The first erasure writes journal schema 3 into the existing locked file. Both
app roles must use the upgraded SDK; the previous RC rejects this schema. This
is an active-journal operation, not a remote wipe or guaranteed removal of app
memory, exports, backups, restored copies or provider history. Local removal
and any necessary remaining-marker review are parts of the app's scoped case
procedure, not automatic certification of an all-copy result.

The implemented token service caps readable context at first admission plus
seven days and the requested expiry. Recorded terminal completion/rejection
scrubs that context. Server replay markers have a fixed deadline based on
admission and original requested expiry; the capture-clock allowance can make
that bound seven days plus five minutes after admission. Retries do not renew
it. Eligibility for deletion is not proof that scheduled cleanup ran. Verify
actual deployment cleanup, access, exports and backup retention separately;
SDK storage cannot erase remote copies.

The included attested adapter additionally retains protected key metadata,
registration retry evidence and pins locally. Its service uses fixed 30-day key
validity, five-minute one-use challenges and at most seven-day receipt context
validity. Raw native proof is transient on that backend; interrupted local
registration evidence can remain for bounded retry. Those are separate profile
policies, not records generated by the token composition.

## App and provider responsibilities

Readiness/account holds prevent navigation, not collection. Capture and resolve
can run before login. Gate SDK work separately where a disclosure/choice must
precede collection. No separate customer login ID is sent by this SDK; HTTPS
still exposes normal network metadata to the receiving infrastructure.

Original URLs and destinations are app-defined. Keep credentials and sensitive
personal data out of links; disclose any known account, location, purchase or
other specific categories your schema introduces. An opaque-data category does
not replace a known specific category. Added analytics or data linkage can also
change purposes and tracking answers.

Provider invocation logs may retain request URLs, including a direct-resolution
query. Verify effective logging, recipients, retention and access on the actual
deployment. Do not log tokens, proof, original URLs or whole delivery objects.
The SDK exposes a local erasure API, not a user-facing rights-request UI or a
service/provider deletion endpoint. Uninstalling does not erase service or
provider records. Whole-app disclosures, deletion procedures and third-party
notice/provider review remain the app owner's release responsibilities.

The SDK's declaration does not replace the complete app's answers. Apple
defines collection in terms of off-device retention beyond servicing a request,
and tracking in terms of specified cross-company advertising/measurement or
broker uses. Assess the actual deployed service and any app-added linkage;
do not infer an exemption merely from the absence of analytics code or a login
ID. See [Apple's privacy details](https://developer.apple.com/app-store/app-privacy-details/).

The package copies `PrivacyInfo.xcprivacy` into its SwiftPM resource bundle.
Check that resource in the full app and embedded Clip after a fresh build;
resource inclusion alone is not an aggregate Xcode privacy report or an Apple
declaration. [Apple's manifest placement guide](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
describes the required packaging boundary.
