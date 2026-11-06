#!/bin/bash

set -euo pipefail

# Build, sign, verify and package the Release app.
#
# Usage:
#   Scripts/package-release.sh                                  # ad-hoc (default)
#   SIGNING_MODE=development Scripts/package-release.sh          # Apple Development
#   SIGNING_MODE=developer-id NOTARY_PROFILE=clipboard-notary \
#     Scripts/package-release.sh                                 # Developer ID + notarize
#
# SIGNING_MODE
#   adhoc         Locally ad-hoc signed. Works anywhere, no account required.
#   development   Signed with "Apple Development" and the team from
#                 Config/Signing.local.xcconfig (or DEVELOPMENT_TEAM). Stable identity
#                 for your own registered Macs; Gatekeeper rejects it elsewhere.
#   developer-id  Signed with "Developer ID Application" for distribution outside the
#                 App Store. Notarized and stapled when notary credentials are given.
#
# Notary credentials (developer-id only; one of):
#   NOTARY_PROFILE=<name>   keychain profile from `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER   App Store Connect API key (CI)
# Set REQUIRE_NOTARIZATION=1 to fail instead of skipping when none are set.
#
# PACKAGE_ARCHS may be set to a space-separated subset of arm64 and x86_64.
# The default asks Xcode for a universal app. SIGNING_KEYCHAIN optionally names
# the keychain holding the identity (used by CI).

fail() {
    printf 'package-release: error: %s\n' "$*" >&2
    exit 1
}

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_directory/.." && pwd)"
project_path="$repository_root/ClipboardManager.xcodeproj"
scheme_name="ClipboardManager"
configuration="Release"
developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
requested_architectures="${PACKAGE_ARCHS:-arm64 x86_64}"
signing_mode="${SIGNING_MODE:-adhoc}"
notary_profile="${NOTARY_PROFILE:-}"
require_notarization="${REQUIRE_NOTARIZATION:-0}"

case "$signing_mode" in
    adhoc) signing_identity='-' ;;
    development) signing_identity='Apple Development' ;;
    developer-id) signing_identity='Developer ID Application' ;;
    *) fail "SIGNING_MODE must be adhoc, development or developer-id (got: $signing_mode)" ;;
esac

notary_arguments=()
if [[ "$signing_mode" == 'developer-id' ]]; then
    if [[ -n "$notary_profile" ]]; then
        notary_arguments=(--keychain-profile "$notary_profile")
    elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
        [[ -f "$NOTARY_KEY_PATH" ]] || fail "NOTARY_KEY_PATH does not name a file"
        notary_arguments=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    elif [[ "$require_notarization" == '1' ]]; then
        fail "REQUIRE_NOTARIZATION=1 but neither NOTARY_PROFILE nor NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER is set"
    fi
fi

[[ -d "$project_path" ]] || fail "missing ClipboardManager.xcodeproj"
[[ -d "$developer_directory" ]] || fail "DEVELOPER_DIR does not name an Xcode developer directory: $developer_directory"
[[ -x "$developer_directory/usr/bin/xcodebuild" ]] || fail "xcodebuild is unavailable under DEVELOPER_DIR: $developer_directory"

for architecture in $requested_architectures; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) fail "PACKAGE_ARCHS may contain only arm64 and x86_64 (got: $architecture)" ;;
    esac
done

[[ -n "$requested_architectures" ]] || fail "PACKAGE_ARCHS must contain at least one architecture"

xcodebuild_path="$(DEVELOPER_DIR="$developer_directory" xcrun --find xcodebuild)"
swift_path="$(DEVELOPER_DIR="$developer_directory" xcrun --find swift)"
sdk_path="$(DEVELOPER_DIR="$developer_directory" xcrun --sdk macosx --show-sdk-path)"
[[ -x "$xcodebuild_path" ]] || fail "xcodebuild was not found by xcrun"
[[ -x "$swift_path" ]] || fail "Swift was not found by xcrun"
[[ -d "$sdk_path" ]] || fail "macOS SDK was not found by xcrun"

