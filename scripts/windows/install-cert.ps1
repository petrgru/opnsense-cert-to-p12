#!/usr/bin/env pwsh
#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Downloads a .p12 certificate from OPNsense and installs it into the Windows
    Local Machine certificate store.

.DESCRIPTION
    Reads configuration from a .env file, downloads the .p12 and .password files
    from the OPNsense cert-export API, and imports the certificate into
    Cert:\LocalMachine\My (the Personal store for the local machine).

    The script MUST be run as Administrator. On Windows 10/Server 2016+ the
    #Requires -RunAsAdministrator directive enforces this automatically.

.PARAMETER EnvFile
    Path to the .env configuration file. Default: .env in the script directory.

.PARAMETER WhatIf
    Shows what would be done without actually downloading or importing.

.EXAMPLE
    .\install-cert.ps1

.EXAMPLE
    .\install-cert.ps1 -EnvFile C:\Config\opnsense.env -Verbose

.NOTES
    Author:  OPNsense Certificate-to-P12 Exporter project
    Requires: Windows 10 / Windows Server 2016+, PowerShell 5.1+
    Link:     https://github.com/petrgru/opnsense-cert-to-p12
#>

[CmdletBinding(SupportsShouldProcess = $true)]
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
            # PowerShell Core 6+
            $skipParam = @{ SkipCertificateCheck = $true }
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
        Write-Success "Downloaded $Description → $OutFile ($((Get-Item $OutFile).Length) bytes)"
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDesc = $_.Exception.Response.StatusDescription
        if ($statusCode -eq 401) {
            Write-ErrorAndExit "Authentication failed (401). Check API_KEY and API_SECRET in .env."
        } elseif ($statusCode -eq 403) {
            Write-ErrorAndExit "Access denied (403). Verify API_KEY and API_SECRET are correct."
        } elseif ($statusCode -eq 404) {
            Write-ErrorAndExit "Certificate '$certName' not found on server (404). Run cert-to-p12.sh on OPNsense first."
        } else {
            Write-ErrorAndExit "HTTP $statusCode $statusDesc — $Url"
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

# Verify admin
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-ErrorAndExit "This script must be run as Administrator. Right-click PowerShell and select 'Run as Administrator'."
}

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
    if ($PSCmdlet.ShouldProcess($p12Dir, 'Create directory')) {
        New-Item -Path $p12Dir -ItemType Directory -Force | Out-Null
        Write-Success "Created $p12Dir"
    }
} else {
    Write-Success "Output directory $p12Dir exists"
}

# ---------------------------------------------------------------------------
# Download .p12 and .password files
# ---------------------------------------------------------------------------

$p12File       = Join-Path $p12Dir "$certName.p12"
$passwordFile  = Join-Path $p12Dir "$certName.password"
$apiBaseUrl    = "${opnsenseUrl}/cert-export/?cert=$([System.Net.WebUtility]::UrlEncode($certName))"
$p12Url        = $apiBaseUrl
$passwordUrl   = "${apiBaseUrl}&password=1"

$commonParams = @{
    ApiKey       = $apiKey
    ApiSecret    = $apiSecret
    SkipTlsVerify = $skipTlsVerify
}

Write-Step "Downloading .p12 file from OPNsense..."
if ($PSCmdlet.ShouldProcess($p12Url, 'Download .p12')) {
    Invoke-OPNsenseDownload @commonParams -Url $p12Url -OutFile $p12File -Description "$certName.p12"
}

Write-Step "Downloading .password file from OPNsense..."
if ($PSCmdlet.ShouldProcess($passwordUrl, 'Download .password')) {
    Invoke-OPNsenseDownload @commonParams -Url $passwordUrl -OutFile $passwordFile -Description "$certName.password"
}

# ---------------------------------------------------------------------------
# Verify downloaded files
# ---------------------------------------------------------------------------

if (-not (Test-Path $p12File)) {
    Write-ErrorAndExit "Downloaded .p12 file not found at $p12File"
}
if ((Get-Item $p12File).Length -eq 0) {
    Write-ErrorAndExit "Downloaded .p12 file is empty: $p12File"
}
if (-not (Test-Path $passwordFile)) {
    Write-ErrorAndExit "Downloaded .password file not found at $passwordFile"
}

$password = Get-Content $passwordFile -Raw
if (-not $password -or $password.Trim().Length -eq 0) {
    Write-ErrorAndExit "Password file is empty: $passwordFile"
}

Write-Success "Files verified successfully"

# ---------------------------------------------------------------------------
# Import certificate into Windows Local Machine store
# ---------------------------------------------------------------------------

Write-Step "Importing certificate into Local Machine → Personal certificate store..."
if ($PSCmdlet.ShouldProcess("Cert:\LocalMachine\My\$certName", 'Import-PfxCertificate')) {
    try {
        $securePass = ConvertTo-SecureString $password.Trim() -AsPlainText -Force

        # Remove any existing certificate with the same thumbprint first.
        # Import-PfxCertificate with -AcceptAny is available in some versions,
        # but the safest approach is to just import and let it overwrite.
        Import-PfxCertificate -FilePath $p12File `
            -CertStoreLocation Cert:\LocalMachine\My `
            -Password $securePass `
            -Exportable `
            -ErrorAction Stop | Out-Null

        Write-Success "Certificate imported successfully into Cert:\LocalMachine\My"
    } catch {
        Write-ErrorAndExit "Failed to import certificate: $_"
    }
}

# ---------------------------------------------------------------------------
# Verify the import
# ---------------------------------------------------------------------------

Write-Step "Verifying certificate in the store..."
try {
    $thumbprint = (Get-PfxCertificate -FilePath $p12File -ErrorAction Stop).Thumbprint
    $imported = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $thumbprint }
    if ($imported) {
        Write-Success "Certificate verified:"
        Write-Host "         Subject : $($imported.Subject)" -ForegroundColor Gray
        Write-Host "         Thumbprint : $thumbprint" -ForegroundColor Gray
        Write-Host "         Expires : $($imported.NotAfter)" -ForegroundColor Gray
    } else {
        Write-Warn "Certificate was imported but could not be verified in the store (possible timing issue)."
    }
} catch {
    Write-Warn "Could not read thumbprint from .p12 file: $_"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Installation complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Files:"
Write-Host "    .p12       : $p12File"
Write-Host "    .password  : $passwordFile"
Write-Host ""
Write-Host "  Certificate store: Cert:\LocalMachine\My"
Write-Host ""
Write-Host "  To verify manually, run:"
Write-Host "    certlm.msc"
Write-Host "    → Personal → Certificates"
Write-Host ""
Write-Host "  To re-run with a different certificate, update CERT_NAME in .env"
Write-Host "  and run this script again."
Write-Host ""
