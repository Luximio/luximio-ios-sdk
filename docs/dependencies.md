# Dependencies and notices

The Swift package declares no external package dependencies. It uses Apple
platform frameworks and system APIs, including Foundation, CryptoKit, Security,
DeviceCheck and Darwin where applicable. Those platform components are not
relicensed by the SDK's Apache-2.0 license or distributed as source here.

The SDK's LICENSE and NOTICE apply to Dot Square's original SDK code. Retain
license and attribution notices when redistributing the SDK. Root legal files
in a source package are not automatically embedded in a consuming app bundle;
the app owner must arrange the notices for its actual distributed app.

Tests use synthetic fixtures, temporary files and injected transports. They do
not contain provider credentials or establish native store transport. Existing
experimental adapters remain included in the module, with the privacy manifest
covering its cumulative capabilities.

Before public distribution, review the complete app and dependency inventory,
retained notices and selected distribution method. This private source import
does not certify a whole-app licensing, privacy or platform-policy review.
