#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

# ============================================================================
# gh-proxy-upload: Upload large files/folders to GitHub via chunked API calls
# Bypasses corporate proxy size limits (e.g., 100KB per request)
# ============================================================================

usage() {
    cat <<'EOF'
Usage: upload.sh -s <source> -r <owner/repo> [options]

Required:
  -s, --source <path>       Local file or folder to upload
  -r, --repo <owner/repo>   Target GitHub repository

Options:
  -b, --branch <branch>     Target branch (default: main)
  -p, --prefix <path>       Remote path prefix for uploaded files
  -c, --chunk-size <bytes>  Raw chunk size in bytes (default: 61440 = 60KB)
  -d, --delay <ms>          Delay between requests in ms (default: 1000)
      --resume <session-id> Resume a previous upload session
      --dry-run             Show what would be uploaded without uploading
  -h, --help                Show this help
  -v, --version             Show version
EOF
    exit 0
}

# ============================================================================
# Defaults
# ============================================================================
SOURCE=""
REPO=""
BRANCH="main"
PREFIX=""
CHUNK_SIZE=61440  # 60KB raw -> ~82KB base64 -> ~83KB JSON payload
DELAY_MS=1000
RESUME_SESSION=""
DRY_RUN=false

# ============================================================================
# Parse arguments
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source)     SOURCE="$2"; shift 2 ;;
        -r|--repo)       REPO="$2"; shift 2 ;;
        -b|--branch)     BRANCH="$2"; shift 2 ;;
        -p|--prefix)     PREFIX="$2"; shift 2 ;;
        -c|--chunk-size) CHUNK_SIZE="$2"; shift 2 ;;
        -d|--delay)      DELAY_MS="$2"; shift 2 ;;
        --resume)        RESUME_SESSION="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        -h|--help)       usage ;;
        -v|--version)    echo "gh-proxy-upload $VERSION"; exit 0 ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

# ============================================================================
# Validate
# ============================================================================
if [[ -z "$SOURCE" ]]; then
    echo "ERROR: --source is required"
    exit 1
fi
if [[ -z "$REPO" ]]; then
    echo "ERROR: --repo is required"
    exit 1
fi
if [[ ! -e "$SOURCE" ]]; then
    echo "ERROR: Source path does not exist: $SOURCE"
    exit 1
fi
if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI is not installed. Install from https://cli.github.com/"
    exit 1
fi
if ! gh auth status &>/dev/null; then
    echo "ERROR: gh CLI is not authenticated. Run: gh auth login"
    exit 1
fi

# ============================================================================
# Utility functions
# ============================================================================
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Fallback: generate pseudo-UUID from random data
        od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}'
    fi
}

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

delay_sleep() {
    if [[ "$DELAY_MS" -gt 0 ]]; then
        sleep "$(awk "BEGIN{printf \"%.3f\", $DELAY_MS/1000}")"
    fi
}

# ============================================================================
# Build file list
# ============================================================================
declare -a FILE_LIST=()
declare -a TARGET_PATHS=()

if [[ -d "$SOURCE" ]]; then
    # Directory: recursively list all files
    SOURCE_DIR="$(cd "$SOURCE" && pwd)"
    while IFS= read -r -d '' file; do
        FILE_LIST+=("$file")
        # Compute relative path from source dir
        rel_path="${file#"$SOURCE_DIR/"}"
        if [[ -n "$PREFIX" ]]; then
            TARGET_PATHS+=("$PREFIX/$rel_path")
        else
            TARGET_PATHS+=("$rel_path")
        fi
    done < <(find "$SOURCE_DIR" -type f -print0 | sort -z)
elif [[ -f "$SOURCE" ]]; then
    FILE_LIST+=("$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")")
    basename_src="$(basename "$SOURCE")"
    if [[ -n "$PREFIX" ]]; then
        TARGET_PATHS+=("$PREFIX/$basename_src")
    else
        TARGET_PATHS+=("$basename_src")
    fi
else
    echo "ERROR: Source is neither a file nor a directory: $SOURCE"
    exit 1
fi

