#Requires -Version 5.1

<#
.SYNOPSIS
    Download and merge chunked uploads from GitHub.

.DESCRIPTION
    Downloads chunks uploaded by gh-proxy-upload and reassembles them locally.
    Verifies SHA256 integrity of each reassembled file.

.PARAMETER Repo
    Source GitHub repository in owner/repo format (required).

.PARAMETER SessionId
    Upload session ID (UUID) to download (required).

.PARAMETER Branch
    Branch to download from (default: main).

.PARAMETER OutputDir
    Output directory (default: current directory).

.EXAMPLE
    .\download.ps1 -Repo "owner/repo" -SessionId "abc-123-def"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [Parameter(Mandatory = $true)]
    [string]$SessionId,

    [string]$Branch = "main",

    [string]$OutputDir = "."
)

$ErrorActionPreference = "Stop"

# Validate gh CLI
if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
    Write-Error "gh CLI is not installed. Install from https://cli.github.com/"
    exit 1
}

function Get-FileSHA256 {
    param([string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return [BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
        }
        finally {
            $stream.Close()
        }
    }
    finally {
        $sha256.Dispose()
    }
}

$chunkBase = ".gh-proxy-upload/$SessionId"

# Download manifest
Write-Host "Downloading manifest..."
$manifestTmp = [System.IO.Path]::GetTempFileName()

try {
    gh api "repos/$Repo/contents/$chunkBase/manifest.json" `
        -H "Accept: application/vnd.github.raw+json" `
        | Out-File -FilePath $manifestTmp -Encoding UTF8
}
catch {
    Write-Error "Failed to download manifest: $_"
    Remove-Item -Path $manifestTmp -Force -ErrorAction SilentlyContinue
    exit 1
}

$manifest = Get-Content -Path $manifestTmp -Raw | ConvertFrom-Json
Remove-Item -Path $manifestTmp -Force

if ($manifest.status -ne "complete") {
    Write-Warning "Manifest status is '$($manifest.status)', upload may be incomplete"
}

$fileCount = $manifest.files.Count
Write-Host "Files to download: $fileCount"
Write-Host ""

$errors = 0

for ($i = 0; $i -lt $fileCount; $i++) {
    $fileEntry = $manifest.files[$i]
    $targetPath = $fileEntry.target_path
    $totalChunks = [int]$fileEntry.total_chunks
    $expectedSha256 = $fileEntry.sha256
    $originalSize = [long]$fileEntry.original_size
    $fileIndex = $i.ToString("D3")

    $outputPath = Join-Path $OutputDir $targetPath
    Write-Host "Downloading: $targetPath ($totalChunks chunks, $originalSize bytes)"

    $outputDirPath = Split-Path -Path $outputPath -Parent
    if (-not (Test-Path $outputDirPath)) {
        New-Item -ItemType Directory -Path $outputDirPath -Force | Out-Null
    }

    if ($totalChunks -eq 0) {
        New-Item -ItemType File -Path $outputPath -Force | Out-Null
        Write-Host "  Created empty file"
        continue
    }

    $tmpPath = "$outputPath.tmp"
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force }

    # Create output stream
    $outStream = [System.IO.File]::Create($tmpPath)
    $downloadFailed = $false

    try {
        for ($c = 0; $c -lt $totalChunks; $c++) {
            $chunkIdx = $c.ToString("D4")
            $chunkRemote = "$chunkBase/files/$fileIndex/chunk_$chunkIdx.chunk"

            $chunkTmp = [System.IO.Path]::GetTempFileName()

            try {
                gh api "repos/$Repo/contents/$chunkRemote" `
                    -H "Accept: application/vnd.github.raw+json" `
                    | Out-File -FilePath $chunkTmp -Encoding Byte 2>$null

                # PowerShell 5.1 doesn't have -Encoding Byte for Out-File
                # Fall back to reading content as bytes
            }
            catch {
                # Try alternative: download via content field with base64
                try {
                    $response = gh api "repos/$Repo/contents/$chunkRemote" | ConvertFrom-Json
                    $chunkBytes = [Convert]::FromBase64String($response.content)
                    [System.IO.File]::WriteAllBytes($chunkTmp, $chunkBytes)
                }
                catch {
                    Write-Host "  ERROR: Failed to download chunk $c"
                    $downloadFailed = $true
                    break
                }
            }

            $chunkBytes = [System.IO.File]::ReadAllBytes($chunkTmp)
            $outStream.Write($chunkBytes, 0, $chunkBytes.Length)
            Remove-Item $chunkTmp -Force -ErrorAction SilentlyContinue

            Write-Host "  [$($c + 1)/$totalChunks] chunk_$chunkIdx"
        }
    }
    finally {
        $outStream.Close()
    }

    if ($downloadFailed) {
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        $errors++
        continue
    }

    # Verify SHA256
    $actualSha256 = Get-FileSHA256 -Path $tmpPath
    if ($actualSha256 -ne $expectedSha256) {
        Write-Host "  ERROR: SHA256 mismatch!"
        Write-Host "    Expected: $expectedSha256"
        Write-Host "    Actual:   $actualSha256"
        Remove-Item $tmpPath -Force
        $errors++
    }
    else {
        if (Test-Path $outputPath) { Remove-Item $outputPath -Force }
        Move-Item $tmpPath $outputPath
        $actualSize = (Get-Item $outputPath).Length
        Write-Host "  OK: $outputPath ($actualSize bytes, SHA256 verified)"
    }
    Write-Host ""
}

if ($errors -gt 0) {
    Write-Host "COMPLETED WITH $errors ERROR(S)" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "All files downloaded and verified successfully!" -ForegroundColor Green
}
