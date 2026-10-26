# Luximio Links for iOS

**Release candidate `0.1.0-rc.1` — not published.** This repository contains
standalone Swift source for Luximio link routing and App Clip recovery. APIs
and release support remain provisional; source access does not enable the
Luximio recovery service.

## Add the private package

Use `https://github.com/Luximio/luximio-ios-sdk.git` in Xcode's package
dependencies. For internal validation, pin the exact reviewed SDK commit.
SwiftPM needs a GitHub identity
with read access to this private repository, including on CI. Keep those
credentials in developer/CI Git authentication, never app configuration.

A package manifest can use:

```swift
.package(url: "https://github.com/Luximio/luximio-ios-sdk.git",
         revision: "<reviewed SDK commit>")
```

Replace the revision placeholder with the full candidate commit being reviewed.
After a public release and matching tag have been explicitly approved, use the
exact version instead:

```swift
.package(url: "https://github.com/Luximio/luximio-ios-sdk.git",
         exact: "0.1.0-rc.1")
```

That version requirement is prospective: there is no matching GitHub release
tag or public package yet. Private validation uses an isolated local mirror
tagged with the RC at the reviewed commit, without tagging the GitHub repository.

Link product `LuximioLinks` to the full app and `LuximioLinksAppClip` to the
App Clip. Both products currently expose the same module: `import LuximioLinks`.
The package requires Swift tools 6.2 and Swift language mode 6. Declared compile
floors are iOS 15 and macOS 12; compilation is not runtime coverage for every OS.

## Candidate scope

- `TokenRecoverySession` is the selected customer composition. It shares finite
  recovery context between the signed App Clip and full app through the App
  Group; it does not transfer a usable App Attest key across that boundary.
- The full app owns onboarding, authentication, resource authorization and
  synchronous navigation. The coordinator supports holds, explicit retry,
  completion and cancellation before a newer manual/direct-link choice.
- A bearer capability, native platform handoff or original campaign context
  does not establish user identity, trustworthy conversion attribution or
  permission to open a private resource.
- Earlier fixture, private and attested adapters remain in the module as
  separate profiles; customer failures do not fall back to them.
- Production recovery, customer provisioning and authenticated setup guides
  remain disabled. Package download alone grants no service entitlement.

## Integrate and review

Start with the [token recovery integration guide](docs/integration.md). It
constructs each role's paired `TokenRecoverySession`, uses the real signed App
Group container and forwards lifecycle events to an app-owned router.

The selected token profile uses a finite bearer capability. It does not prove
an installation, identity, trustworthy attribution, payment or permission to
open a private resource. The full app owns authentication and authorization.
The package also contains earlier adapters; their presence does not make those
profiles generally available or provide a fallback when recovery fails.

Review the [privacy inventory](docs/privacy.md), the bundled
[privacy manifest](Sources/LuximioLinks/Resources/PrivacyInfo.xcprivacy) and the
complete consuming app. The manifest remains cumulative across SDK adapters.

## Build

From this repository with Swift 6.2 or later:

```sh
swift test
swift build --configuration release
```

The Build SDK workflow is started manually from GitHub Actions. It has read-only
repository permissions and no release or deployment steps. Importing this
workflow does not start a hosted build. CI tests and builds checked-in source only. A successful build does not verify signed
App Group handoff, a store installation path or a customer's provider setup.
The package/dependency and privacy reviews are inputs to release review;
whole-app declarations and broader runtime validation remain separate.
Customer setup screens, authenticated guides and production
recovery remain disabled pending their separate release work.

## License

Dot Square-authored SDK code is licensed under the [Apache License 2.0](LICENSE).
Retain [NOTICE](NOTICE); third-party components retain their own terms. The
license covers this SDK, not the Luximio backend, dashboard or service. It grants
no service access or paid-plan entitlement and changes no Starter or future Pro
feature gates.
