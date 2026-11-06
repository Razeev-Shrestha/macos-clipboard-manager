# Signing and distribution outside the App Store

Clipboard Manager is distributed as a DMG, not through the Mac App Store. Apple's
mechanism for that is **Developer ID** signing plus **notarization**. The project
supports three signing modes, selected with `SIGNING_MODE` when running
`Scripts/package-release.sh`.

| Mode | Certificate | Who can run it | Use it for |
| --- | --- | --- | --- |
| `adhoc` (default) | none | any Mac, after a Gatekeeper override | CI without secrets, quick local builds |
| `development` | Apple Development | your own Macs | daily personal use; stable identity so Accessibility stays granted |
| `developer-id` | Developer ID Application | any Mac, no warnings once notarized | giving the app to anyone else |

> **Apple Distribution certificates do not work here.** They are only for App
> Store and TestFlight submissions. Gatekeeper rejects an Apple Distribution–signed
> app downloaded from anywhere else.

## 1. Point the project at your team (once per Mac)

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# then edit DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY
```

`Config/Signing.local.xcconfig` is gitignored, so the team ID and identity choice
never land in the public repository. Without it the project keeps building
ad-hoc, exactly as before. Xcode picks it up too: Debug builds from Xcode are
signed with your team, which keeps the Accessibility permission working across
rebuilds.

Optionally set `APP_BUNDLE_IDENTIFIER` there to a reverse-DNS name you control.
Clipboard history does not move (it lives in a fixed folder), and settings saved
under the old identifier are copied over automatically on first launch.

## 2. Personal use: Apple Development

```sh
SIGNING_MODE=development Scripts/package-release.sh
```

The build is signed by your team with the hardened runtime and a secure timestamp.
The script verifies the signer, team, hardened runtime and absence of the
`get-task-allow` debugging entitlement for the app, the ZIP copy and the DMG copy,
and signs the DMG itself.

## 3. Sharing the app: Developer ID + notarization

1. **Create the certificate.** Only the team's **Account Holder** can do this:
   Xcode › Settings › Accounts › select the team › Manage Certificates › **+** ›
   **Developer ID Application**. Admins and members cannot. If the Account Holder
   creates it on another Mac, export it from Keychain Access as a `.p12`
   (certificate **and** private key) and import it here.
2. **Store notarization credentials** in the keychain (once). Use an
   [app-specific password](https://support.apple.com/102654) for the Apple ID, or
   an App Store Connect API key:

   ```sh
   xcrun notarytool store-credentials clipboard-notary \
       --apple-id you@example.com --team-id YOURTEAMID
   ```
3. **Build, sign, notarize and staple:**

   ```sh
   SIGNING_MODE=developer-id NOTARY_PROFILE=clipboard-notary \
     REQUIRE_NOTARIZATION=1 Scripts/package-release.sh
   ```

   The app is notarized and stapled before it is archived, so the ZIP and DMG
   contain a stapled app. The DMG is then signed, notarized and stapled too, and
   both are checked with `spctl` (Gatekeeper) before the script succeeds.

## 4. GitHub Actions (optional)

`.github/workflows/release.yml` builds ad-hoc unless these repository secrets
exist, in which case it signs with Developer ID and notarizes:

| Secret | Value |
| --- | --- |
| `MACOS_DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `NOTARY_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` (App Store Connect API key, Developer role) |
| `NOTARY_API_KEY_ID` | the key ID |
| `NOTARY_API_ISSUER_ID` | the issuer ID |

The certificate is imported into a temporary keychain that is deleted at the end of
the job. Because this repository is public, think twice before giving it a company
signing certificate. Anyone who can push a `v*` tag can produce an app signed as
your company. Restrict tag pushes or keep release signing local.

## After switching signing modes

macOS ties the Accessibility permission (needed for automatic paste) to the app's
code signature. The first time you run a build with a different signature,
re-enable Clipboard Manager in System Settings › Privacy & Security ›
Accessibility. If an old entry lingers, remove it there, or reset it:

```sh
tccutil reset Accessibility com.example.ClipboardManager
```
