<#
.SYNOPSIS
    Installs the RxInfer Julia distribution and registers it with juliaup as the
    channel `rxinfer`.

.DESCRIPTION
    After this runs, `julia +rxinfer` starts a Julia in which `using RxInfer`
    resolves, installs and compiles nothing.

    Re-running this script is how you upgrade: it is idempotent and replaces the
    channel rather than failing on it.

.PARAMETER Version
    Install a specific release tag instead of the latest stable release.

.PARAMETER Weekly
    Install the newest weekly prerelease. For testing, not for a course.

.PARAMETER NoTelemetry
    Also set LOG_USING_RXINFER=false as a persistent user environment variable.

.PARAMETER Channel
    The juliaup channel name to create. Defaults to `rxinfer`.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    iwr -useb https://raw.githubusercontent.com/ReactiveBayes/rxinfer-julia-distribution/main/install.ps1 | iex
#>

[CmdletBinding()]
param(
    [string]$Version = $env:RXINFER_DIST_VERSION,
    [switch]$Weekly,
    [switch]$NoTelemetry,
    [string]$Channel = "rxinfer"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Repository = if ($env:RXINFER_DIST_REPOSITORY) { $env:RXINFER_DIST_REPOSITORY } else { "ReactiveBayes/rxinfer-julia-distribution" }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Blue }
function Write-Note { param([string]$Message) Write-Host "warning: $Message" -ForegroundColor Yellow }

# --- 1. Platform check ------------------------------------------------------
#
# Only x64 Windows is built. Failing loudly beats downloading a tarball that
# cannot run.

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($architecture -ne "X64") {
    throw "Only 64-bit x86 Windows is built (this machine reports '$architecture'). Please open an issue at https://github.com/$Repository/issues if you need another."
}
$platform = "windows-x86_64"
Write-Step "Platform: $platform"

# `tar.exe` ships with Windows 10 1803 and later. Unlike Explorer's zip
# extraction it does not propagate Mark-of-the-Web to the extracted files, which
# is what keeps SmartScreen out of the way.
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    throw "tar.exe was not found. It ships with Windows 10 1803 and later; please update Windows."
}

# --- 2. Ensure juliaup ------------------------------------------------------
#
# juliaup owns the `julia` launcher that makes `julia +rxinfer` work, so it is a
# hard requirement rather than a convenience.

if (-not (Get-Command juliaup -ErrorAction SilentlyContinue)) {
    Write-Step "juliaup not found; installing it"
    $installed = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        # The Microsoft Store package is the route juliaup itself documents first.
        winget install --id 9NJNWW8PVKMN --exact --accept-source-agreements --accept-package-agreements
        $installed = $LASTEXITCODE -eq 0
    }
    if (-not $installed) {
        Write-Step "Falling back to the installer from https://install.julialang.org"
        Invoke-Expression ((Invoke-WebRequest -Uri "https://install.julialang.org" -UseBasicParsing).Content)
    }

    # The installer edits the user PATH, which does not affect this already
    # running process, so pick it up explicitly.
    $juliaupBin = Join-Path $env:USERPROFILE ".juliaup\bin"
    if (Test-Path $juliaupBin) { $env:PATH = "$juliaupBin;$env:PATH" }
    $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "User") + ";" + $env:PATH

    if (-not (Get-Command juliaup -ErrorAction SilentlyContinue)) {
        throw "juliaup was installed but is not on PATH. Open a new PowerShell window and re-run this script."
    }
}
Write-Step "Using juliaup: $((Get-Command juliaup).Source)"

# --- 3. Resolve the release -------------------------------------------------

$api = "https://api.github.com/repos/$Repository/releases"

if ([string]::IsNullOrWhiteSpace($Version)) {
    if ($Weekly) {
        # Weekly builds are prereleases, so /latest never returns one.
        $releases = Invoke-RestMethod -Uri "$api`?per_page=30" -UseBasicParsing
        $weeklyRelease = $releases | Where-Object { $_.tag_name -like "weekly-*" } | Select-Object -First 1
        if (-not $weeklyRelease) { throw "No weekly prerelease found in $Repository." }
        $Version = $weeklyRelease.tag_name
    }
    else {
        try {
            $Version = (Invoke-RestMethod -Uri "$api/latest" -UseBasicParsing).tag_name
        }
        catch {
            throw "No stable release found in $Repository. Pass -Weekly to install a weekly build."
        }
    }
}
Write-Step "Release: $Version"

$stem = "rxinfer-$($Version -replace '^v', '')-$platform"
$tarball = "$stem.tar.gz"
$baseUrl = "https://github.com/$Repository/releases/download/$Version"

