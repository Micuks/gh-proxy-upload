#Requires -Version 5.1

<#
.SYNOPSIS
    Upload large files/folders to GitHub via chunked API calls.

.DESCRIPTION
    gh-proxy-upload: Bypasses corporate proxy size limits (e.g., 100KB per request)
    by splitting files into base64-encoded chunks and uploading via the GitHub Contents API.
    A manifest.json is uploaded last so that a merge-chunks workflow can reassemble the file.

.PARAMETER Source
    Local file or folder to upload (required).

.PARAMETER Repo
    Target GitHub repository in owner/repo format (required).

.PARAMETER Branch
    Target branch (default: main).

.PARAMETER Prefix
    Remote path prefix for uploaded files.

.PARAMETER ChunkSize
    Raw chunk size in bytes (default: 61440 = 60KB, ~82KB base64).

.PARAMETER Delay
    Delay between requests in milliseconds (default: 1000).

.PARAMETER Resume
    Resume a previous upload session by providing the session ID.

.PARAMETER DryRun
    Show what would be uploaded without uploading.

.EXAMPLE
    .\upload.ps1 -Source .\myfile.bin -Repo owner/repo

.EXAMPLE
    .\upload.ps1 -Source .\folder -Repo owner/repo -Branch dev -Prefix "data/v2"

.EXAMPLE
    .\upload.ps1 -Source .\myfile.bin -Repo owner/repo -Resume "abc-123"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Branch = "main",

    [string]$Prefix = "",

    [int]$ChunkSize = 61440,

    [int]$Delay = 1000,

    [string]$Resume = "",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$VERSION = "1.0.0"

# ============================================================================
# Validate prerequisites
# ============================================================================

$Source = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Error "Source path does not exist: $Source"
    exit 1
}

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Write-Error "gh CLI is not installed. Install from https://cli.github.com/"
    exit 1
}

$null = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "gh CLI is not authenticated. Run: gh auth login"
    exit 1
}

# ============================================================================
# Utility functions
# ============================================================================

function New-SessionId {
    return [guid]::NewGuid().ToString("D")
}

function Get-FileSha256 {
    param([string]$FilePath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $hashBytes = $sha.ComputeHash($stream)
            return [BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $stream.Close()
        }
    }
    finally {
        $sha.Dispose()
    }
}

function Read-ChunkBytes {
    <#
    .SYNOPSIS
        Read a specific byte range from a file using FileStream (dd equivalent).
    #>
    param(
        [string]$FilePath,
        [long]$Offset,
        [int]$Count
    )
    $fs = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $fileLen = $fs.Length
        if ($Offset -ge $fileLen) {
            return [byte[]]@()
        }
        $remaining = $fileLen - $Offset
        if ($remaining -lt $Count) {
            $Count = [int]$remaining
        }
        $buffer = [byte[]]::new($Count)
        $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $totalRead = 0
        while ($totalRead -lt $Count) {
            $bytesRead = $fs.Read($buffer, $totalRead, $Count - $totalRead)
            if ($bytesRead -eq 0) { break }
            $totalRead += $bytesRead
        }
        if ($totalRead -lt $Count) {
            $trimmed = [byte[]]::new($totalRead)
            [Array]::Copy($buffer, $trimmed, $totalRead)
            return $trimmed
        }
        return $buffer
    }
    finally {
        $fs.Close()
    }
}

function Invoke-DelayedSleep {
    if ($Delay -gt 0) {
        Start-Sleep -Milliseconds $Delay
    }
}

# ============================================================================
# Build file list
# ============================================================================

$fileList = [System.Collections.Generic.List[string]]::new()
$targetPaths = [System.Collections.Generic.List[string]]::new()

$sourceItem = Get-Item -LiteralPath $Source

