# Release candidate 0.1.0-rc.2

This unpublished candidate contains the standalone Luximio iOS SDK, synthetic
tests, customer guides and manual build-only CI. Preparation and local candidate
tagging do not publish a GitHub tag, update the public SDK repository or enable
production recovery. The issued
[`0.1.0-rc.1`](https://github.com/Luximio/luximio-ios-sdk/tree/0.1.0-rc.1)
remains unchanged.

RC2 adds scoped local erasure through `TokenRecoverySession.eraseCompleted`
and its lower-level journal API. It removes one eligible handoff's readable
context while retaining a finite replay marker. The first erasure upgrades the
existing journal to schema 3. Both the full app and its Clip must upgrade before
use; RC1 rejects that schema. See [local erasure](docs/local-erasure.md) before
reviewing migration or rollback.

The selected customer composition remains token recovery through
`TokenRecoverySession`. Earlier fixture, private and attested adapters are
separate profiles, not customer fallback paths. Both products use the same
module and unchanged cumulative privacy resource.

Apache-2.0 covers Dot Square's original SDK code. See [LICENSE](LICENSE),
[NOTICE](NOTICE) and [dependency notes](docs/dependencies.md). Service access,
provider setup, full-app privacy answers and actual device validation remain
separate from source access and local packaging results.