distribution_root="$repository_root/build/Distribution"
mkdir -p "$distribution_root"

run_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
if ! run_directory="$(mktemp -d "$distribution_root/ClipboardManager-Release-${run_stamp}-XXXXXX")"; then
    fail "unable to create a unique package output directory under $distribution_root"
fi

derived_data="$run_directory/DerivedData"
swift_scratch="$run_directory/SwiftPM"
test_log="$run_directory/swift-test.log"
build_log="$run_directory/xcodebuild-release.log"
validation_log="$run_directory/validation.log"
signature_log="$run_directory/codesign-details.log"
metadata_file="$run_directory/BUILD-METADATA.txt"
app_destination="$run_directory/Clipboard Manager.app"
archive_path="$run_directory/ClipboardManager-Release-${run_stamp}.zip"
dmg_path="$run_directory/ClipboardManager-Release-${run_stamp}.dmg"
extracted_directory="$run_directory/Extracted"
dmg_source_directory="$run_directory/DMG-Source"
dmg_mountpoint="$run_directory/DMG-Mount"
checksums_file="$run_directory/SHA256SUMS.txt"

git_revision="$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || printf 'unavailable')"
git_branch="$(git -C "$repository_root" branch --show-current 2>/dev/null || printf 'unavailable')"
git_description="$(git -C "$repository_root" describe --always --dirty 2>/dev/null || printf 'unavailable')"
git_status="$(git -C "$repository_root" status --porcelain=v1 2>/dev/null || true)"
if [[ -n "$git_status" ]]; then
    source_dirty="yes"
else
    source_dirty="no"
fi

printf 'package-release: output directory: %s\n' "$run_directory"
printf 'package-release: requested architectures: %s\n' "$requested_architectures"
printf 'package-release: running Swift tests with warnings as errors\n'

{
    printf '%s\n' "DEVELOPER_DIR=$developer_directory"
    printf '%s\n' "Swift=$swift_path"
    printf '%s\n' "ScratchPath=$swift_scratch"
    printf '%s\n' "Command: swift test --scratch-path $swift_scratch -Xswiftc -warnings-as-errors"
    DEVELOPER_DIR="$developer_directory" "$swift_path" test \
        --package-path "$repository_root" \
        --scratch-path "$swift_scratch" \
        -Xswiftc -warnings-as-errors
} 2>&1 | tee "$test_log"

signing_overrides=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$signing_identity")
if [[ "$signing_mode" == 'adhoc' ]]; then
    signing_overrides+=(DEVELOPMENT_TEAM='' AD_HOC_CODE_SIGNING_ALLOWED=YES)
