# Dependencies and notices

Prepared **30 October 2026** for unpublished candidate **`0.1.0-rc.2`**. `Package.swift`
declares no external package or binary-target dependencies. Both library
products compile the same `LuximioLinks` target; the test target and its
synthetic fixtures are separate from the products consumed by an app.

| Platform dependency | Reviewed SDK use |
| --- | --- |
| Foundation | URLs, bounded Codable/JSON models, dates, files and ephemeral URLSession transport |
| CryptoKit | SHA-256 hashes for invocation/receipt/scope binding, local erasure replay markers and the retained adapters |
| Security | OS random-byte generation for capabilities/nonces |
| DeviceCheck | Retained experimental App Attest adapter; unavailable-platform branches fail closed |
| Darwin | Owned-file metadata, permissions, no-follow open and short file locking/synchronization |

These are Apple platform frameworks/system APIs rather than vendored
third-party SDKs. Their platform conditions remain separate from the SDK's
Apache-2.0 license; their framework sources/binaries are not copied into this
source distribution. No downloaded Swift package or embedded third-party
binary was added for this RC. The complete app can introduce additional
dependencies and embedded Swift runtime support through its own toolchain.

The SDK's [LICENSE](../LICENSE) and [NOTICE](../NOTICE) apply to Dot Square's original SDK code. Retain
license and attribution notices when redistributing the SDK. Root legal files
in a source package are not automatically embedded in a consuming app bundle;
the app owner must arrange the notices for its actual distributed app.

Tests use synthetic fixtures, temporary files and injected transports. They do
not contain provider credentials or establish native store transport. Existing
experimental adapters remain included in the module, with the privacy manifest
covering its cumulative capabilities.

Before public distribution, review the complete app and dependency inventory,
retained notices and selected distribution method. This offline candidate
preparation does not certify a whole-app licensing, privacy or platform-policy
review. Its new local erasure operation adds no external package, binary or
provider dependency and does not alter LICENSE, NOTICE or the cumulative privacy
resource. Review the [storage/upgrade contract](local-erasure.md) separately from
dependency results.
