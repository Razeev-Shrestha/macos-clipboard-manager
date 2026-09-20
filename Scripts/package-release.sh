#!/bin/bash

set -euo pipefail

# Build and package the local, ad-hoc signed Release app for trusted testers.
#
# Usage:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
#     Scripts/package-release.sh
#
# PACKAGE_ARCHS may be set to a space-separated subset of arm64 and x86_64.
# The default asks Xcode for a universal app.

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

printf 'package-release: building Release app with ad-hoc signing\n'

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
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        DEVELOPMENT_TEAM='' \
        AD_HOC_CODE_SIGNING_ALLOWED=YES \
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

    [[ "$bundle_identifier" == 'com.example.ClipboardManager' ]] || fail "$app_label bundle identifier is unexpected: $bundle_identifier"
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
    {
        printf '%s\n' "[$app_label] $app_path"
        "$codesign_path" --display --verbose=4 "$app_path" 2>&1
    } >> "$signature_log"
    grep -q '^Signature=adhoc$' "$signature_log" || fail "$app_label is not ad-hoc signed"

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
    printf '%s\n' "signature=ad-hoc"
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

printf 'package-release: verified app, extracted archive, DMG, ad-hoc signature, and requested architectures\n'
printf 'package-release: Swift WAE log: %s\n' "$test_log"
printf 'package-release: Release build log: %s\n' "$build_log"
printf 'package-release: ZIP: %s\n' "$archive_path"
printf 'package-release: DMG: %s\n' "$dmg_path"
printf 'package-release: checksums: %s\n' "$checksums_file"
printf 'package-release: metadata: %s\n' "$metadata_file"