if ($sourceItem.PSIsContainer) {
    # Directory: recursively list all files
    $sourceDir = $sourceItem.FullName.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $allFiles = Get-ChildItem -LiteralPath $sourceDir -Recurse -File | Sort-Object FullName
    foreach ($f in $allFiles) {
        $fileList.Add($f.FullName)
        # Compute relative path, convert backslashes to forward slashes for the API
        $relPath = $f.FullName.Substring($sourceDir.Length + 1).Replace('\', '/')
        if ($Prefix) {
            $targetPaths.Add("$Prefix/$relPath")
        }
        else {
            $targetPaths.Add($relPath)
        }
    }
}
elseif (Test-Path -LiteralPath $Source -PathType Leaf) {
    $fileList.Add($sourceItem.FullName)
    $baseName = $sourceItem.Name
    if ($Prefix) {
        $targetPaths.Add("$Prefix/$baseName")
    }
    else {
        $targetPaths.Add($baseName)
    }
}
else {
    Write-Error "Source is neither a file nor a directory: $Source"
    exit 1
}

if ($fileList.Count -eq 0) {
    Write-Error "No files found in source path"
    exit 1
}

Write-Host "Found $($fileList.Count) file(s) to upload"

# ============================================================================
# Session setup
# ============================================================================

if ($Resume) {
    $sessionId = $Resume
    Write-Host "Resuming session: $sessionId"
}
else {
    $sessionId = New-SessionId
    Write-Host "New session: $sessionId"
}

$stateDir = Join-Path $HOME ".gh-proxy-upload"
if (-not (Test-Path -LiteralPath $stateDir)) {
    $null = New-Item -ItemType Directory -Path $stateDir -Force
}
$stateFile = Join-Path $stateDir "state-${sessionId}.json"

$chunkBase = ".gh-proxy-upload/$sessionId"

# ============================================================================
# Build manifest and compute totals
# ============================================================================

$fileSizes = [System.Collections.Generic.List[long]]::new()
$fileHashes = [System.Collections.Generic.List[string]]::new()
$fileChunks = [System.Collections.Generic.List[int]]::new()
$totalChunks = 0

for ($i = 0; $i -lt $fileList.Count; $i++) {
    $filePath = $fileList[$i]
    $fInfo = [System.IO.FileInfo]::new($filePath)
    $fsize = $fInfo.Length
    $fileSizes.Add($fsize)
    $fileHashes.Add((Get-FileSha256 -FilePath $filePath))

    if ($fsize -eq 0) {
        $nchunks = 0
    }
    else {
        $nchunks = [int][Math]::Ceiling($fsize / $ChunkSize)
    }
    $fileChunks.Add($nchunks)
    $totalChunks += $nchunks

    Write-Host "  [$i] $($targetPaths[$i]) ($fsize bytes, $nchunks chunks)"
}

Write-Host ""
Write-Host "Total chunks to upload: $totalChunks"
$estimatedSeconds = [int]($totalChunks * ($Delay + 500) / 1000)
Write-Host "Estimated time: ~${estimatedSeconds}s"
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] Would upload $totalChunks chunks to $Repo branch $Branch"
    exit 0
}

# ============================================================================
# Load resume state
# ============================================================================

$uploadedSet = [System.Collections.Generic.HashSet[string]]::new()

if (Test-Path -LiteralPath $stateFile) {
    Write-Host "Loading resume state from $stateFile"
    $lines = Get-Content -LiteralPath $stateFile -Encoding UTF8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed) {
            $null = $uploadedSet.Add($trimmed)
        }
    }
    Write-Host "  $($uploadedSet.Count) chunks already uploaded"
}

# ============================================================================
# Rate limiter state
# ============================================================================

