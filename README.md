# gh-proxy-upload

Upload large files and folders to GitHub repositories through corporate proxies that limit HTTP request size (e.g., 100KB).

## Problem

Corporate proxy servers (like Huawei HIS proxy) often truncate HTTP requests exceeding a size threshold (commonly 100KB). This prevents uploading files larger than ~75KB to GitHub via the API, since the GitHub Contents API requires base64 encoding (33% overhead) plus JSON wrapper.

## How It Works

```
┌──────────────┐     ┌─────────┐     ┌──────────────┐     ┌─────────────┐
│ Local Machine │────>│  Proxy  │────>│  GitHub API  │────>│  Repository │
│              │     │ (100KB  │     │              │     │             │
│ 3.4MB file   │     │  limit) │     │ PUT contents │     │ .gh-proxy-  │
│   ↓          │     │         │     │ per chunk    │     │  upload/    │
│ 57 chunks    │     │ ~83KB   │     │              │     │  {uuid}/   │
│ × 60KB each  │────>│ each ✓  │────>│              │────>│  chunks... │
└──────────────┘     └─────────┘     └──────────────┘     └──────┬──────┘
                                                                 │
                                                    GitHub Actions trigger
                                                                 │
                                                          ┌──────▼──────┐
                                                          │ Reassemble  │
                                                          │ + SHA256    │
                                                          │ verify      │
                                                          │ + commit    │
                                                          └─────────────┘
```

1. **Split**: Files are split into ~60KB raw chunks
2. **Encode**: Each chunk is base64-encoded (~80KB) and wrapped in a JSON payload (~83KB total, under 100KB limit)
3. **Upload**: Each chunk is uploaded via `gh api` as a separate file under `.gh-proxy-upload/{session-uuid}/`
4. **Manifest**: A `manifest.json` is uploaded **last**, containing file metadata and SHA256 hashes
5. **Merge**: A GitHub Actions workflow detects the manifest, reassembles files, verifies integrity, and commits

## Quick Start

### 1. Install the merge workflow in your target repo

Copy the workflow file to your target repository:

```bash
# Clone this tool
git clone https://github.com/micuks/gh-proxy-upload.git

# Copy workflow to your target repo
cp gh-proxy-upload/.github/workflows/merge-chunks.yml \
   /path/to/your-repo/.github/workflows/

# Commit and push the workflow
cd /path/to/your-repo
git add .github/workflows/merge-chunks.yml
git commit -m "Add gh-proxy-upload merge workflow"
git push
```

### 2. Upload files

**Single file (Bash):**
```bash
./upload.sh -s document.docx -r owner/repo
```

**Folder (Bash):**
```bash
./upload.sh -s ./my-folder -r owner/repo -p docs/uploads
```

**Single file (PowerShell):**
```powershell
.\upload.ps1 -Source document.docx -Repo owner/repo
```

**Folder (PowerShell):**
```powershell
.\upload.ps1 -Source .\my-folder -Repo owner/repo -Prefix docs/uploads
```

### 3. Wait for merge

GitHub Actions will automatically detect the upload and merge the chunks into the target files. Check the Actions tab in your repository.

## Usage

### upload.sh / upload.ps1

| Parameter | Bash Flag | PowerShell | Default | Description |
|-----------|-----------|------------|---------|-------------|
| Source | `-s, --source` | `-Source` | (required) | Local file or folder |
| Repo | `-r, --repo` | `-Repo` | (required) | Target repo (`owner/repo`) |
| Branch | `-b, --branch` | `-Branch` | `main` | Target branch |
| Prefix | `-p, --prefix` | `-Prefix` | (root) | Remote path prefix |
| Chunk size | `-c, --chunk-size` | `-ChunkSize` | `61440` | Raw chunk size (bytes) |
| Delay | `-d, --delay` | `-Delay` | `1000` | Delay between requests (ms) |
| Resume | `--resume <id>` | `-Resume` | — | Resume a failed upload |
| Dry run | `--dry-run` | `-DryRun` | — | Preview without uploading |

### download.sh / download.ps1

For manually downloading and merging chunks without GitHub Actions:

```bash
./download.sh -r owner/repo -i <session-id> -o ./output
```

```powershell
.\download.ps1 -Repo owner/repo -SessionId <session-id> -OutputDir .\output
```

## Resume Support

If an upload is interrupted, resume it using the session ID shown at the start:

```bash
# Session ID is printed when upload starts:
# "New session: 550e8400-e29b-41d4-a716-446655440000"

./upload.sh -s document.docx -r owner/repo --resume 550e8400-e29b-41d4-a716-446655440000
```

```powershell
.\upload.ps1 -Source document.docx -Repo owner/repo -Resume 550e8400-e29b-41d4-a716-446655440000
```

## Configuration Tips

### Stricter proxy limits

If your proxy limits are lower than 100KB, reduce the chunk size:

```bash
# 40KB chunks → ~55KB payload
./upload.sh -s file.bin -r owner/repo -c 40960
```

### Rate limiting

GitHub allows ~80 content-creation requests per minute. The scripts automatically throttle. Adjust the delay if needed:

```bash
# 2 second delay between requests
./upload.sh -s file.bin -r owner/repo -d 2000
```

### Large files

| File Size | Chunks (60KB) | Est. Time |
|-----------|---------------|-----------|
| 1 MB | 18 | ~30s |
| 5 MB | 86 | ~2.5min |
| 10 MB | 171 | ~5min |
| 50 MB | 854 | ~25min |

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated
- `jq` (for Bash scripts, optional but recommended)
- `python3` (for Bash scripts, used for safe JSON construction; falls back to `jq`)
- PowerShell 5.1+ (for Windows scripts)

## Troubleshooting

### "422 - sha is required"
The chunk file already exists. This usually means you're re-running an upload. Use `--resume` with the session ID, or start a new session (new UUID will be generated).

### "403 - rate limit exceeded"
The scripts automatically handle this by pausing and retrying. If it persists, increase `--delay`.

### GitHub Actions workflow not triggering
Ensure the `merge-chunks.yml` workflow file exists in the **default branch** of your target repository. Workflows must be on the default branch to be triggered.

### SHA256 mismatch after merge
This indicates data corruption during upload. Delete the session directory from the repo and re-upload:
```bash
# Delete the failed session via API
gh api --method DELETE "repos/owner/repo/contents/.gh-proxy-upload/<session-id>" ...
```
Or simply re-run the upload (a new session ID will be generated).

## License

MIT
