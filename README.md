# Luximio Links for iOS

**Private development preview.** This repository contains standalone Swift
source for Luximio link routing and App Clip recovery. There are no public
releases or version tags yet. APIs and release support remain provisional;
access to this repository does not enable the Luximio recovery service.

## Add the private package

Use `https://github.com/Luximio/luximio-ios-sdk.git` in Xcode's package
dependencies. Select branch `main` for internal validation, or pin a reviewed
commit revision for a reproducible integration. SwiftPM needs a GitHub identity
with read access to this private repository, including on CI. Keep those
credentials in developer/CI Git authentication, never app configuration.

A package manifest can use:

```swift
.package(url: "https://github.com/Luximio/luximio-ios-sdk.git", branch: "main")
```

Link product `LuximioLinks` to the full app and `LuximioLinksAppClip` to the
App Clip. Both products currently expose the same module: `import LuximioLinks`.
The package requires Swift tools 6.2 and Swift language mode 6. Declared compile
floors are iOS 15 and macOS 12; compilation is not runtime coverage for every OS.

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
Public release review, third-party notice audit and broader runtime validation
remain pending. Customer setup screens, authenticated guides and production
recovery remain disabled pending their separate release work.

## License

Dot Square-authored SDK code is licensed under the [Apache License 2.0](LICENSE).
Retain [NOTICE](NOTICE); third-party components retain their own terms. The
license covers this SDK, not the Luximio backend, dashboard or service. It grants
no service access or paid-plan entitlement and changes no Starter or future Pro
feature gates.
