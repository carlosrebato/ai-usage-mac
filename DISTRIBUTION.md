# Distributing AI Usage for Mac

## What CI validates

Every change runs the test suite, regenerates the Xcode project, builds the app
and widget in Release, and validates the bundle structure. GitHub retains an
`AI-Usage-unsigned-diagnostic` ZIP for seven days.

That artifact is unsigned and must not be published as a release. It exists to
catch compilation errors, version mismatches and malformed WidgetKit bundles.

## One-time Apple Developer setup

The official release requires an active Apple Developer Program membership and
the following items in the same team:

- A `Developer ID Application` certificate in the signing Mac's Keychain.
- App ID `com.carlosrebato.aiusage`.
- App ID `com.carlosrebato.aiusage.widgets`.
- App Group `467CC6L4BF.com.carlosrebato.aiusage`, assigned to both App IDs.
- Any Developer ID provisioning assets required by the app and widget
  entitlements.

The repository never stores certificates, profiles or Apple credentials. Forks
must register their own Team ID, bundle IDs and App Group.

The checked-in project uses `com.example.*` identifiers. Configure these build
settings in Xcode or pass them to `xcodebuild` for an official release:

```text
DEVELOPMENT_TEAM=467CC6L4BF
AI_USAGE_APP_BUNDLE_ID=com.carlosrebato.aiusage
AI_USAGE_WIDGET_BUNDLE_ID=com.carlosrebato.aiusage.widgets
AI_USAGE_APP_GROUP=467CC6L4BF.com.carlosrebato.aiusage
```

## First release

1. Regenerate and open `AIUsage.xcodeproj`, then configure the release build
   settings above.
2. In **Signing & Capabilities**, select the same Apple team for the app and
   widget and confirm automatic signing resolves without errors.
3. Select **Any Mac (Apple Silicon, Intel)** and run **Product > Archive**.
4. In Organizer, choose **Distribute App > Developer ID > Upload**. Xcode signs
   the archive and submits it to Apple's notary service.
5. Export the notarized app and test it on another Mac before publishing a ZIP
   or DMG.

Before publishing, complete onboarding in the installed app and run:

```sh
AI_USAGE_EXPECTED_BUNDLE_ID=com.carlosrebato.aiusage \
Scripts/smoke-test-signed-app.sh "/Applications/AI Usage.app" 3
```

Repeat the install and smoke test in a clean macOS user account or another Mac.
The first access may ask for permission; subsequent launches must not ask again.

## Notarize from the command line

Xcode can submit the first notarization using its stored Apple account without a
separate `notarytool` profile:

```sh
xcodebuild -exportArchive \
  -archivePath "/path/AI Usage.xcarchive" \
  -exportPath "/path/upload" \
  -exportOptionsPlist Configurations/ExportOptions-DeveloperID-Upload.plist \
  -allowProvisioningUpdates

xcodebuild -exportNotarizedApp \
  -archivePath "/path/AI Usage.xcarchive" \
  -exportPath "/path/notarized"
```

The first command uploads the app and returns a submission identifier. The
second succeeds only after Apple accepts the submission and exports an app with
the notarization ticket stapled.

For later releases, credentials can be stored in Keychain for `notarytool`:

```sh
xcrun notarytool store-credentials AIUsage-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"

Scripts/notarize-signed-app.sh \
  "/path/AI Usage.app" \
  AIUsage-notary
```

The script rejects apps not signed with `Developer ID Application`, waits for
Apple, staples and validates the ticket, checks Gatekeeper and creates
`AI Usage-notarized.zip`.

## Publish an automatic update

AI Usage uses Sparkle. The public EdDSA key is embedded in the app; its private
counterpart stays in the login Keychain under the account
`com.carlosrebato.aiusage` and must never be committed.

After notarizing a release, put the final ZIP in a directory by itself and run:

```sh
Scripts/generate-appcast.sh v0.2.0 /path/to/release-archives
```

Upload the ZIP to the matching GitHub Release and commit the generated
`appcast.xml` at the repository root. Sparkle reads that file from the `main`
branch, verifies the archive's EdDSA signature and compares `CFBundleVersion`.
Every public build must therefore increment `CURRENT_PROJECT_VERSION`.

The first build that embeds Sparkle must still be installed manually. Builds
after that can update automatically.

## Automating signed releases

After a manual release works end to end, add a workflow protected by a GitHub
environment. It must create a temporary Keychain, import the certificate and
profiles, sign the app and widget, submit with `notarytool`, and delete the
temporary Keychain. Signing credentials must never be exposed to pull-request
workflows.
