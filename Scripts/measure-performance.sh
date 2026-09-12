#!/bin/zsh
set -euo pipefail

if (( $# != 0 )); then
    echo "measure-performance.sh does not accept path or pasteboard overrides" >&2
    exit 2
fi

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DATASET_DIR="$PROJECT_ROOT/build/GateFPerformance"
LARGE_DATASET_DIR="$DATASET_DIR/large"
DATASET_BLOBS_DIR="$DATASET_DIR/blobs"
LARGE_BLOBS_DIR="$LARGE_DATASET_DIR/blobs"
PROBE="$DATASET_DIR/ClipboardPerformanceProbe"

reject_unsafe_path() {
    echo "unsafe Gate F fixture path: $1" >&2
    return 1
}

preflight_owned_path() {
    local owned_path="$1"
    local kind="$2"
    local current="/"
    local component
    local -a components
    components=("${(@s:/:)owned_path}")

    for component in "${components[@]}"; do
        [[ -z "$component" ]] && continue
        current="${current%/}/$component"
        if [[ -L "$current" ]]; then
            reject_unsafe_path "$owned_path"
            return 1
        fi
        if [[ "$current" != "$owned_path" && -e "$current" && ! -d "$current" ]]; then
            reject_unsafe_path "$owned_path"
            return 1
        fi
        if [[ "$current" == "$owned_path" && -e "$current" ]]; then
            if [[ "$kind" == directory && ! -d "$current" ]]; then
                reject_unsafe_path "$owned_path"
                return 1
            fi
            if [[ "$kind" == file && ! -f "$current" ]]; then
                reject_unsafe_path "$owned_path"
                return 1
            fi
        fi
    done
}

preflight_owned_paths() {
    preflight_owned_path "$PROJECT_ROOT/build" directory
    preflight_owned_path "$DATASET_DIR" directory
    preflight_owned_path "$DATASET_BLOBS_DIR" directory
    preflight_owned_path "$LARGE_DATASET_DIR" directory
    preflight_owned_path "$LARGE_BLOBS_DIR" directory
    preflight_owned_path "$PROBE" file
    for database in \
        "$DATASET_DIR/history.sqlite" \
        "$DATASET_DIR/history.sqlite-wal" \
        "$DATASET_DIR/history.sqlite-shm" \
        "$LARGE_DATASET_DIR/large-history.sqlite" \
        "$LARGE_DATASET_DIR/large-history.sqlite-wal" \
        "$LARGE_DATASET_DIR/large-history.sqlite-shm"; do
        preflight_owned_path "$database" file
    done
}

assert_databases_closed() {
    if [[ ! -x /usr/sbin/lsof ]]; then
        echo "lsof is required to protect the Gate F SQLite fixtures" >&2
        return 1
    fi
    local database
    for database in \
        "$DATASET_DIR/history.sqlite" \
        "$DATASET_DIR/history.sqlite-wal" \
        "$DATASET_DIR/history.sqlite-shm" \
        "$LARGE_DATASET_DIR/large-history.sqlite" \
        "$LARGE_DATASET_DIR/large-history.sqlite-wal" \
        "$LARGE_DATASET_DIR/large-history.sqlite-shm"; do
        assert_database_closed "$database" || return 1
    done
}

assert_database_closed() {
    if [[ ! -x /usr/sbin/lsof ]]; then
        echo "lsof is required to protect the Gate F SQLite fixtures" >&2
        return 1
    fi
    local database="$1"
    local output
    local exit_status
    [[ -e "$database" ]] || return 0
    set +e
    output="$(/usr/sbin/lsof -t "$database" 2>/dev/null)"
    exit_status=$?
    set -e
    if (( exit_status == 0 )); then
        echo "Gate F fixture database is open; quit the Debug app before resetting: $database" >&2
        return 1
    fi
    if (( exit_status != 1 )); then
        echo "could not verify that the Gate F fixture is closed: $database" >&2
        return 1
    fi
}

preflight_owned_paths
assert_databases_closed

mkdir -p "$DATASET_DIR" "$LARGE_DATASET_DIR"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

PROBE_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CORE_SOURCES=(
    "$PROJECT_ROOT"/Sources/ClipboardCore/*.swift
    "$PROJECT_ROOT"/Sources/ClipboardCore/Persistence/*.swift
    "$PROJECT_ROOT"/Sources/ClipboardCore/System/*.swift
)

echo "Building optimized ClipboardCore performance probe"
xcrun swiftc \
    -swift-version 6 \
    -O \
    -whole-module-optimization \
    -parse-as-library \
    -module-name ClipboardPerformanceProbe \
    -warnings-as-errors \
    -sdk "$PROBE_SDK_PATH" \
    "${CORE_SOURCES[@]}" \
    "$PROJECT_ROOT/Tools/ClipboardPerformanceProbe.swift" \
    -o "$PROBE" \
    -framework AppKit \
    -framework Combine \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -lsqlite3

preflight_owned_paths
assert_databases_closed

echo "Running CLI isolation guard tests"
GUARD_DIR="$(mktemp -d "$DATASET_DIR/guard-test.XXXXXX")"
GUARD_SENTINEL="$GUARD_DIR/sentinel.sqlite"
GUARD_OUTPUT="$GUARD_DIR/probe-output"
printf '%s' 'gate-f-guard-sentinel' > "$GUARD_SENTINEL"

cleanup_guard_files() {
    local cleanup_path
    for cleanup_path in \
        "${GUARD_SENTINEL:-}" \
        "${GUARD_OUTPUT:-}" \
        "${GUARD_SYMLINK_PATH:-}" \
        "${GUARD_OPEN_DB:-}"; do
        [[ -n "$cleanup_path" ]] && /bin/unlink "$cleanup_path" 2>/dev/null || true
    done
    [[ -n "${GUARD_DIRECTORY_DB:-}" ]] && rmdir "$GUARD_DIRECTORY_DB" 2>/dev/null || true
    [[ -n "${GUARD_SYMLINK_TARGET:-}" ]] && rmdir "$GUARD_SYMLINK_TARGET" 2>/dev/null || true
    rmdir "$GUARD_DIR" 2>/dev/null || true
}
trap cleanup_guard_files EXIT INT TERM

expect_rejected() {
    set +e
    "$@" > "$GUARD_OUTPUT" 2>&1
    local exit_status=$?
    set -e
    if (( exit_status == 0 )); then
        echo "guard failure: probe accepted an unsafe option" >&2
        return 1
    fi
}

# These use only a newly-created sacrificial file under the ignored Gate F
# directory. Every command must fail before parsing can touch a path or board.
expect_rejected "$PROBE" --database-path "$GUARD_SENTINEL" --reset-dataset
expect_rejected "$PROBE" --storage-directory "$GUARD_DIR"
expect_rejected "$PROBE" --pasteboard-name "NSPasteboard.general"
expect_rejected "$PROBE" --unknown-option
expect_rejected "$PROBE" --database-path

GUARD_SYMLINK_TARGET="$GUARD_DIR/symlink-target"
GUARD_SYMLINK_PATH="$GUARD_DIR/symlink-dataset"
mkdir "$GUARD_SYMLINK_TARGET"
ln -s "$GUARD_SYMLINK_TARGET" "$GUARD_SYMLINK_PATH"
if preflight_owned_path "$GUARD_SYMLINK_PATH/database.sqlite" file 2>/dev/null; then
    echo "guard failure: symlinked fixture component accepted" >&2
    exit 1
fi

GUARD_DIRECTORY_DB="$GUARD_DIR/database.sqlite"
mkdir "$GUARD_DIRECTORY_DB"
if preflight_owned_path "$GUARD_DIRECTORY_DB" file 2>/dev/null; then
    echo "guard failure: database directory accepted as a file" >&2
    exit 1
fi

GUARD_OPEN_DB="$GUARD_DIR/open.sqlite"
: > "$GUARD_OPEN_DB"
(
    exec 9>"$GUARD_OPEN_DB"
    sleep 1
) &
GUARD_HOLDER_PID=$!
sleep 0.1
if assert_database_closed "$GUARD_OPEN_DB" 2>/dev/null; then
    echo "guard failure: open sacrificial database accepted" >&2
    exit 1
fi
wait "$GUARD_HOLDER_PID"

if [[ "$(cat "$GUARD_SENTINEL")" != 'gate-f-guard-sentinel' ]]; then
    echo "guard failure: sacrificial sentinel changed" >&2
    exit 1
fi

trap - EXIT INT TERM
cleanup_guard_files

echo "Running isolated Gate F fixture"
"$PROBE" \
    --reset-dataset