if [[ ${#FILE_LIST[@]} -eq 0 ]]; then
    echo "ERROR: No files found in source path"
    exit 1
fi

echo "Found ${#FILE_LIST[@]} file(s) to upload"

# ============================================================================
# Session setup
# ============================================================================
if [[ -n "$RESUME_SESSION" ]]; then
    SESSION_ID="$RESUME_SESSION"
    echo "Resuming session: $SESSION_ID"
else
    SESSION_ID="$(generate_uuid)"
    echo "New session: $SESSION_ID"
fi

STATE_DIR="${HOME}/.gh-proxy-upload"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/state-${SESSION_ID}.json"

CHUNK_BASE=".gh-proxy-upload/${SESSION_ID}"

# ============================================================================
# Build manifest and compute totals
# ============================================================================
declare -a FILE_SIZES=()
declare -a FILE_HASHES=()
declare -a FILE_CHUNKS=()
TOTAL_CHUNKS=0

for i in "${!FILE_LIST[@]}"; do
    file="${FILE_LIST[$i]}"
    fsize=$(wc -c < "$file" | tr -d ' ')
    FILE_SIZES+=("$fsize")
    FILE_HASHES+=("$(sha256_file "$file")")
    if [[ "$fsize" -eq 0 ]]; then
        nchunks=0
    else
        nchunks=$(( (fsize + CHUNK_SIZE - 1) / CHUNK_SIZE ))
    fi
    FILE_CHUNKS+=("$nchunks")
    TOTAL_CHUNKS=$((TOTAL_CHUNKS + nchunks))
    echo "  [$i] ${TARGET_PATHS[$i]} (${fsize} bytes, ${nchunks} chunks)"
done

echo ""
echo "Total chunks to upload: $TOTAL_CHUNKS"
echo "Estimated time: ~$(( TOTAL_CHUNKS * (DELAY_MS + 500) / 1000 ))s"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would upload $TOTAL_CHUNKS chunks to $REPO branch $BRANCH"
    exit 0
fi

# ============================================================================
# Load resume state
# ============================================================================
declare -A UPLOADED_SET=()

if [[ -f "$STATE_FILE" ]]; then
    echo "Loading resume state from $STATE_FILE"
    while IFS= read -r line; do
        UPLOADED_SET["$line"]=1
    done < "$STATE_FILE"
    echo "  ${#UPLOADED_SET[@]} chunks already uploaded"
fi

# ============================================================================
# Rate limiter state
# ============================================================================
MINUTE_COUNT=0
MINUTE_START=$(date +%s)

check_rate_limit() {
    MINUTE_COUNT=$((MINUTE_COUNT + 1))
    if [[ $MINUTE_COUNT -ge 75 ]]; then
        local now elapsed remaining
        now=$(date +%s)
        elapsed=$((now - MINUTE_START))
        if [[ $elapsed -lt 62 ]]; then
            remaining=$((62 - elapsed))
            echo "  [RATE LIMIT] Pausing ${remaining}s (75 requests/minute limit)"
            sleep "$remaining"
        fi
        MINUTE_COUNT=0
        MINUTE_START=$(date +%s)
    fi
}

# ============================================================================
# Upload function with retry
# ============================================================================
upload_chunk() {
    local remote_path="$1"
    local b64_content="$2"
    local commit_msg="$3"
    local tmpfile
    tmpfile=$(mktemp)

    # Build JSON body - use python/perl/jq to safely construct JSON
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
body = {
    'message': sys.argv[1],
    'content': sys.argv[2],
    'branch': sys.argv[3]
}
with open(sys.argv[4], 'w') as f:
    json.dump(body, f)
" "$commit_msg" "$b64_content" "$BRANCH" "$tmpfile"
    elif command -v jq &>/dev/null; then
        jq -n \
            --arg msg "$commit_msg" \
            --arg content "$b64_content" \
            --arg branch "$BRANCH" \
            '{message: $msg, content: $content, branch: $branch}' > "$tmpfile"
    else
        # Fallback: manual JSON (safe since base64 has no special chars)
        printf '{"message":"%s","content":"%s","branch":"%s"}' \
            "$commit_msg" "$b64_content" "$BRANCH" > "$tmpfile"
    fi

    local attempt max_attempts=3
    for attempt in $(seq 1 $max_attempts); do
        local http_code
        http_code=$(gh api --method PUT \
            "repos/${REPO}/contents/${remote_path}" \
            --input "$tmpfile" \
            --silent \
            -i 2>&1 | head -1 | grep -oE '[0-9]{3}' || echo "000")

        case "$http_code" in
            201|200)
                rm -f "$tmpfile"
                return 0
                ;;
            422)
                # File might already exist (resume case)
                echo "  [WARN] 422 - file may already exist, skipping: $remote_path"
                rm -f "$tmpfile"
                return 0
                ;;
            403|429)
                local wait_time=$((60 * attempt))
                echo "  [RATE LIMITED] HTTP $http_code, waiting ${wait_time}s (attempt $attempt/$max_attempts)"
                sleep "$wait_time"
                ;;
            409)
                local wait_time=$((5 * attempt))
                echo "  [CONFLICT] HTTP 409, retrying in ${wait_time}s (attempt $attempt/$max_attempts)"
                sleep "$wait_time"
                ;;
            *)
                local wait_time=$((3 * attempt))
                echo "  [ERROR] HTTP $http_code, retrying in ${wait_time}s (attempt $attempt/$max_attempts)"
                sleep "$wait_time"
                ;;
        esac
    done

    rm -f "$tmpfile"
    echo "FATAL: Failed to upload $remote_path after $max_attempts attempts"
    return 1
}

# ============================================================================
# Main upload loop
# ============================================================================
GLOBAL_COUNTER=0

