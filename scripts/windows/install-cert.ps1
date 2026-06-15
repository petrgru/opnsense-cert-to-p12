#!/usr/bin/env pwsh
#Requires -Version 5.1

<#
.SYNOPSIS
    Downloads a .p12 certificate from OPNsense.

.DESCRIPTION
    Reads configuration from a .env file and downloads the .p12 certificate
    file from the OPNsense cert-export API. Saves it to a local directory.

    No administrator privileges are required for download-only mode.

.PARAMETER EnvFile
    Path to the .env configuration file. Default: .env in the script directory.

.EXAMPLE
    .\install-cert.ps1

.EXAMPLE
    .\install-cert.ps1 -EnvFile C:\Config\opnsense.env -Verbose

.NOTES
    Author:  OPNsense Certificate-to-P12 Exporter project
    Requires: Windows 7 / Windows Server 2012+, PowerShell 5.1+
    Link:     https://github.com/petrgru/opnsense-cert-to-p12
#>

param (
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$EnvFile = (Join-Path -Path $PSScriptRoot -ChildPath '.env')
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ">>> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host " WARN $Message" -ForegroundColor Yellow
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Parse .env file
# ---------------------------------------------------------------------------

function Parse-EnvFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-ErrorAndExit ".env file not found at '$Path'. Copy .env.example to .env and fill in your settings."
    }

    $config = @{}
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        # Skip comments and blank lines
        if ($line -and $line -notmatch '^\s*#') {
            $parts = $line.Split('=', 2)
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $value = $parts[1].Trim()
                # Strip optional surrounding quotes
                $value = $value -replace '^["'']|["'']$', ''
                $config[$key] = $value
            }
        }
    }

    return $config
}

# ---------------------------------------------------------------------------
# Download a file from OPNsense with Basic Auth
# ---------------------------------------------------------------------------

function Invoke-OPNsenseDownload {
    param(
        [string]$Url,
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$OutFile,
        [string]$Description,
        [switch]$SkipTlsVerify
    )

    if ($SkipTlsVerify) {
        Write-Warn "TLS certificate validation is DISABLED."
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            # PowerShell Core 6+ supports -SkipCertificateCheck natively
        } else {
            # Windows PowerShell 5.1 — global callback (not thread-safe)
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ApiKey}:${ApiSecret}"))
    $headers = @{ Authorization = "Basic $authHeader" }

    try {
        $params = @{
            Uri             = $Url
            Method          = 'Get'
            Headers         = $headers
            OutFile         = $OutFile
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params['SkipCertificateCheck'] = $SkipTlsVerify
        } elseif ($SkipTlsVerify) {
            # Fallback already handled above via ServicePointManager
        }

        Invoke-WebRequest @params
        $sizeBytes = (Get-Item $OutFile).Length
        Write-Success "Downloaded $Description -> $OutFile ($sizeBytes bytes)"
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDesc = $_.Exception.Response.StatusDescription
        if ($statusCode -eq 401) {
            Write-ErrorAndExit "Authentication failed (401). Check API_KEY and API_SECRET in .env."
        } elseif ($statusCode -eq 403) {
            Write-ErrorAndExit "Access denied (403). Verify API_KEY and API_SECRET are correct."
        } elseif ($statusCode -eq 404) {
            Write-ErrorAndExit "Certificate not found on server (404). Run cert-to-p12.sh on OPNsense first."
        } else {
            Write-ErrorAndExit "HTTP $statusCode $statusDesc - $Url"
        }
    } finally {
        # Reset TLS callback if we changed it (PS 5.1)
        if ($SkipTlsVerify -and $PSVersionTable.PSVersion.Major -lt 6) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " OPNsense Certificate-to-P12 Windows Installer" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

Write-Step "Loading configuration from $EnvFile"
$config = Parse-EnvFile -Path $EnvFile

$opnsenseUrl   = $config['OPNSENSE_URL']
$apiKey        = $config['API_KEY']
$apiSecret     = $config['API_SECRET']
$certName      = $config['CERT_NAME']
$p12Dir        = if ($config['P12_DIR']) { $config['P12_DIR'] } else { "$env:ProgramData\cert-to-p12" }
$skipTlsVerify = $config['SKIP_TLS_VERIFY'] -eq 'true'

# Validate required fields
$missing = @()
if (-not $opnsenseUrl) { $missing += 'OPNSENSE_URL' }
if (-not $apiKey)      { $missing += 'API_KEY' }
if (-not $apiSecret)   { $missing += 'API_SECRET' }
if (-not $certName)    { $missing += 'CERT_NAME' }

if ($missing.Count -gt 0) {
    Write-ErrorAndExit "Missing required configuration: $($missing -join ', ')"
}

# Normalise URL (strip trailing slash)
$opnsenseUrl = $opnsenseUrl.TrimEnd('/')

Write-Success "OPNSENSE_URL = $opnsenseUrl"
Write-Success "CERT_NAME    = $certName"
Write-Success "P12_DIR      = $p12Dir"
if ($skipTlsVerify) {
    Write-Warn "SKIP_TLS_VERIFY = true (INSECURE)"
}

# ---------------------------------------------------------------------------
# Create output directory
# ---------------------------------------------------------------------------

if (-not (Test-Path $p12Dir)) {
    Write-Step "Creating output directory $p12Dir"
    New-Item -Path $p12Dir -ItemType Directory -Force | Out-Null
    Write-Success "Created $p12Dir"
} else {
    Write-Success "Output directory $p12Dir exists"
}

# ---------------------------------------------------------------------------
# Download .p12 file
# ---------------------------------------------------------------------------

$p12File    = Join-Path $p12Dir "$certName.p12"
$queryCert  = [System.Net.WebUtility]::UrlEncode($certName)
$p12Url     = $opnsenseUrl + "/cert-export/?cert=" + $queryCert

$commonParams = @{
    ApiKey       = $apiKey
    ApiSecret    = $apiSecret
    SkipTlsVerify = $skipTlsVerify
}

Write-Step "Downloading .p12 file from OPNsense..."
Invoke-OPNsenseDownload @commonParams -Url $p12Url -OutFile $p12File -Description "$certName.p12"

# ---------------------------------------------------------------------------
# Verify downloaded file
# ---------------------------------------------------------------------------

if (-not (Test-Path $p12File)) {
    Write-ErrorAndExit "Downloaded .p12 file not found at $p12File"
}
if ((Get-Item $p12File).Length -eq 0) {
    Write-ErrorAndExit "Downloaded .p12 file is empty: $p12File"
}

Write-Success "Download verified: $((Get-Item $p12File).Length) bytes"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Download complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  File : $p12File"
Write-Host ""
Write-Host "  To import into Windows certificate store manually:"
Write-Host "    1. Run certlm.msc"
Write-Host "    2. Go to Personal -> Certificates"
Write-Host "    3. Right-click -> All Tasks -> Import"
Write-Host "    4. Select the .p12 file and enter the password"
Write-Host "       (password file is stored alongside the .p12 on the OPNsense"
Write-Host "       server at /root/cert-export/$certName.password)"
Write-Host ""
Write-Host "  To re-run with a different certificate, update CERT_NAME in .env"
Write-Host "  and run this script again."
Write-Host ""
