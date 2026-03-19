#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Install the merge-chunks workflow into a target repository
# ============================================================================

usage() {
    cat <<'EOF'
Usage: install-workflow.sh -r <owner/repo> [-b <branch>]

Installs the merge-chunks.yml GitHub Actions workflow into the target repository
via the GitHub Contents API. This is needed for automatic chunk merging.

Options:
  -r, --repo <owner/repo>   Target repository (required)
  -b, --branch <branch>     Target branch (default: main)
  -h, --help                Show this help
EOF
    exit 0
}

REPO=""
BRANCH="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--repo)   REPO="$2"; shift 2 ;;
        -b|--branch) BRANCH="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$REPO" ]]; then
    echo "ERROR: --repo is required"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_FILE="${SCRIPT_DIR}/.github/workflows/merge-chunks.yml"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo "ERROR: merge-chunks.yml not found at $WORKFLOW_FILE"
    exit 1
fi

echo "Installing merge-chunks workflow to $REPO (branch: $BRANCH)..."

CONTENT=$(base64 < "$WORKFLOW_FILE" | tr -d '\n')
REMOTE_PATH=".github/workflows/merge-chunks.yml"

TMPFILE=$(mktemp)
if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
body = {
    'message': '[gh-proxy-upload] Install merge-chunks workflow',
    'content': sys.argv[1],
    'branch': sys.argv[2]
}
with open(sys.argv[3], 'w') as f:
    json.dump(body, f)
" "$CONTENT" "$BRANCH" "$TMPFILE"
elif command -v jq &>/dev/null; then
    jq -n \
        --arg msg "[gh-proxy-upload] Install merge-chunks workflow" \
        --arg content "$CONTENT" \
        --arg branch "$BRANCH" \
        '{message: $msg, content: $content, branch: $branch}' > "$TMPFILE"
else
    printf '{"message":"[gh-proxy-upload] Install merge-chunks workflow","content":"%s","branch":"%s"}' \
        "$CONTENT" "$BRANCH" > "$TMPFILE"
fi

gh api --method PUT \
    "repos/${REPO}/contents/${REMOTE_PATH}" \
    --input "$TMPFILE" \
    --silent || {
    echo "ERROR: Failed to install workflow. It may already exist."
    echo "If it already exists, you can update it manually or delete it first."
    rm -f "$TMPFILE"
    exit 1
}

rm -f "$TMPFILE"
echo "Workflow installed successfully!"
echo "The merge-chunks workflow is now active at:"
echo "  https://github.com/${REPO}/blob/${BRANCH}/.github/workflows/merge-chunks.yml"