for file_idx in "${!FILE_LIST[@]}"; do
    file="${FILE_LIST[$file_idx]}"
    target="${TARGET_PATHS[$file_idx]}"
    nchunks="${FILE_CHUNKS[$file_idx]}"
    file_idx_padded=$(printf "%03d" "$file_idx")

    if [[ "$nchunks" -eq 0 ]]; then
        echo "[SKIP] Empty file: $target"
        continue
    fi

    echo "Uploading: $target ($nchunks chunks)"

    for chunk_idx in $(seq 0 $((nchunks - 1))); do
        chunk_key="${file_idx}/${chunk_idx}"
        GLOBAL_COUNTER=$((GLOBAL_COUNTER + 1))

        # Skip if already uploaded (resume)
        if [[ -n "${UPLOADED_SET[$chunk_key]+_}" ]]; then
            echo "  [SKIP] [$GLOBAL_COUNTER/$TOTAL_CHUNKS] chunk $chunk_idx (already uploaded)"
            continue
        fi

        # Rate limit check
        check_rate_limit

        # Read chunk bytes and base64 encode
        local_offset=$((chunk_idx * CHUNK_SIZE))
        chunk_idx_padded=$(printf "%04d" "$chunk_idx")
        remote_path="${CHUNK_BASE}/files/${file_idx_padded}/chunk_${chunk_idx_padded}.chunk"
        commit_msg="[gh-proxy-upload] ${SESSION_ID} file ${file_idx} chunk ${chunk_idx}/${nchunks}"

        # Extract chunk and base64 encode
        b64_content=$(dd if="$file" bs=1 skip="$local_offset" count="$CHUNK_SIZE" 2>/dev/null | base64 | tr -d '\n')

        # Upload
        if ! upload_chunk "$remote_path" "$b64_content" "$commit_msg"; then
            echo "Upload failed at chunk $chunk_key. Use --resume $SESSION_ID to continue."
            exit 1
        fi

        # Save state
        echo "$chunk_key" >> "$STATE_FILE"
        UPLOADED_SET["$chunk_key"]=1

        echo "  [OK] [$GLOBAL_COUNTER/$TOTAL_CHUNKS] $remote_path"

        # Throttle
        delay_sleep
    done
done

# ============================================================================
# Upload manifest (last!)
# ============================================================================
echo ""
echo "All chunks uploaded. Uploading manifest..."

# Build manifest JSON
MANIFEST_FILES=""
for i in "${!FILE_LIST[@]}"; do
    [[ $i -gt 0 ]] && MANIFEST_FILES+=","
    MANIFEST_FILES+=$(cat <<ENTRY
{
    "index": $i,
    "target_path": "${TARGET_PATHS[$i]}",
    "original_size": ${FILE_SIZES[$i]},
    "sha256": "${FILE_HASHES[$i]}",
    "total_chunks": ${FILE_CHUNKS[$i]},
    "raw_chunk_size": $CHUNK_SIZE
}
ENTRY
)
done

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MANIFEST_JSON=$(cat <<MANIFEST
{
    "version": 1,
    "session_id": "$SESSION_ID",
    "created_at": "$CREATED_AT",
    "tool_version": "$VERSION",
    "status": "complete",
    "files": [$MANIFEST_FILES]
}
MANIFEST
)

# Upload manifest via temp file
MANIFEST_TMPFILE=$(mktemp)
MANIFEST_B64=$(echo "$MANIFEST_JSON" | base64 | tr -d '\n')

if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
body = {
    'message': sys.argv[1],
    'content': sys.argv[2],
    'branch': sys.argv[3]
}
with open(sys.argv[4], 'w') as f:
    json.dump(body, f)
" "[gh-proxy-upload] manifest for session $SESSION_ID" "$MANIFEST_B64" "$BRANCH" "$MANIFEST_TMPFILE"
elif command -v jq &>/dev/null; then
    jq -n \
        --arg msg "[gh-proxy-upload] manifest for session $SESSION_ID" \
        --arg content "$MANIFEST_B64" \
        --arg branch "$BRANCH" \
        '{message: $msg, content: $content, branch: $branch}' > "$MANIFEST_TMPFILE"
else
    printf '{"message":"[gh-proxy-upload] manifest for session %s","content":"%s","branch":"%s"}' \
        "$SESSION_ID" "$MANIFEST_B64" "$BRANCH" > "$MANIFEST_TMPFILE"
fi

gh api --method PUT \
    "repos/${REPO}/contents/${CHUNK_BASE}/manifest.json" \
    --input "$MANIFEST_TMPFILE" \
    --silent || {
    echo "ERROR: Failed to upload manifest"
    rm -f "$MANIFEST_TMPFILE"
    exit 1
}
rm -f "$MANIFEST_TMPFILE"

echo "Manifest uploaded: ${CHUNK_BASE}/manifest.json"

# ============================================================================
# Cleanup
# ============================================================================
rm -f "$STATE_FILE"

echo ""
echo "========================================"
echo " Upload complete!"
echo " Session:  $SESSION_ID"
echo " Repo:     $REPO"
echo " Branch:   $BRANCH"
echo " Files:    ${#FILE_LIST[@]}"
echo " Chunks:   $TOTAL_CHUNKS"
echo "========================================"
echo ""
echo "If the target repo has the merge-chunks workflow installed,"
echo "GitHub Actions will automatically merge the chunks."
echo ""
echo "To install the workflow in your target repo, copy:"
echo "  .github/workflows/merge-chunks.yml"
echo "into the target repository."