elif [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    signing_overrides+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    signing_overrides+=("OTHER_CODE_SIGN_FLAGS=--timestamp --keychain $SIGNING_KEYCHAIN")
fi

# Resolve the bundle identifier and team the build will use, so verification
# follows Config/Signing*.xcconfig instead of a hard-coded value.
resolved_settings="$(DEVELOPER_DIR="$developer_directory" "$xcodebuild_path" \
    -project "$project_path" -scheme "$scheme_name" -configuration "$configuration" \
    -showBuildSettings "${signing_overrides[@]}" 2>/dev/null)"
build_setting() {
    printf '%s\n' "$resolved_settings" | sed -n "s/^ *$1 = //p" | head -n 1
}
expected_bundle_identifier="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
expected_team="$(build_setting DEVELOPMENT_TEAM)"
[[ -n "$expected_bundle_identifier" ]] || fail "unable to resolve PRODUCT_BUNDLE_IDENTIFIER"
if [[ "$signing_mode" != 'adhoc' ]]; then
    [[ -n "$expected_team" ]] || fail "SIGNING_MODE=$signing_mode needs DEVELOPMENT_TEAM (set it in Config/Signing.local.xcconfig or the environment)"
    # Command-line identity overrides reach the local Swift package target too,
    # which does not read the app's xcconfig, so pass the resolved team globally.
    signing_overrides+=("DEVELOPMENT_TEAM=$expected_team")
fi

printf 'package-release: building Release app (signing: %s, bundle: %s, team: %s)\n' \
    "$signing_mode" "$expected_bundle_identifier" "${expected_team:-none}"

{
    printf '%s\n' "DEVELOPER_DIR=$developer_directory"
    printf '%s\n' "SDK=$sdk_path"
    printf '%s\n' "Command: xcodebuild -project ClipboardManager.xcodeproj -scheme $scheme_name -configuration $configuration -destination generic/platform=macOS -derivedDataPath $derived_data ARCHS=$requested_architectures"
    DEVELOPER_DIR="$developer_directory" "$xcodebuild_path" \
        -project "$project_path" \
        -scheme "$scheme_name" \
        -configuration "$configuration" \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$run_directory/SourcePackages" \
        -disableAutomaticPackageResolution \
        ARCHS="$requested_architectures" \
        ONLY_ACTIVE_ARCH=NO \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='' \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        SWIFT_SUPPRESS_WARNINGS=NO \
        "${signing_overrides[@]}" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        build
} 2>&1 | tee "$build_log"

built_app="$derived_data/Build/Products/$configuration/Clipboard Manager.app"
[[ -d "$built_app" ]] || fail "Release build did not produce $built_app"
[[ ! -e "$app_destination" ]] || fail "package destination already exists: $app_destination"
ditto "$built_app" "$app_destination"

codesign_path="$(command -v codesign || true)"
lipo_path="$(command -v lipo || true)"
plutil_path="$(command -v plutil || true)"
strings_path="$(command -v strings || true)"
ditto_path="$(command -v ditto || true)"
hdiutil_path="$(command -v hdiutil || true)"
shasum_path="$(command -v shasum || true)"
for required_tool in codesign_path lipo_path plutil_path strings_path ditto_path hdiutil_path shasum_path; do
    [[ -n "${!required_tool}" ]] || fail "required packaging tool is unavailable: ${required_tool%_path}"
done

plist_value() {
    local key="$1"
    local plist="$2"
    "$plutil_path" -extract "$key" raw -o - "$plist"
}

verify_app() {
    local app_path="$1"
    local app_label="$2"
    local plist_path="$app_path/Contents/Info.plist"

    [[ -d "$app_path" ]] || fail "$app_label app bundle is missing: $app_path"
    [[ -f "$plist_path" ]] || fail "$app_label app has no Info.plist"
    "$plutil_path" -lint "$plist_path" >> "$validation_log" 2>&1

    local bundle_identifier
    local package_type
    local executable_name
    local short_version
    local build_version
    local icon_name
    local icon_file
    bundle_identifier="$(plist_value CFBundleIdentifier "$plist_path")"
    package_type="$(plist_value CFBundlePackageType "$plist_path")"
    executable_name="$(plist_value CFBundleExecutable "$plist_path")"
    short_version="$(plist_value CFBundleShortVersionString "$plist_path")"
    build_version="$(plist_value CFBundleVersion "$plist_path")"
    if ! icon_name="$(plist_value CFBundleIconName "$plist_path")"; then
        fail "$app_label does not declare a primary app icon name"
    fi
    if ! icon_file="$(plist_value CFBundleIconFile "$plist_path")"; then
        fail "$app_label does not declare an app icon fallback file"
    fi

    [[ "$bundle_identifier" == "$expected_bundle_identifier" ]] || fail "$app_label bundle identifier is unexpected: $bundle_identifier"
    [[ "$(plist_value CFBundleDisplayName "$plist_path")" == 'Clipboard Manager' ]] || fail "$app_label display name is incorrect"
    [[ "$(plist_value CFBundleName "$plist_path")" == 'Clipboard Manager' ]] || fail "$app_label bundle name is incorrect"
    [[ "$package_type" == 'APPL' ]] || fail "$app_label bundle type is unexpected: $package_type"
    [[ -n "$executable_name" ]] || fail "$app_label has no executable name"
    [[ "$icon_name" == 'AppIcon' ]] || fail "$app_label primary app icon name is unexpected: $icon_name"
    [[ "$icon_file" == 'AppIcon' ]] || fail "$app_label app icon fallback file is unexpected: $icon_file"
    [[ -s "$app_path/Contents/Resources/Assets.car" ]] || fail "$app_label is missing compiled app icon assets"
    [[ -s "$app_path/Contents/Resources/AppIcon.icns" ]] || fail "$app_label is missing its app icon fallback"

    local executable_path="$app_path/Contents/MacOS/$executable_name"
    [[ -f "$executable_path" ]] || fail "$app_label executable is missing: $executable_path"

    if ! "$codesign_path" --verify --deep --strict --verbose=2 "$app_path" >> "$validation_log" 2>&1; then
        fail "$app_label failed strict code-signature verification"
    fi
    local signature_details
    signature_details="$("$codesign_path" --display --verbose=4 "$app_path" 2>&1)"
    printf '%s\n%s\n' "[$app_label] $app_path" "$signature_details" >> "$signature_log"
    printf '%s\n' "$signature_details" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' \
        || fail "$app_label is not signed with the hardened runtime"
    case "$signing_mode" in
        adhoc)
            printf '%s\n' "$signature_details" | grep -q '^Signature=adhoc$' \
                || fail "$app_label is not ad-hoc signed"
            ;;
        development|developer-id)
            local authority_prefix='Apple Development: '
            [[ "$signing_mode" == 'developer-id' ]] && authority_prefix='Developer ID Application: '
            printf '%s\n' "$signature_details" | grep -q "^Authority=${authority_prefix}" \
                || fail "$app_label is not signed by an identity starting with '$authority_prefix'"
            printf '%s\n' "$signature_details" | grep -qx "TeamIdentifier=$expected_team" \
                || fail "$app_label is not signed by team $expected_team"
            printf '%s\n' "$signature_details" | grep -q '^Timestamp=' \
                || [[ "$signing_mode" == 'development' ]] \
                || fail "$app_label signature has no secure timestamp (required for notarization)"
            local entitlements
            entitlements="$("$codesign_path" --display --entitlements - --xml "$app_path" 2>/dev/null || true)"
            if printf '%s' "$entitlements" | grep -q 'com.apple.security.get-task-allow'; then
                fail "$app_label carries the get-task-allow debugging entitlement"
            fi
            ;;
    esac

    local architecture_info
    architecture_info="$("$lipo_path" -info "$executable_path" 2>&1)"
    printf '%s: %s\n' "$app_label architectures" "$architecture_info" >> "$validation_log"
    for architecture in $requested_architectures; do
        printf '%s\n' "$architecture_info" | grep -Eq "(^|[[:space:]])${architecture}([[:space:]]|$)" \
            || fail "$app_label executable does not contain requested architecture $architecture"
    done

    # DEBUG-only command-line flags select private pasteboards and storage. They
    # must not be present in a tester Release binary.
    local strings_file="$run_directory/${app_label}-strings.txt"
    "$strings_path" "$executable_path" > "$strings_file"
    for debug_flag in \
        '--test-pasteboard' \
        '--test-storage-directory' \
        '--test-paste-target-app-path'; do
        if grep -F -- "$debug_flag" "$strings_file" > /dev/null 2>&1; then
            fail "$app_label contains a DEBUG-only test flag: $debug_flag"
        fi
    done

    printf '%s\n' "$app_label bundle=$bundle_identifier version=$short_version build=$build_version executable=$executable_name" >> "$validation_log"
}

