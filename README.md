# Luximio Links for iOS

**Release candidate `0.1.0-rc.2` — prepared offline, not published.** This
standalone Swift package provides link routing and token-based App Clip
recovery. RC2 adds [scoped local handoff erasure](docs/local-erasure.md).
Source access does not activate the Luximio recovery service.

The public SDK repository already contains
[`0.1.0-rc.1`](https://github.com/Luximio/luximio-ios-sdk/tree/0.1.0-rc.1).
That issued version is preserved and does not provide the new erasure API.
Do not treat an RC2 local candidate or build result as a public SDK release.

## Validate the candidate

For offline review, use the generated SDK-only Git mirror and its exact local
`0.1.0-rc.2` tag. Pin the reviewed candidate revision and verify it against its
archive/inventory record. The mirror is a validation input, not a remote release.

After RC2 publication and its matching tag have been separately approved, a
package manifest can use:

```swift
.package(url: "https://github.com/Luximio/luximio-ios-sdk.git",
         exact: "0.1.0-rc.2")
```

This RC2 version requirement is **prospective**. Until publication, it is not
an installation instruction for the public repository. Existing public RC1
consumers can continue to pin `0.1.0-rc.1`; do not call RC2-only APIs from it.

Link product `LuximioLinks` to the full app and `LuximioLinksAppClip` to its
App Clip. Both products expose `import LuximioLinks`. The package requires
Swift tools 6.2 and Swift language mode 6. Declared compile floors are iOS 15
and macOS 12; compilation does not establish runtime coverage on every OS.

## Integration and migration

Start with the [token integration guide](docs/integration.md). Construct each
role's paired `TokenRecoverySession`, use the real signed App Group container,
and forward lifecycle events to an app-owned router.

- The full app owns onboarding, authentication, resource authorization and
  synchronous navigation. A recovered capability or campaign parameter does
  not establish identity, verified attribution or access to a private resource.
- The selected token profile shares finite context through the App Group. It
  does not rely on moving an App Attest key from the Clip to the full app.
- Earlier fixture, private and attested adapters remain separate profiles in
  the module. A customer failure does not fall back to those profiles.
- Recovery admission, customer setup screens and authenticated guides remain
  disabled pending their separate rollout. Package access grants no service
  entitlement or paid-plan override.

**Upgrade both the full app and App Clip before using local erasure.** Its first
successful use writes journal schema 3 in the existing locked file. RC1 rejects
that schema; downgrading after erasure therefore fails closed. Do not delete or
reset the journal to make an older reader work. Review the exact preconditions,
marker lifetime and limits in [local erasure](docs/local-erasure.md).

Read the [privacy inventory](docs/privacy.md), the bundled
[privacy manifest](Sources/LuximioLinks/Resources/PrivacyInfo.xcprivacy) and the
complete consuming app. The manifest remains cumulative across SDK adapters.

## Build and test

From this repository with Swift 6.2 or later:

```sh
swift test
swift build --configuration release
```

The Build SDK workflow is started manually, has read-only repository permissions
and contains no release/deployment step. Preparing or importing a candidate does
not start a hosted build. Tests use synthetic data and injected dependencies.
Successful package builds do not prove signed App Group behavior, physical
Clip/store installation, provider authorization or complete data erasure.

## License

Dot Square-authored SDK code is licensed under the [Apache License 2.0](LICENSE).
Retain [NOTICE](NOTICE); third-party components retain their own terms. The
license covers this SDK, not the Luximio backend, dashboard or service. It grants
no service access or paid-plan entitlement and changes no Starter or future Pro
feature gates. See [dependencies and notices](docs/dependencies.md).
