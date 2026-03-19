#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

# ============================================================================
# gh-proxy-upload download: Download and merge chunked uploads locally
# ============================================================================

usage() {
    cat <<'EOF'
Usage: download.sh -r <owner/repo> -i <session-id> [options]

Required:
  -r, --repo <owner/repo>     Source GitHub repository
  -i, --session-id <uuid>     Upload session ID to download

Options:
  -b, --branch <branch>       Branch to download from (default: main)
  -o, --output <dir>          Output directory (default: current directory)
  -h, --help                  Show this help
EOF
    exit 0
}

REPO=""
SESSION_ID=""
BRANCH="main"
OUTPUT_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--repo)       REPO="$2"; shift 2 ;;
        -i|--session-id) SESSION_ID="$2"; shift 2 ;;
        -b|--branch)     BRANCH="$2"; shift 2 ;;
        -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$REPO" || -z "$SESSION_ID" ]]; then
    echo "ERROR: --repo and --session-id are required"
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI is not installed"
    exit 1
fi

sha256_file() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | cut -d' ' -f1
    else
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    fi
}

CHUNK_BASE=".gh-proxy-upload/${SESSION_ID}"

# Download manifest
echo "Downloading manifest..."
MANIFEST_TMPFILE=$(mktemp)
gh api "repos/${REPO}/contents/${CHUNK_BASE}/manifest.json" \
    --jq '.content' \
    -H "Accept: application/vnd.github.v3+json" \
    | base64 -d > "$MANIFEST_TMPFILE" 2>/dev/null || \
gh api "repos/${REPO}/contents/${CHUNK_BASE}/manifest.json" \
    -H "Accept: application/vnd.github.raw+json" \
    > "$MANIFEST_TMPFILE"

if [[ ! -s "$MANIFEST_TMPFILE" ]]; then
    echo "ERROR: Failed to download manifest"
    rm -f "$MANIFEST_TMPFILE"
    exit 1
fi

echo "Manifest downloaded."

# Parse manifest
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for parsing manifest. Install jq."
    rm -f "$MANIFEST_TMPFILE"
    exit 1
fi

STATUS=$(jq -r '.status' "$MANIFEST_TMPFILE")
if [[ "$STATUS" != "complete" ]]; then
    echo "WARNING: Manifest status is '$STATUS', upload may be incomplete"
fi

FILE_COUNT=$(jq '.files | length' "$MANIFEST_TMPFILE")
echo "Files to download: $FILE_COUNT"
echo ""

ERRORS=0

for i in $(seq 0 $((FILE_COUNT - 1))); do
    TARGET_PATH=$(jq -r ".files[$i].target_path" "$MANIFEST_TMPFILE")
    TOTAL_CHUNKS=$(jq -r ".files[$i].total_chunks" "$MANIFEST_TMPFILE")
    EXPECTED_SHA256=$(jq -r ".files[$i].sha256" "$MANIFEST_TMPFILE")
    ORIGINAL_SIZE=$(jq -r ".files[$i].original_size" "$MANIFEST_TMPFILE")
    FILE_INDEX=$(printf "%03d" "$i")

    OUTPUT_PATH="${OUTPUT_DIR}/${TARGET_PATH}"
    echo "Downloading: $TARGET_PATH ($TOTAL_CHUNKS chunks, $ORIGINAL_SIZE bytes)"

    mkdir -p "$(dirname "$OUTPUT_PATH")"

    if [[ "$TOTAL_CHUNKS" -eq 0 ]]; then
        : > "$OUTPUT_PATH"
        echo "  Created empty file"
        continue
    fi

    : > "${OUTPUT_PATH}.tmp"

    for c in $(seq 0 $((TOTAL_CHUNKS - 1))); do
        CHUNK_IDX=$(printf "%04d" "$c")
        CHUNK_REMOTE="${CHUNK_BASE}/files/${FILE_INDEX}/chunk_${CHUNK_IDX}.chunk"

        # Download raw content
        CHUNK_TMP=$(mktemp)
        if ! gh api "repos/${REPO}/contents/${CHUNK_REMOTE}" \
            -H "Accept: application/vnd.github.raw+json" \
            > "$CHUNK_TMP" 2>/dev/null; then
            echo "  ERROR: Failed to download chunk $c"
            rm -f "$CHUNK_TMP"
            ERRORS=$((ERRORS + 1))
            break
        fi

        cat "$CHUNK_TMP" >> "${OUTPUT_PATH}.tmp"
        rm -f "$CHUNK_TMP"

        echo "  [$((c + 1))/$TOTAL_CHUNKS] chunk_${CHUNK_IDX}"
    done

    # Verify
    ACTUAL_SHA256=$(sha256_file "${OUTPUT_PATH}.tmp")
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "  ERROR: SHA256 mismatch!"
        echo "    Expected: $EXPECTED_SHA256"
        echo "    Actual:   $ACTUAL_SHA256"
        rm -f "${OUTPUT_PATH}.tmp"
        ERRORS=$((ERRORS + 1))
    else
        mv "${OUTPUT_PATH}.tmp" "$OUTPUT_PATH"
        ACTUAL_SIZE=$(wc -c < "$OUTPUT_PATH" | tr -d ' ')
        echo "  OK: $OUTPUT_PATH ($ACTUAL_SIZE bytes, SHA256 verified)"
    fi
    echo ""
done

rm -f "$MANIFEST_TMPFILE"

if [[ "$ERRORS" -gt 0 ]]; then
    echo "COMPLETED WITH $ERRORS ERROR(S)"
    exit 1
else
    echo "All files downloaded and verified successfully!"
fi