: > "$validation_log"
: > "$signature_log"
verify_app "$app_destination" 'built'

notarized='no'
notarize() {
    local artifact="$1"
    local label="$2"
    local submission_log="$run_directory/notary-${label}.json"
    printf 'package-release: submitting %s for notarization (this can take several minutes)\n' "$label"
    if ! xcrun notarytool submit "$artifact" "${notary_arguments[@]}" \
        --wait --timeout 30m --output-format json > "$submission_log" 2>&1; then
        cat "$submission_log" >&2
        fail "notarization submission failed for $label"
    fi
    if ! grep -q '"status" *: *"Accepted"' "$submission_log"; then
        local submission_id
        submission_id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$submission_log" | head -n 1)"
        [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" "${notary_arguments[@]}" >&2 || true
        fail "Apple did not accept $label for notarization (see $submission_log)"
    fi
}

if [[ "$signing_mode" == 'developer-id' && ${#notary_arguments[@]} -gt 0 ]]; then
    notary_zip="$run_directory/notarize-app.zip"
    "$ditto_path" -c -k --sequesterRsrc --keepParent "$app_destination" "$notary_zip"
    notarize "$notary_zip" 'app'
    rm -f "$notary_zip"
    xcrun stapler staple "$app_destination" >> "$validation_log" 2>&1 || fail "unable to staple the app"
    xcrun stapler validate "$app_destination" >> "$validation_log" 2>&1 || fail "stapled app ticket did not validate"
    spctl --assess --type execute --verbose=4 "$app_destination" >> "$validation_log" 2>&1 \
        || fail "Gatekeeper rejected the notarized app"
    notarized='yes'
    verify_app "$app_destination" 'stapled'
elif [[ "$signing_mode" == 'developer-id' ]]; then
    printf 'package-release: warning: no notary credentials; the Developer ID build is NOT notarized\n' >&2
fi

printf 'package-release: creating ZIP archive\n'
mkdir "$extracted_directory"
[[ ! -e "$archive_path" ]] || fail "archive destination already exists: $archive_path"
"$ditto_path" -c -k --sequesterRsrc --keepParent "$app_destination" "$archive_path"
"$ditto_path" -x -k "$archive_path" "$extracted_directory"
extracted_app="$extracted_directory/Clipboard Manager.app"
verify_app "$extracted_app" 'extracted'

printf 'package-release: creating DMG image\n'
mkdir "$dmg_source_directory"
ln -s /Applications "$dmg_source_directory/Applications"
ditto "$app_destination" "$dmg_source_directory/Clipboard Manager.app"
[[ ! -e "$dmg_path" ]] || fail "DMG destination already exists: $dmg_path"
"$hdiutil_path" create \
    -volname 'Clipboard Manager' \
    -srcfolder "$dmg_source_directory" \
    -ov \
    -format UDZO \
    "$dmg_path" >> "$validation_log" 2>&1

if [[ "$signing_mode" != 'adhoc' ]]; then
    # Sign with the exact certificate Xcode chose for the app. A keychain can hold
    # several certificates with the same common name, which makes a name ambiguous.
    certificate_prefix="$run_directory/app-certificate-"
    "$codesign_path" --display --extract-certificates="$certificate_prefix" "$app_destination" > /dev/null 2>&1 \
        || fail "unable to read the app's signing certificate"
    dmg_signing_hash="$(openssl x509 -inform DER -in "${certificate_prefix}0" -noout -fingerprint -sha1 \
        | sed 's/^.*=//; s/://g')"
    rm -f "${certificate_prefix}"*
    [[ -n "$dmg_signing_hash" ]] || fail "unable to fingerprint the app's signing certificate"
    dmg_sign_arguments=(--force --sign "$dmg_signing_hash" --timestamp)
    [[ -n "${SIGNING_KEYCHAIN:-}" ]] && dmg_sign_arguments+=(--keychain "$SIGNING_KEYCHAIN")
    if [[ "$signing_mode" == 'developer-id' ]]; then
        dmg_sign_arguments+=(--identifier "${expected_bundle_identifier}.dmg")
    fi
    "$codesign_path" "${dmg_sign_arguments[@]}" "$dmg_path" >> "$validation_log" 2>&1 \
        || fail "unable to sign the DMG"
    "$codesign_path" --verify --strict --verbose=2 "$dmg_path" >> "$validation_log" 2>&1 \
        || fail "DMG signature did not verify"
fi
if [[ "$notarized" == 'yes' ]]; then
    notarize "$dmg_path" 'dmg'
    xcrun stapler staple "$dmg_path" >> "$validation_log" 2>&1 || fail "unable to staple the DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path" \
        >> "$validation_log" 2>&1 || fail "Gatekeeper rejected the notarized DMG"
fi

mkdir "$dmg_mountpoint"
"$hdiutil_path" attach "$dmg_path" \
    -nobrowse \
    -readonly \
    -mountpoint "$dmg_mountpoint" >> "$validation_log" 2>&1
verify_app "$dmg_mountpoint/Clipboard Manager.app" 'DMG'
"$hdiutil_path" detach "$dmg_mountpoint" >> "$validation_log" 2>&1
rmdir "$dmg_mountpoint"

binary_path="$app_destination/Contents/MacOS/$(plist_value CFBundleExecutable "$app_destination/Contents/Info.plist")"
archive_digest="$("$shasum_path" -a 256 "$archive_path" | awk '{print $1}')"
dmg_digest="$("$shasum_path" -a 256 "$dmg_path" | awk '{print $1}')"
binary_digest="$("$shasum_path" -a 256 "$binary_path" | awk '{print $1}')"

{
    printf '%s\n' 'ClipboardManager Release package metadata'
    printf '%s\n' "created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "source_revision=$git_revision"
    printf '%s\n' "source_branch=$git_branch"
    printf '%s\n' "source_description=$git_description"
    printf '%s\n' "source_dirty=$source_dirty"
    printf '%s\n' 'source_status_begin'
    if [[ -n "$git_status" ]]; then
        printf '%s\n' "$git_status"
    else
        printf '%s\n' '(clean)'
    fi
    printf '%s\n' 'source_status_end'
    printf '%s\n' "developer_dir=$developer_directory"
    printf '%s\n' "sdk_path=$sdk_path"
    printf '%s\n' "project=ClipboardManager.xcodeproj"
    printf '%s\n' "scheme=$scheme_name"
    printf '%s\n' "configuration=$configuration"
    printf '%s\n' "requested_architectures=$requested_architectures"
    printf '%s\n' "built_app_architectures=$(grep '^built architectures:' "$validation_log" | sed 's/^built architectures: //')"
    printf '%s\n' "bundle_identifier=$(plist_value CFBundleIdentifier "$app_destination/Contents/Info.plist")"
    printf '%s\n' "bundle_version=$(plist_value CFBundleShortVersionString "$app_destination/Contents/Info.plist")"
    printf '%s\n' "build_version=$(plist_value CFBundleVersion "$app_destination/Contents/Info.plist")"
    printf '%s\n' "signature=$signing_mode"
    printf '%s\n' "team=${expected_team:-none}"
    printf '%s\n' "notarized=$notarized"
    printf '%s\n' "archive=$(basename "$archive_path")"
    printf '%s\n' "archive_sha256=$archive_digest"
    printf '%s\n' "dmg=$(basename "$dmg_path")"
    printf '%s\n' "dmg_sha256=$dmg_digest"
    printf '%s\n' "executable_sha256=$binary_digest"
    printf '%s\n' "swift_test_log=$(basename "$test_log")"
    printf '%s\n' "release_build_log=$(basename "$build_log")"
    printf '%s\n' "validation_log=$(basename "$validation_log")"
    printf '%s\n' "signature_log=$(basename "$signature_log")"
} > "$metadata_file"

{
    printf '%s  %s\n' "$archive_digest" "$(basename "$archive_path")"
    printf '%s  %s\n' "$dmg_digest" "$(basename "$dmg_path")"
    printf '%s  %s\n' "$binary_digest" "$(basename "$app_destination")/Contents/MacOS/ClipboardManager"
} > "$checksums_file"

printf 'package-release: verified app, extracted archive, DMG, %s signature (notarized: %s), and requested architectures\n' "$signing_mode" "$notarized"
printf 'package-release: Swift WAE log: %s\n' "$test_log"
printf 'package-release: Release build log: %s\n' "$build_log"
printf 'package-release: ZIP: %s\n' "$archive_path"
printf 'package-release: DMG: %s\n' "$dmg_path"
printf 'package-release: checksums: %s\n' "$checksums_file"
printf 'package-release: metadata: %s\n' "$metadata_file"