# --- 4. Download and verify -------------------------------------------------

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("rxinfer-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

try {
    $tarballPath = Join-Path $workDirectory $tarball

    Write-Step "Downloading $tarball (this is a few hundred MB)"
    try {
        Invoke-WebRequest -Uri "$baseUrl/$tarball" -OutFile $tarballPath -UseBasicParsing
    }
    catch {
        throw "Download failed. Does $Version include a build for $platform`? See https://github.com/$Repository/releases"
    }

    Write-Step "Verifying the checksum"
    $checksumPath = "$tarballPath.sha256"
    try {
        Invoke-WebRequest -Uri "$baseUrl/$tarball.sha256" -OutFile $checksumPath -UseBasicParsing
        $expected = ((Get-Content $checksumPath -Raw).Trim() -split '\s+')[0]
        $actual = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
        if ($expected -ne $actual) {
            throw "Checksum mismatch: expected $expected, got $actual. Refusing to install."
        }
        Write-Step "Checksum ok"
    }
    catch [System.Net.WebException] {
        Write-Note "No published checksum for $tarball; installing without verification."
    }

    # --- 5. Extract ---------------------------------------------------------

    $depot = if ($env:JULIA_DEPOT_PATH) { ($env:JULIA_DEPOT_PATH -split ';')[0] } else { Join-Path $env:USERPROFILE ".julia" }
    $installPath = Join-Path (Join-Path $depot "rxinfer-distributions") $Version

    if (Test-Path $installPath) {
        Write-Step "Replacing the existing installation at $installPath"
        Remove-Item -Recurse -Force $installPath
    }
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null

    # A distribution tree is deep. Long-path support has been the default since
    # Windows 10 1607, but a machine with it disabled fails here rather than
    # halfway through a student's first lecture.
    if ($installPath.Length -gt 120) {
        Write-Note "The install path is long ($($installPath.Length) characters). If extraction fails with a path error, enable Win32 long paths (Group Policy: 'Enable Win32 long paths')."
    }

    Write-Step "Extracting into $installPath"
    tar -xzf $tarballPath -C $installPath
    if ($LASTEXITCODE -ne 0) { throw "Extraction failed (tar exit code $LASTEXITCODE)." }

    $juliaBinary = Join-Path $installPath "$stem\bin\julia.exe"
    if (-not (Test-Path $juliaBinary)) { throw "The extracted tree has no executable at $juliaBinary." }

    # --- 6. Register the juliaup channel ------------------------------------
    #
    # `juliaup link` refuses a channel name that is already in use, so removing
    # first is what makes re-running this script an upgrade rather than an error.

    if ((juliaup status) -match "\s$([regex]::Escape($Channel))\s") {
        Write-Step "Removing the previous '$Channel' channel"
        juliaup remove $Channel 2>$null | Out-Null
    }

    Write-Step "Linking channel '$Channel'"
    juliaup link $Channel $juliaBinary
    if ($LASTEXITCODE -ne 0) { throw "juliaup link failed (exit code $LASTEXITCODE)." }

    # --- 7. Optional telemetry opt-out --------------------------------------
    #
    # RxInfer's telemetry preferences are compiled into this distribution's
    # system image, so `RxInfer.disable_rxinfer_using_telemetry!()` cannot take
    # effect here. The environment variable is the only opt-out that works.

    if ($NoTelemetry) {
        [Environment]::SetEnvironmentVariable("LOG_USING_RXINFER", "false", "User")
        Write-Step "Set LOG_USING_RXINFER=false for your user account (takes effect in a new terminal)"
    }

    # --- 8. Verify ----------------------------------------------------------

    Write-Step "Verifying the installation"
    & julia "+$Channel" --startup-file=no -e 'using RxInfer; println("RxInfer ", pkgversion(RxInfer), " on Julia ", VERSION, " -- ready")'
    if ($LASTEXITCODE -ne 0) { throw "The installed distribution failed to run." }

    Write-Host @"

Done. Start it with:

    julia +$Channel

Optionally make it your default Julia (this affects a plain ``julia`` too):

    juliaup default $Channel

Installed at: $installPath
Uninstall:    juliaup remove $Channel; Remove-Item -Recurse -Force "$installPath"

This distribution sends one anonymous event per ``using RxInfer``. Because the
setting is compiled into the system image, the only way to opt out is the
environment variable LOG_USING_RXINFER=false -- see the README section
"Telemetry" at https://github.com/$Repository#telemetry
"@
}
finally {
    Remove-Item -Recurse -Force $workDirectory -ErrorAction SilentlyContinue
}