$script:minuteCount = 0
$script:minuteStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Test-RateLimit {
    $script:minuteCount++
    if ($script:minuteCount -ge 75) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $elapsed = $now - $script:minuteStart
        if ($elapsed -lt 62) {
            $remaining = 62 - $elapsed
            Write-Host "  [RATE LIMIT] Pausing ${remaining}s (75 requests/minute limit)"
            Start-Sleep -Seconds $remaining
        }
        $script:minuteCount = 0
        $script:minuteStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

# ============================================================================
# Upload function with retry
# ============================================================================

function Invoke-UploadChunk {
    param(
        [string]$RemotePath,
        [string]$Base64Content,
        [string]$CommitMessage
    )

    # Build JSON body via ConvertTo-Json and write to temp file to avoid
    # argument length limits on the command line.
    $body = @{
        message = $CommitMessage
        content = $Base64Content
        branch  = $Branch
    }
    $jsonBody = $body | ConvertTo-Json -Depth 5 -Compress
    $tmpFile = [System.IO.Path]::GetTempFileName()

    try {
        [System.IO.File]::WriteAllText($tmpFile, $jsonBody, [System.Text.Encoding]::UTF8)

        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $rawOutput = & gh api --method PUT `
                    "repos/${Repo}/contents/${RemotePath}" `
                    --input $tmpFile `
                    -i 2>&1

                # Parse HTTP status code from the first line of the response
                $firstLine = ($rawOutput | Select-Object -First 1) -as [string]
                $httpCode = "000"
                if ($firstLine -match '(\d{3})') {
                    $httpCode = $Matches[1]
                }
            }
            catch {
                $httpCode = "000"
            }

            switch ($httpCode) {
                { $_ -in @("200", "201") } {
                    return $true
                }
                "422" {
                    # File might already exist (resume case)
                    Write-Host "  [WARN] 422 - file may already exist, skipping: $RemotePath"
                    return $true
                }
                { $_ -in @("403", "429") } {
                    $waitTime = 60 * $attempt
                    Write-Host "  [RATE LIMITED] HTTP $httpCode, waiting ${waitTime}s (attempt $attempt/$maxAttempts)"
                    Start-Sleep -Seconds $waitTime
                }
                "409" {
                    $waitTime = 5 * $attempt
                    Write-Host "  [CONFLICT] HTTP 409, retrying in ${waitTime}s (attempt $attempt/$maxAttempts)"
                    Start-Sleep -Seconds $waitTime
                }
                default {
                    $waitTime = 3 * $attempt
                    Write-Host "  [ERROR] HTTP $httpCode, retrying in ${waitTime}s (attempt $attempt/$maxAttempts)"
                    Start-Sleep -Seconds $waitTime
                }
            }
        }

        Write-Host "FATAL: Failed to upload $RemotePath after $maxAttempts attempts"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tmpFile) {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Main upload loop
# ============================================================================

$globalCounter = 0

for ($fileIdx = 0; $fileIdx -lt $fileList.Count; $fileIdx++) {
    $file = $fileList[$fileIdx]
    $target = $targetPaths[$fileIdx]
    $nchunks = $fileChunks[$fileIdx]
    $fileIdxPadded = $fileIdx.ToString("D3")

    if ($nchunks -eq 0) {
        Write-Host "[SKIP] Empty file: $target"
        continue
    }

    Write-Host "Uploading: $target ($nchunks chunks)"

    for ($chunkIdx = 0; $chunkIdx -lt $nchunks; $chunkIdx++) {
        $chunkKey = "${fileIdx}/${chunkIdx}"
        $globalCounter++

        # Skip if already uploaded (resume)
        if ($uploadedSet.Contains($chunkKey)) {
            Write-Host "  [SKIP] [$globalCounter/$totalChunks] chunk $chunkIdx (already uploaded)"
            continue
        }

        # Rate limit check
        Test-RateLimit

        # Read chunk bytes and base64 encode
        $localOffset = [long]$chunkIdx * [long]$ChunkSize
        $chunkIdxPadded = $chunkIdx.ToString("D4")
        $remotePath = "${chunkBase}/files/${fileIdxPadded}/chunk_${chunkIdxPadded}.chunk"
        $commitMsg = "[gh-proxy-upload] ${sessionId} file ${fileIdx} chunk ${chunkIdx}/${nchunks}"

        # Extract chunk via FileStream and base64 encode
        $chunkBytes = Read-ChunkBytes -FilePath $file -Offset $localOffset -Count $ChunkSize
        $b64Content = [Convert]::ToBase64String($chunkBytes)

        # Upload
        $success = Invoke-UploadChunk -RemotePath $remotePath -Base64Content $b64Content -CommitMessage $commitMsg
        if (-not $success) {
            Write-Host "Upload failed at chunk $chunkKey. Use -Resume '$sessionId' to continue."
            exit 1
        }

        # Save state
        Add-Content -LiteralPath $stateFile -Value $chunkKey -Encoding UTF8
        $null = $uploadedSet.Add($chunkKey)

        Write-Host "  [OK] [$globalCounter/$totalChunks] $remotePath"

        # Throttle
        Invoke-DelayedSleep
    }
}

# ============================================================================
# Upload manifest (last!)
# ============================================================================

Write-Host ""
Write-Host "All chunks uploaded. Uploading manifest..."

# Build manifest object
$manifestFiles = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $fileList.Count; $i++) {
    $manifestFiles.Add(@{
        index          = $i
        target_path    = $targetPaths[$i]
        original_size  = $fileSizes[$i]
        sha256         = $fileHashes[$i]
        total_chunks   = $fileChunks[$i]
        raw_chunk_size = $ChunkSize
    })
}

$createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$manifest = @{
    version      = 1
    session_id   = $sessionId
    created_at   = $createdAt
    tool_version = $VERSION
    status       = "complete"
    files        = $manifestFiles.ToArray()
}

$manifestJson = $manifest | ConvertTo-Json -Depth 10
$manifestB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($manifestJson))

$manifestBody = @{
    message = "[gh-proxy-upload] manifest for session $sessionId"
    content = $manifestB64
    branch  = $Branch
} | ConvertTo-Json -Depth 5 -Compress

$manifestTmpFile = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($manifestTmpFile, $manifestBody, [System.Text.Encoding]::UTF8)

    & gh api --method PUT `
        "repos/${Repo}/contents/${chunkBase}/manifest.json" `
        --input $manifestTmpFile `
        --silent 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to upload manifest"
        exit 1
    }
}
finally {
    if (Test-Path -LiteralPath $manifestTmpFile) {
        Remove-Item -LiteralPath $manifestTmpFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Manifest uploaded: ${chunkBase}/manifest.json"

# ============================================================================
# Cleanup
# ============================================================================

if (Test-Path -LiteralPath $stateFile) {
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================"
Write-Host " Upload complete!"
Write-Host " Session:  $sessionId"
Write-Host " Repo:     $Repo"
Write-Host " Branch:   $Branch"
Write-Host " Files:    $($fileList.Count)"
Write-Host " Chunks:   $totalChunks"
Write-Host "========================================"
Write-Host ""
Write-Host "If the target repo has the merge-chunks workflow installed,"
Write-Host "GitHub Actions will automatically merge the chunks."
Write-Host ""
Write-Host "To install the workflow in your target repo, copy:"
Write-Host "  .github/workflows/merge-chunks.yml"
Write-Host "into the target repository."
