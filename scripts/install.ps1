#Requires -Version 5.1

<#
.SYNOPSIS
    Native Windows installer for Nerd Fonts (parallel to scripts/install.sh).

.DESCRIPTION
    Installs, inspects and uninstalls Nerd Fonts on Windows through multiple
    backends: scoop, winget, Chocolatey (choco) or direct downloads from the
    official ryanoasis/nerd-fonts GitHub releases.

    Canonical font ids are shared with the bash installer: the GitHub release
    asset basename, lowercased (e.g. JetBrainsMono.zip -> jetbrainsmono).

    Exit codes (identical to the bash installer):
      0  Success.
      1  Invalid argument, usage or validation error.
      2  Missing dependency or manifest fetch failure.
      3  No Nerd Fonts found or available for the requested operation.
      4  Partial failure: some fonts failed to install or uninstall.

    Backend "auto" picks the first available manager with a non-empty Nerd
    Fonts catalog, in this order: scoop -> winget -> choco -> direct.

.PARAMETER All
    Install every available Nerd Font (non-interactive).

.PARAMETER Fonts
    Comma-separated list of canonical font ids to install, e.g. "firacode,hack".
    Spaces after commas are tolerated; unknown ids produce a warning and are
    skipped. When combined with -Uninstall, this list selects the fonts to
    REMOVE instead of install.

.PARAMETER List
    Print the available Nerd Font ids (one per line, plain stdout) and exit.

.PARAMETER Installed
    Print the installed Nerd Font ids (one per line, plain stdout) and exit.

.PARAMETER Uninstall
    Uninstall fonts. Selection sources, in order of precedence:
      -UninstallAll           remove every installed Nerd Font;
      -Uninstall -Fonts "a,b" remove the named fonts;
      -Uninstall (alone)      open an interactive console selector over the
                              installed fonts.

.PARAMETER UninstallAll
    Remove every installed Nerd Font. Implies -Uninstall.

.PARAMETER Backend
    Installation backend: auto (default), scoop, winget, choco or direct.
    An explicit backend is always honored, even when its tool is missing
    (a warning explains the situation and the catalog will likely be empty).

.PARAMETER DryRun
    Print what would be done without touching the system.

.PARAMETER Quiet
    Suppress step/success/warning messages (errors are still printed).

.PARAMETER NoColor
    Disable colored output. The NO_COLOR environment variable is honored too.

.PARAMETER Version
    Print version information and exit.

.PARAMETER Help
    Show the usage summary (a condensed form of Get-Help) and exit.

.EXAMPLE
    pwsh -File scripts\install.ps1 -List

.EXAMPLE
    pwsh -File scripts\install.ps1 -Fonts "firacode,jetbrainsmono"

.EXAMPLE
    pwsh -File scripts\install.ps1 -Backend direct -Fonts hack -DryRun

.EXAMPLE
    pwsh -File scripts\install.ps1 -Uninstall -Fonts firacode

.EXAMPLE
    pwsh -File scripts\install.ps1 -UninstallAll

.NOTES
    Environment variables:
      GITHUB_TOKEN               GitHub API token (direct backend; avoids 403s).
      DIRECT_CACHE_TTL_HOURS     Manifest cache TTL in hours (default: 24).
      DIRECT_NO_CACHE=1          Bypass the direct-backend manifest cache.
      NF_DEBUG_BACKEND=1         Print backend resolution debug info (stderr).
      NO_COLOR                   Disable colored output when non-empty.
      QUIET=1                    Same as -Quiet.
      INSTALLER_VERSION          Override the reported version string.

    Testing hook (hidden): NF_TEST_MANIFEST_FILE makes the direct backend read
    a local manifest.cache-format file instead of contacting the GitHub API.
    Used by the repository test suites and for offline smoke tests.

    Design decisions (paralleling the bash installer):
      - Downloads are SEQUENTIAL on Windows. Start-Job/runspace parallelism
        costs more than it saves for this workload and keeps PS 5.1 support
        simple and predictable.
      - Direct installs copy *.ttf/*.otf into
        "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" and register each file
        under HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts with
        value name "<InternalName> (TrueType)" and the full file path as data.
        InternalName comes from the font file itself (System.Drawing
        PrivateFontCollection); when unavailable (or off-Windows) the base
        file name is used instead.
      - Duplicate family names across weights are disambiguated with numeric
        suffixes in the registry value name.
      - Success markers live in "%LOCALAPPDATA%\nerdfonts-installer\installed\<id>"
        and the manifest cache reuses the bash format (#META|epoch|tag + URLs),
        so fixtures stay portable between platforms.
#>

[CmdletBinding()]
param(
    [switch]$All,
    [string]$Fonts,
    [switch]$List,
    [switch]$Installed,
    [switch]$Uninstall,
    [switch]$UninstallAll,
    [string]$Backend,
    [switch]$DryRun,
    [switch]$Quiet,
    [switch]$NoColor,
    [switch]$Version,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class NfUsageException : System.Exception {
    NfUsageException([string]$message) : base($message) { }
}

###############################################################################
# Region: Constants and script state
###############################################################################

$script:NFVersion = 'dev'
if ($env:INSTALLER_VERSION) { $script:NFVersion = $env:INSTALLER_VERSION }

$script:GitHubRepo = 'ryanoasis/nerd-fonts'
$script:GitHubReleaseApi = "https://api.github.com/repos/$($script:GitHubRepo)/releases/latest"

# Resolved lazily by Get-NfCacheRoot ($env:LOCALAPPDATA is always present on
# real Windows; the fallbacks only serve off-Windows test hosts).
$script:CacheRoot = $null

# Candidate order for auto resolution (first with a non-empty catalog wins);
# "direct" is the implicit final fallback.
$script:BackendAutoOrder = @('scoop', 'winget', 'choco')

# Glyphs aligned with the bash installer style (scripts/lib/log.sh).
$script:GlyphStep = [char]0x279C      # arrow
$script:GlyphSuccess = [char]0x2705   # check mark
$script:GlyphWarn = [char]0x26A0      # warning sign
$script:GlyphError = [char]0x2757     # exclamation mark

$script:OptAll = [bool]$All
$script:OptFonts = ''
$script:FontsWasBound = $PSBoundParameters.ContainsKey('Fonts')
if ($script:FontsWasBound) { $script:OptFonts = $Fonts }
$script:OptList = [bool]$List
$script:OptInstalled = [bool]$Installed
$script:OptUninstall = [bool]$Uninstall
$script:OptUninstallAll = [bool]$UninstallAll
$script:IsUninstallAction = ([bool]$Uninstall -or [bool]$UninstallAll)
$script:OptDryRun = [bool]$DryRun
$script:OptQuiet = ([bool]$Quiet -or $env:QUIET -eq '1')
$script:OptNoColor = [bool]$NoColor
if ($env:NO_COLOR) { $script:OptNoColor = $true }

$script:OptBackend = 'auto'
if ($Backend) { $script:OptBackend = $Backend.Trim().ToLowerInvariant() }
$script:OptVersion = [bool]$Version
$script:OptHelp = [bool]$Help

$script:ColorsEnabled = (-not $script:OptNoColor)

# True only on real Windows (guards registry/System.Drawing usage in tests).
$script:IsWindowsHost = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)

# Resolved backend and per-run caches (mirrors the bash globals).
$script:ResolvedBackend = ''
$script:CachedFontList = @()
$script:CachedFontListBackend = ''
$script:CatalogLoaded = $false
$script:CachedInstalledList = @()
$script:InstalledLoaded = $false
$script:FailedFonts = New-Object System.Collections.Generic.List[string]

# Backend id maps: canonical id -> native package/asset identifier.
$script:ScoopFontMap = @{}
$script:ScoopRanks = @{}
$script:WingetFontMap = @{}
$script:ChocoFontMap = @{}
$script:DirectFontMap = @{}
$script:DirectTag = ''

# Native installed-list caches (queried at most once per run).
$script:ScoopInstalledPackages = $null
$script:WingetInstalledIds = $null

###############################################################################
# Region: Pure helpers
###############################################################################

function Test-NfCommand {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function ConvertTo-NfLowercase {
    param([string]$Value)
    return $Value.ToLowerInvariant()
}

function Get-NfCanonicalIdsFromCsv {
    param([string]$Csv)
    $result = @()
    if ([string]::IsNullOrWhiteSpace($Csv)) { return $result }
    foreach ($entry in $Csv.Split(',')) {
        $trimmed = $entry.Trim()
        if ($trimmed) { $result += $trimmed }
    }
    return $result
}

function Test-NfListContains {
    param([string[]]$List, [string]$Value)
    foreach ($item in $List) {
        if ($item -eq $Value) { return $true }
    }
    return $false
}

###############################################################################
# Region: Logging and exit helpers (mirrors scripts/lib/log.sh)
###############################################################################

function Write-NfColored {
    param([string]$Glyph, [string]$Message, [ConsoleColor]$Color)
    $line = "$Glyph  $Message"
    if ($script:ColorsEnabled) {
        Write-Host $line -ForegroundColor $Color
    }
    else {
        Write-Host $line
    }
}

function Write-NfStep {
    param([string]$Message)
    if ($script:OptQuiet) { return }
    Write-Host ''
    Write-NfColored -Glyph $script:GlyphStep -Message $Message -Color Cyan
    Write-Host ''
}

function Write-NfSuccess {
    param([string]$Message)
    if ($script:OptQuiet) { return }
    Write-Host ''
    Write-NfColored -Glyph $script:GlyphSuccess -Message $Message -Color Green
    Write-Host ''
}

function Write-NfWarn {
    param([string]$Message)
    if ($script:OptQuiet) { return }
    Write-NfColored -Glyph $script:GlyphWarn -Message $Message -Color Yellow
}

# Errors always print, go to stderr (like bash die) and carry no color,
# because many Windows consoles ignore ANSI colors on the error stream.
function Write-NfError {
    param([string]$Message)
    [Console]::Error.WriteLine("$($script:GlyphError)  $Message")
}

function Write-NfDebug {
    param([string]$Message)
    if ($env:NF_DEBUG_BACKEND -eq '1') {
        [Console]::Error.WriteLine("[debug] $Message")
    }
}

function Show-NfPlain {
    param([string]$Message)
    Write-Host $Message
}

###############################################################################
# Region: CLI validation (mirrors scripts/lib/cli.sh)
###############################################################################

function Assert-NfValidOptions {
    $validBackends = @('auto', 'scoop', 'winget', 'choco', 'direct')
    if ($validBackends -notcontains $script:OptBackend) {
        throw [NfUsageException]("Invalid backend '{0}'. Valid backends: auto, scoop, winget, choco, direct." -f $script:OptBackend)
    }

    if ($script:FontsWasBound -and [string]::IsNullOrWhiteSpace($script:OptFonts)) {
        throw [NfUsageException]'Option -Fonts requires a non-empty value.'
    }

    if ($script:OptList) {
        if ($script:OptAll -or $script:FontsWasBound -or $script:OptInstalled -or $script:IsUninstallAction -or $script:OptDryRun) {
            throw [NfUsageException]'Option -List cannot be combined with other actions.'
        }
    }

    if ($script:OptInstalled) {
        if ($script:OptAll -or $script:FontsWasBound -or $script:IsUninstallAction -or $script:OptDryRun) {
            throw [NfUsageException]'Option -Installed cannot be combined with other actions.'
        }
    }

    if ($script:OptAll -and $script:FontsWasBound) {
        throw [NfUsageException]'Options -All and -Fonts cannot be combined.'
    }

    if ($script:IsUninstallAction -and $script:OptAll) {
        throw [NfUsageException]'Option -Uninstall cannot be combined with -All.'
    }
}

###############################################################################
# Region: Native command invocation helper
###############################################################################

# Invoke-NfNative runs a native executable and captures its merged output.
# ErrorActionPreference is relaxed around the call because redirecting native
# stderr under -ErrorActionPreference Stop converts stderr lines into
# terminating ErrorRecords on Windows PowerShell 5.1.
function Invoke-NfNative {
    param([string]$FilePath, [string[]]$ArgumentList = @())
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $lines = @()
    foreach ($item in @($raw)) { $lines += ("$item") }
    return [pscustomobject]@{ Output = $lines; ExitCode = $code }
}

###############################################################################
# Region: Backend resolution (mirrors scripts/lib/platform.sh)
###############################################################################

function Test-NfBackendToolAvailable {
    param([string]$Name)
    switch ($Name) {
        'scoop' { return (Test-NfCommand 'scoop') }
        'winget' { return (Test-NfCommand 'winget') }
        'choco' { return (Test-NfCommand 'choco') }
        'direct' { return $true } # Invoke-RestMethod + Expand-Archive ship with PowerShell itself.
        default { return $false }
    }
}

function Get-NfBackendFontCatalog {
    param([string]$Name)
    switch ($Name) {
        'scoop' { return Get-NfScoopFonts }
        'winget' { return Get-NfWingetFonts }
        'choco' { return Get-NfChocoFonts }
        'direct' { return Get-NfDirectFonts }
        default { return @() }
    }
}

function Set-NfCatalogCache {
    param([string]$Name, [string[]]$List)
    $script:CachedFontList = @($List)
    $script:CachedFontListBackend = $Name
    $script:CatalogLoaded = $true
}

# Probe-NfBackendCatalog tolerates any failure (broken tools, network errors):
# a failing probe simply reports an empty catalog, like the bash subshell probe.
function Probe-NfBackendCatalog {
    param([string]$Name)
    $list = @()
    try {
        $list = Get-NfBackendFontCatalog $Name
    }
    catch {
        Write-NfDebug "probe of '${Name}' failed: $($_.Exception.Message)"
        $list = @()
    }
    Set-NfCatalogCache -Name $Name -List $list
    return $script:CachedFontList
}

function Resolve-NfBackend {
    param([string]$Requested)

    if ($Requested -ne 'auto') {
        $script:ResolvedBackend = $Requested
        if ($Requested -ne 'direct') {
            if (-not (Test-NfBackendToolAvailable $Requested)) {
                Write-NfWarn "Backend '${Requested}' is not available on this system. Using it anyway: its catalog will likely be empty."
            }
            else {
                $probed = Probe-NfBackendCatalog -Name $Requested
                if (@($probed).Count -eq 0) {
                    Write-NfWarn "Backend '${Requested}' reported no Nerd Fonts packages. Proceeding with an empty catalog."
                }
            }
        }
        Write-NfDebug "backend=$($script:ResolvedBackend)"
        return
    }

    foreach ($candidate in $script:BackendAutoOrder) {
        if (-not (Test-NfBackendToolAvailable $candidate)) { continue }
        Write-NfDebug "probing candidate=${candidate}"
        $probed = Probe-NfBackendCatalog -Name $candidate
        if (@($probed).Count -gt 0) {
            $script:ResolvedBackend = $candidate
            Write-NfDebug "backend=$($script:ResolvedBackend)"
            return
        }
    }

    # No package manager had fonts: fall back to the official release downloads.
    if (Test-NfBackendToolAvailable 'direct') {
        $script:ResolvedBackend = 'direct'
        $script:CachedFontList = @()
        $script:CachedFontListBackend = ''
        $script:CatalogLoaded = $false
        Write-NfDebug "backend=$($script:ResolvedBackend)"
        return
    }

    Exit-Nf 2 'No supported installation backend found. Install one of: scoop, winget, chocolatey; direct downloads require nothing extra.'
}

###############################################################################
# Region: Scoop backend
###############################################################################

function Get-NfScoopRoot {
    if ($env:SCOOP -and (Test-Path $env:SCOOP)) { return $env:SCOOP }
    $cmd = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) {
        $shimsDir = Split-Path -Path $cmd.Source -Parent
        $root = Split-Path -Path $shimsDir -Parent
        if ($root -and (Test-Path (Join-Path $root 'buckets'))) { return $root }
    }
    if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE 'scoop') }
    return 'scoop'
}

function Get-NfScoopBucketDir {
    return Join-Path (Get-NfScoopRoot) (Join-Path 'buckets' (Join-Path 'nerd-fonts' 'bucket'))
}

# Ensure-NfScoopBucket adds the nerd-fonts bucket when this backend was chosen
# but the bucket directory is missing (i.e. `scoop bucket list` lacks it).
function Ensure-NfScoopBucket {
    if (Test-Path (Get-NfScoopBucketDir)) { return $true }
    Write-NfWarn "scoop bucket 'nerd-fonts' is missing. Trying 'scoop bucket add nerd-fonts'..."
    $result = Invoke-NfNative -FilePath 'scoop' -ArgumentList @('bucket', 'add', 'nerd-fonts')
    if ($result.ExitCode -ne 0) {
        Write-NfWarn "Could not add the 'nerd-fonts' bucket automatically. Run it manually, or fall back to -Backend direct."
        return $false
    }
    return (Test-Path (Get-NfScoopBucketDir))
}

# Get-NfScoopPackageId derives a canonical id from a bucket manifest file name:
# strip the -nerd-font-mono / -nf-mono / -nerd-font / -nf suffixes (longest
# first), then drop remaining hyphens (JetBrainsMono-NF -> jetbrainsmono).
function Get-NfScoopPackageId {
    param([string]$PackageName)
    $id = $PackageName.ToLowerInvariant()
    foreach ($suffix in @('-nerd-font-mono', '-nf-mono', '-nerd-font', '-nf')) {
        if ($id.EndsWith($suffix)) {
            $id = $id.Substring(0, $id.Length - $suffix.Length)
            break
        }
    }
    return ($id.Replace('-', ''))
}

function Test-NfIsNerfFontScoopPackage {
    param([string]$PackageName)
    $lower = $PackageName.ToLowerInvariant()
    foreach ($suffix in @('-nerd-font-mono', '-nf-mono', '-nerd-font', '-nf')) {
        if ($lower.EndsWith($suffix)) { return $true }
    }
    return $false
}

# Mono variants (-NF-Mono) collide with their plain counterparts: rank 1 loses
# against rank 0 so the plain package owns the canonical id.
function Get-NfScoopPackageRank {
    param([string]$PackageName)
    $lower = $PackageName.ToLowerInvariant()
    if ($lower.EndsWith('-nf-mono') -or $lower.EndsWith('-nerd-font-mono')) { return 1 }
    return 0
}

function Get-NfScoopFonts {
    $script:ScoopFontMap = @{}
    $script:ScoopRanks = @{}

    if (-not (Ensure-NfScoopBucket)) { return @() }

    $bucketDir = Get-NfScoopBucketDir
    $manifests = @(Get-ChildItem -Path $bucketDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name)
    if ($manifests.Count -eq 0) { return @() }

    foreach ($manifest in $manifests) {
        $packageName = [IO.Path]::GetFileNameWithoutExtension($manifest.Name)
        $id = Get-NfScoopPackageId -PackageName $packageName
        if (-not $id) { continue }
        $rank = Get-NfScoopPackageRank -PackageName $packageName
        if ($script:ScoopFontMap.ContainsKey($id)) {
            if ($rank -ge $script:ScoopRanks[$id]) { continue }
        }
        $script:ScoopFontMap[$id] = $packageName
        $script:ScoopRanks[$id] = $rank
    }

    return @($script:ScoopFontMap.Keys | Sort-Object)
}

function Get-NfScoopPackageForId {
    param([string]$Id)
    if ($script:ScoopFontMap.ContainsKey($Id)) { return $script:ScoopFontMap[$Id] }
    # Fallback to conventional bucket naming before giving up.
    foreach ($candidate in @("${Id}-nf", "${Id}-nerd-font")) {
        $path = Join-Path (Get-NfScoopBucketDir) ($candidate + '.json')
        if (Test-Path $path) { return $candidate }
    }
    return $null
}

function Get-NfScoopInstalledPackages {
    if ($null -ne $script:ScoopInstalledPackages) { return $script:ScoopInstalledPackages }
    $names = @()
    $result = Invoke-NfNative -FilePath 'scoop' -ArgumentList @('list')
    foreach ($line in $result.Output) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('Name') -or $trimmed.StartsWith('---')) { continue }
        $firstToken = ($trimmed -split '\s+')[0]
        if ($firstToken -and $firstToken -ne 'Name') { $names += $firstToken }
    }
    $script:ScoopInstalledPackages = $names
    return $names
}

function Get-NfScoopInstalledPackagesMapped {
    $ids = @()
    foreach ($package in (Get-NfScoopInstalledPackages)) {
        if (-not (Test-NfIsNerfFontScoopPackage -PackageName $package)) { continue }
        $id = Get-NfScoopPackageId -PackageName $package
        if ($id) { $ids += $id }
    }
    return @($ids | Sort-Object -Unique)
}

function Test-NfScoopFontInstalled {
    param([string]$Id)
    $package = Get-NfScoopPackageForId -Id $Id
    if (-not $package) { return $false }
    $installed = Get-NfScoopInstalledPackages
    return (Test-NfListContains -List $installed -Value $package)
}

function Invoke-NfScoopInstall {
    param([string[]]$Ids)
    $packages = @()
    foreach ($id in $Ids) {
        $package = Get-NfScoopPackageForId -Id $id
        if ($package) { $packages += $package }
        else {
            Write-NfWarn "No scoop package maps the canonical id '${id}' (the 'nerd-fonts' bucket is required). Marking as failed."
            $script:FailedFonts.Add($id)
        }
    }
    if ($packages.Count -eq 0) { return }

    Show-NfPlain ("Installing " + ($packages -join ' ') + "...")
    $result = Invoke-NfNative -FilePath 'scoop' -ArgumentList (@('install') + $packages)
    if ($result.ExitCode -eq 0) {
        foreach ($package in $packages) { Write-NfSuccess "Successfully installed ${package}." }
        return
    }

    # Batch failed: retry one by one to pinpoint the failures (mirrors brew).
    foreach ($package in $packages) {
        Show-NfPlain "Installing ${package}..."
        $single = Invoke-NfNative -FilePath 'scoop' -ArgumentList @('install', $package)
        if ($single.ExitCode -eq 0) {
            Write-NfSuccess "Successfully installed ${package}."
        }
        else {
            Write-NfWarn "Failed to install ${package}."
            $script:FailedFonts.Add((Get-NfScoopPackageId -PackageName $package))
        }
    }
}

function Invoke-NfScoopUninstall {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
        $package = Get-NfScoopPackageForId -Id $id
        if (-not $package) {
            Write-NfWarn "No scoop package maps the canonical id '${id}'. Marking as failed."
            $script:FailedFonts.Add($id)
            continue
        }
        Show-NfPlain "Uninstalling ${package}..."
        $result = Invoke-NfNative -FilePath 'scoop' -ArgumentList @('uninstall', $package)
        if ($result.ExitCode -eq 0) {
            Write-NfSuccess "Successfully uninstalled ${package}."
        }
        else {
            Write-NfWarn "Failed to uninstall ${package}."
            $script:FailedFonts.Add($id)
        }
    }
}

function Show-NfScoopDryRunInstall {
    param([string]$Id)
    $package = Get-NfScoopPackageForId -Id $Id
    if ($package) {
        Write-Output "[dry-run] Would install ${package}."
    }
    else {
        Write-Output "[dry-run] Would install ${Id}-nf (assumed bucket name)."
    }
}

function Show-NfScoopDryRunUninstall {
    param([string]$Id)
    $package = Get-NfScoopPackageForId -Id $Id
    if ($package) {
        Write-Output "[dry-run] Would uninstall ${package}."
    }
    else {
        Write-Output "[dry-run] Would uninstall ${Id}-nf (assumed bucket name)."
    }
}

###############################################################################
# Region: winget backend (best-effort coverage, see notes)
###############################################################################

# winget has PARTIAL Nerd Fonts coverage and its tabular output is fragile;
# this backend is therefore explicitly best-effort. Packages are mapped by
# name heuristics; unmapped requested ids produce a warning and a failure.
function Get-NfIdFromWingetEntry {
    param([string]$DisplayName)
    $value = $DisplayName.ToLowerInvariant()
    $value = $value -replace '\([^)]*\)', ' '
    $value = $value -replace 'nerd[- ]?fonts?', ' '
    $value = $value -replace '\bnf\b', ' '
    $value = $value -replace '[^a-z0-9]+', ''
    return $value
}

function Get-NfWingetFonts {
    $script:WingetFontMap = @{}

    $arguments = @('search', 'Nerd Font', '--accept-source-agreements')
    $result = Invoke-NfNative -FilePath 'winget' -ArgumentList $arguments
    if ($result.ExitCode -ne 0) {
        # Older winget builds reject the agreement flag on searches; retry bare.
        $result = Invoke-NfNative -FilePath 'winget' -ArgumentList @('search', 'Nerd Font')
    }
    if ($result.ExitCode -ne 0) { return @() }

    foreach ($line in $result.Output) {
        if ($line -match '^-{3,}') { continue }
        if ($line -match '[\u2500-\u257F]') { continue } # box-drawing table borders
        $columns = @($line -split '\s{2,}' | Where-Object { $_ -ne '' })
        if ($columns.Count -lt 2) { continue }
        $displayName = $columns[0].Trim()
        $packageId = $columns[1].Trim()
        if ($displayName -eq 'Name' -or $packageId -eq 'Id') { continue }
        if ($packageId -notmatch '^[A-Za-z0-9._\-]+$') { continue }
        $joined = "$displayName $packageId"
        if ($joined -notmatch '(?i)nerd.?font' -and $joined -notmatch '(?i)\bnf\b') { continue }

        $id = Get-NfIdFromWingetEntry -DisplayName $displayName
        if (-not $id -or $id.Length -lt 3) { continue }
        if (-not $script:WingetFontMap.ContainsKey($id)) {
            $script:WingetFontMap[$id] = $packageId
        }
    }

    return @($script:WingetFontMap.Keys | Sort-Object)
}

function Get-NfWingetPackageForId {
    param([string]$Id)
    if ($script:WingetFontMap.ContainsKey($Id)) { return $script:WingetFontMap[$Id] }
    return $null
}

function Get-NfWingetInstalledIds {
    if ($null -ne $script:WingetInstalledIds) { return $script:WingetInstalledIds }
    $ids = @()
    $result = Invoke-NfNative -FilePath 'winget' -ArgumentList @('list', '--accept-source-agreements')
    if ($result.ExitCode -ne 0) {
        $result = Invoke-NfNative -FilePath 'winget' -ArgumentList @('list')
    }
    foreach ($line in $result.Output) {
        if ($line -match '^-{3,}' -or $line -match '[\u2500-\u257F]') { continue }
        $columns = @($line -split '\s{2,}' | Where-Object { $_ -ne '' })
        if ($columns.Count -lt 2) { continue }
        if ($columns[0].Trim() -eq 'Name') { continue }
        $candidate = $columns[1].Trim()
        if ($candidate -and $candidate -notmatch '\s') { $ids += $candidate }
    }
    $script:WingetInstalledIds = $ids
    return $ids
}

function Get-NfWingetInstalledFonts {
    # The id map doubles as translator for installed entries: build it lazily
    # when this action runs without a prior catalog load (e.g. -Installed).
    if ($script:WingetFontMap.Count -eq 0) { Get-NfWingetFonts | Out-Null }

    $ids = @()
    foreach ($package in (Get-NfWingetInstalledIds)) {
        foreach ($mapEntry in $script:WingetFontMap.GetEnumerator()) {
            if ($mapEntry.Value -ieq $package) { $ids += $mapEntry.Key }
        }
    }
    return @($ids | Sort-Object -Unique)
}

function Test-NfWingetFontInstalled {
    param([string]$Id)
    $package = Get-NfWingetPackageForId -Id $Id
    if (-not $package) { return $false }
    $installed = Get-NfWingetInstalledIds
    foreach ($entry in $installed) {
        if ($entry -ieq $package) { return $true }
    }
    return $false
}

function Invoke-NfWingetInstall {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
        $package = Get-NfWingetPackageForId -Id $id
        if (-not $package) {
            Write-NfWarn "No winget package maps the canonical id '${id}' (winget has partial Nerd Fonts coverage). Marking as failed."
            $script:FailedFonts.Add($id)
            continue
        }
        Show-NfPlain "Installing ${package}..."
        $result = Invoke-NfNative -FilePath 'winget' -ArgumentList @(
            'install', '--exact', '--id', $package, '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        if ($result.ExitCode -eq 0) {
            Write-NfSuccess "Successfully installed ${package}."
        }
        else {
            Write-NfWarn "Failed to install ${package}."
            $script:FailedFonts.Add($id)
        }
    }
}

function Invoke-NfWingetUninstall {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
        $package = Get-NfWingetPackageForId -Id $id
        if (-not $package) {
            Write-NfWarn "No winget package maps the canonical id '${id}'. Marking as failed."
            $script:FailedFonts.Add($id)
            continue
        }
        Show-NfPlain "Uninstalling ${package}..."
        $result = Invoke-NfNative -FilePath 'winget' -ArgumentList @('uninstall', '--exact', '--id', $package, '--silent')
        if ($result.ExitCode -eq 0) {
            Write-NfSuccess "Successfully uninstalled ${package}."
        }
        else {
            Write-NfWarn "Failed to uninstall ${package}."
            $script:FailedFonts.Add($id)
        }
    }
}

function Show-NfWingetDryRunInstall {
    param([string]$Id)
    $package = Get-NfWingetPackageForId -Id $Id
    if ($package) {
        Write-Output "[dry-run] Would install ${package} (winget --id --exact)."
    }
    else {
        Write-Output "[dry-run] Would install '${Id}' via winget, but no mapping was found (coverage is partial)."
    }
}

function Show-NfWingetDryRunUninstall {
    param([string]$Id)
    $package = Get-NfWingetPackageForId -Id $Id
    if ($package) {
        Write-Output "[dry-run] Would uninstall ${package} (winget --id --exact)."
    }
    else {
        Write-Output "[dry-run] Would uninstall '${Id}' via winget, but no mapping was found (coverage is partial)."
    }
}

###############################################################################
# Region: Chocolatey backend (best-effort coverage, see notes)
###############################################################################

# Chocolatey community packages are named nerd-fonts-<name>; coverage is
# partial and machine-scope installs usually require an elevated shell.
# `choco list` is local in both choco v1 and v2, so no version sniffing is
# required to inspect installed packages.
function Get-NfIdFromChocoPackage {
    param([string]$PackageName)
    $id = $PackageName.ToLowerInvariant()
    if ($id.StartsWith('nerd-fonts-')) {
        $id = $id.Substring('nerd-fonts-'.Length)
    }
    if ($id.EndsWith('-nerd-font')) {
        $id = $id.Substring(0, $id.Length - '-nerd-font'.Length)
    }
    return ($id.TrimEnd('-').Replace('-', ''))
}

function Get-NfChocoFonts {
    $script:ChocoFontMap = @{}

    $result = Invoke-NfNative -FilePath 'choco' -ArgumentList @('search', 'nerd-fonts', '--limit-output')
    if ($result.ExitCode -ne 0) { return @() }

    foreach ($line in $result.Output) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $parts = $trimmed.Split('|')
        $packageName = $parts[0].Trim()
        if ($packageName -notlike 'nerd-fonts-*') { continue }
        $id = Get-NfIdFromChocoPackage -PackageName $packageName
        if (-not $id) { continue }
        if (-not $script:ChocoFontMap.ContainsKey($id)) {
            $script:ChocoFontMap[$id] = $packageName
        }
    }

    return @($script:ChocoFontMap.Keys | Sort-Object)
}

function Get-NfChocoPackageForId {
    param([string]$Id)
    if ($script:ChocoFontMap.ContainsKey($Id)) { return $script:ChocoFontMap[$Id] }
    return ('nerd-fonts-' + $Id)
}

function Get-NfChocoLocalPackages {
    $result = Invoke-NfNative -FilePath 'choco' -ArgumentList @('list', '--limit-output')
    $names = @()
    if ($result.ExitCode -ne 0) { return $names }
    foreach ($line in $result.Output) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $names += $trimmed.Split('|')[0].Trim()
    }
    return $names
}

function Test-NfChocoFontInstalled {
    param([string]$Id)
    $package = Get-NfChocoPackageForId -Id $Id
    $locals = Get-NfChocoLocalPackages
    return (Test-NfListContains -List $locals -Value $package)
}

function Get-NfChocoInstalledFonts {
    $ids = @()
    foreach ($name in (Get-NfChocoLocalPackages)) {
        if ($name -notlike 'nerd-fonts-*') { continue }
        $id = Get-NfIdFromChocoPackage -PackageName $name
        if ($id) { $ids += $id }
    }
    return @($ids | Sort-Object -Unique)
}

function Invoke-NfChocoInstall {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
        $package = Get-NfChocoPackageForId -Id $id
        Show-NfPlain "Installing ${package}..."
        $result = Invoke-NfNative -FilePath 'choco' -ArgumentList @('install', $package, '-y', '--no-progress')
        if ($result.ExitCode -eq 0) {
            Write-NfSuccess "Successfully installed ${package}."
        }
        else {
            Write-NfWarn "Failed to install ${package} (Chocolatey machine-scope installs usually need an elevated shell)."
            $script:FailedFonts.Add($id)
        }
    }
}

function Invoke-NfChocoUninstall {
    param([string[]]$Ids)
    foreach ($id in $Ids) {
        $package = Get-NfChocoPackageForId -Id $id
        Show-NfPlain "Uninstalling ${package}..."
        $result = Invoke-NfNative -FilePath 'choco' -ArgumentList @('uninstall', $package, '-y', '--skip-autouninstaller')
        if ($result.ExitCode -eq 0) {
            Write-NfSuccess "Successfully uninstalled ${package}."
        }
        else {
            Write-NfWarn "Failed to uninstall ${package}."
            $script:FailedFonts.Add($id)
        }
    }
}

function Show-NfChocoDryRunInstall {
    param([string]$Id)
    Write-Output "[dry-run] Would install $(Get-NfChocoPackageForId -Id $Id) (choco install -y)."
}

function Show-NfChocoDryRunUninstall {
    param([string]$Id)
    Write-Output "[dry-run] Would uninstall $(Get-NfChocoPackageForId -Id $Id) (choco uninstall -y)."
}

###############################################################################
# Region: Direct backend (mirrors scripts/lib/backends/direct.sh)
###############################################################################

# Canonical id = release asset basename without .zip, lowercased
# (JetBrainsMono.zip -> jetbrainsmono), identical to the bash backend.
# Windows consumes the .zip assets instead of .tar.xz.

function Get-NfCacheRoot {
    if ($script:CacheRoot) { return $script:CacheRoot }
    if ($env:LOCALAPPDATA) {
        $script:CacheRoot = Join-Path $env:LOCALAPPDATA 'nerdfonts-installer'
        return $script:CacheRoot
    }
    # Off-Windows fallback (test hosts): mirror the bash XDG cache layout.
    if ($env:XDG_CACHE_HOME) { return (Join-Path $env:XDG_CACHE_HOME 'nerdfonts-installer') }
    if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE (Join-Path '.cache' 'nerdfonts-installer')) }
    return (Join-Path ([IO.Path]::GetTempPath()) 'nerdfonts-installer')
}

function Get-NfDirectManifestCacheFile {
    return (Join-Path (Get-NfCacheRoot) 'manifest.cache')
}

function Get-NfDirectMarkerDir {
    return (Join-Path (Get-NfCacheRoot) 'installed')
}

function Get-NfDirectFontDir {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft' (Join-Path 'Windows' 'Fonts')))
    }
    return (Join-Path (Get-NfCacheRoot) 'fonts')
}

function Read-NfManifestDataFile {
    param([string]$Path)
    $lines = @(Get-Content -Path $Path -ErrorAction Stop)
    if ($lines.Count -lt 1) { return $null }
    $meta = $lines[0]
    if (-not $meta.StartsWith('#META|')) { return $null }
    $metaParts = $meta.Split('|')
    $tag = ''
    if ($metaParts.Count -ge 3) { $tag = $metaParts[2] }
    $urls = @()
    foreach ($line in $lines) {
        if ($line -and (-not $line.StartsWith('#META|'))) { $urls += $line }
    }
    if (-not $tag -or $urls.Count -eq 0) { return $null }
    return [pscustomobject]@{ Tag = $tag; Urls = $urls }
}

function Save-NfManifestCache {
    param([pscustomobject]$Data)
    $cache = Get-NfDirectManifestCacheFile
    $dir = Split-Path -Path $cache -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Join-Path $dir ('.manifest-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $content = New-Object System.Collections.Generic.List[string]
    $content.Add("#META|$epoch|$($Data.Tag)")
    foreach ($url in $Data.Urls) { $content.Add($url) }
    Set-Content -Path $tmp -Value @($content.ToArray()) -Encoding ASCII
    Move-Item -Path $tmp -Destination $cache -Force
}

# Fetch-NfFreshManifest contacts the GitHub releases API. Returns $null on any
# failure (network, parsing, rate limiting); callers decide how to recover.
function Fetch-NfFreshManifest {
    # Windows PowerShell 5.1 may default to protocols older than TLS 1.2.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # Keep whatever protocol stack is available.
    }

    try {
        if ($env:GITHUB_TOKEN) {
            $headers = @{ Authorization = "token $($env:GITHUB_TOKEN)" }
            $release = Invoke-RestMethod -Uri $script:GitHubReleaseApi -Headers $headers -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        }
        else {
            $release = Invoke-RestMethod -Uri $script:GitHubReleaseApi -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        }
    }
    catch {
        Write-NfDebug "manifest fetch failed: $($_.Exception.Message)"
        return $null
    }

    $tag = ''
    if ($release.tag_name) { $tag = [string]$release.tag_name }
    $urls = @()
    foreach ($asset in @($release.assets)) {
        $url = [string]$asset.browser_download_url
        if ($url.ToLowerInvariant().EndsWith('.zip')) { $urls += $url }
    }
    if (-not $tag -or $urls.Count -eq 0) { return $null }

    return [pscustomobject]@{ Tag = $tag; Urls = $urls }
}

# Import-NfDirectManifest fills DirectFontMap/DirectTag from (in order of
# preference): the NF_TEST_MANIFEST_FILE fixture, a fresh API fetch, or a
# stale cache (with a warning). Without any usable source it exits with code 2.
function Import-NfDirectManifest {
    if ($script:DirectFontMap.Count -gt 0) { return }

    $data = $null
    $cache = Get-NfDirectManifestCacheFile
    $noCache = ($env:DIRECT_NO_CACHE -eq '1')
    $ttlHours = 24
    if ($env:DIRECT_CACHE_TTL_HOURS) {
        $parsedTtl = [int64]0
        if ([int64]::TryParse($env:DIRECT_CACHE_TTL_HOURS, [ref]$parsedTtl)) { $ttlHours = $parsedTtl }
    }
    $ttlSeconds = $ttlHours * 3600

    # Hidden testing hook: read the manifest from a fixture file instead of
    # the network (used by the repo test suites and offline smoke tests).
    if ($env:NF_TEST_MANIFEST_FILE) {
        if (-not (Test-Path $env:NF_TEST_MANIFEST_FILE)) {
            Exit-Nf 2 "NF_TEST_MANIFEST_FILE points to a missing file: $($env:NF_TEST_MANIFEST_FILE)"
        }
        $data = Read-NfManifestDataFile -Path $env:NF_TEST_MANIFEST_FILE
        if (-not $data) { Exit-Nf 2 "NF_TEST_MANIFEST_FILE fixture is malformed: $($env:NF_TEST_MANIFEST_FILE)" }
    }
    else {
        if (-not $noCache -and (Test-Path $cache)) {
            $cached = $null
            try { $cached = Read-NfManifestDataFile -Path $cache } catch { $cached = $null }
            if ($cached) {
                $metaLine = Get-Content -Path $cache -TotalCount 1
                $tsPart = $metaLine.Split('|')[1]
                $ts = [int64]0
                if (-not [int64]::TryParse($tsPart, [ref]$ts)) { $ts = [int64]0 }
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                # ">=" so that DIRECT_CACHE_TTL_HOURS=0 means "always expired".
                if (($now - $ts) -lt $ttlSeconds) { $data = $cached }
            }
        }

        if (-not $data) {
            $fresh = Fetch-NfFreshManifest
            if ($fresh) {
                try { Save-NfManifestCache -Data $fresh } catch { Write-NfDebug "could not write manifest cache: $($_.Exception.Message)" }
                $data = $fresh
            }
            elseif (-not $noCache -and (Test-Path $cache)) {
                try { $data = Read-NfManifestDataFile -Path $cache } catch { $data = $null }
                if ($data) {
                    Write-NfWarn 'Could not refresh the Nerd Fonts release manifest. Using the stale cached copy.'
                }
            }
        }
    }

    if (-not $data) {
        Exit-Nf 2 "Failed to download the Nerd Fonts release manifest from GitHub.`nIf this persists you may be rate-limited (HTTP 403). Set a GITHUB_TOKEN environment variable and retry."
    }

    foreach ($url in $data.Urls) {
        if (-not $url.ToLowerInvariant().EndsWith('.zip')) { continue }
        $fileName = ($url -split '/')[-1]
        $id = ConvertTo-NfLowercase ([IO.Path]::GetFileNameWithoutExtension($fileName))
        if (-not $id) { continue }
        if (-not $script:DirectFontMap.ContainsKey($id)) {
            $script:DirectFontMap[$id] = $fileName
        }
    }
    $script:DirectTag = $data.Tag

    if ($script:DirectFontMap.Count -eq 0) {
        Exit-Nf 2 'The Nerd Fonts release manifest contains no .zip assets.'
    }
}

function Get-NfDirectAssetForId {
    param([string]$Id)
    if ($script:DirectFontMap.ContainsKey($Id)) { return $script:DirectFontMap[$Id] }
    return ($Id + '.zip')
}

function Get-NfDirectDownloadUrl {
    param([string]$Asset)
    return "https://github.com/$($script:GitHubRepo)/releases/download/$($script:DirectTag)/$Asset"
}

function Get-NfDirectFonts {
    Import-NfDirectManifest
    return @($script:DirectFontMap.Keys | Sort-Object)
}

function Get-NfDirectInstalledFonts {
    $markerDir = Get-NfDirectMarkerDir
    if (-not (Test-Path $markerDir)) { return @() }
    $ids = @(Get-ChildItem -Path $markerDir -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name } |
        Sort-Object)
    return $ids
}

# Get-NfDirectFontFiles yields files in the user font directory whose
# lowercased name matches "<id>*nerdfont*" (covers fonts managed elsewhere).
function Get-NfDirectFontFiles {
    param([string]$Id)
    $fontDir = Get-NfDirectFontDir
    if (-not (Test-Path $fontDir)) { return @() }
    $pattern = "${Id}*nerdfont*"
    $files = @(Get-ChildItem -Path $fontDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.ToLowerInvariant() -like $pattern } |
        ForEach-Object { $_.FullName })
    return $files
}

function Get-NfFontRegistryEntries {
    $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $key)) { return @() }
    $props = Get-ItemProperty -Path $key
    $reserved = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    $entries = @()
    foreach ($prop in $props.PSObject.Properties) {
        if ($reserved -contains $prop.Name) { continue }
        if ($prop.Value -isnot [string]) { continue }
        $entries += [pscustomobject]@{ Name = $prop.Name; Path = $prop.Value }
    }
    return $entries
}

function Test-NfDirectFontRegistered {
    param([string]$Id)
    if (-not $script:IsWindowsHost) { return $false }
    $needle = ("\{0}*nerdfont*" -f $Id)
    foreach ($entry in (Get-NfFontRegistryEntries)) {
        $value = ''
        if ($entry.Path) { $value = $entry.Path.ToLowerInvariant().Replace('/', '\') }
        if ($value.ToLowerInvariant().Contains($needle.ToLowerInvariant())) { return $true }
    }
    return $false
}

function Test-NfDirectFontInstalled {
    param([string]$Id)
    if (Test-Path (Join-Path (Get-NfDirectMarkerDir) $Id)) { return $true }
    if (@(Get-NfDirectFontFiles -Id $Id).Count -gt 0) { return $true }
    return (Test-NfDirectFontRegistered -Id $Id)
}

# Get-NfFontInternalName extracts the internal family name from the font file
# itself via System.Drawing (PrivateFontCollection). When that is unavailable
# (non-Windows hosts, sandboxed environments) the base file name is used.
function Get-NfFontInternalName {
    param([string]$FilePath)
    if ($script:IsWindowsHost) {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $collection = New-Object System.Drawing.Text.PrivateFontCollection
            $collection.AddFontFile($FilePath)
            $name = $collection.Families[0].Name
            $collection.Dispose()
            if ($name) { return $name }
        }
        catch {
            # Fall through to the file-name fallback below.
        }
    }
    return [IO.Path]::GetFileNameWithoutExtension($FilePath)
}

# Register-NfFontFile adds "HKCU:\...\Fonts\<InternalName> (TrueType)" pointing
# to the installed file. Returns $true on success.
function Register-NfFontFile {
    param([string]$FilePath)
    $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $internalName = Get-NfFontInternalName -FilePath $FilePath
        $baseName = "$internalName (TrueType)"
        $finalName = $baseName
        $existing = Get-NfFontRegistryEntries
        $counter = 1
        while ($true) {
            $conflict = $null
            foreach ($entry in $existing) {
                if ($entry.Name -ieq $finalName) { $conflict = $entry; break }
            }
            if (-not $conflict) { break }
            if ($conflict.Path -ieq $FilePath) { break } # already registered
            $counter = $counter + 1
            $finalName = "$internalName ($counter) (TrueType)"
        }
        New-ItemProperty -Path $key -Name $finalName -Value $FilePath -PropertyType String -Force | Out-Null
        return $true
    }
    catch {
        Write-NfWarn "Could not register '$([IO.Path]::GetFileName($FilePath))' in the user font registry: $($_.Exception.Message)"
        return $false
    }
}

# Unregister-NfFontFilesById removes every registry entry whose stored file
# path matches "<...>\<id>*nerdfont*". Returns the number of removed entries.
function Unregister-NfFontFilesById {
    param([string]$Id)
    if (-not $script:IsWindowsHost) { return 0 }
    $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $needle = ("\{0}*nerdfont*" -f $Id).ToLowerInvariant()
    $removed = 0
    foreach ($entry in (Get-NfFontRegistryEntries)) {
        $value = ''
        if ($entry.Path) { $value = $entry.Path.ToLowerInvariant().Replace('/', '\') }
        if ($value.Contains($needle)) {
            try {
                Remove-ItemProperty -Path $key -Name $entry.Name -ErrorAction Stop
                $removed = $removed + 1
            }
            catch {
                Write-NfWarn "Could not remove registry entry '$($entry.Name)': $($_.Exception.Message)"
            }
        }
    }
    return $removed
}

function Show-NfDirectDryRunInstall {
    param([string]$Id)
    Import-NfDirectManifest
    $asset = Get-NfDirectAssetForId -Id $Id
    Write-Output "[dry-run] Would download $(Get-NfDirectDownloadUrl -Asset $asset)."
}

function Show-NfDirectDryRunUninstall {
    param([string]$Id)
    Write-Output "[dry-run] Would uninstall ${Id} (remove font files, registry entries and the install marker)."
}

# Install-NfDirectFonts installs every given id sequentially: download .zip,
# expand, copy *.ttf/*.otf, register in HKCU and drop the success marker.
# Parallel downloads were deliberately skipped on Windows: Start-Job costs
# more than it saves here and keeps PS 5.1 support simple (see .NOTES).
function Install-NfDirectFonts {
    param([string[]]$Ids)

    $fontDir = Get-NfDirectFontDir
    $markerDir = Get-NfDirectMarkerDir
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nerdfonts-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        foreach ($id in $Ids) {
            $asset = Get-NfDirectAssetForId -Id $id
            $zipPath = Join-Path $tempRoot $asset
            $extractDir = Join-Path $tempRoot ("extract-" + $id)
            $url = Get-NfDirectDownloadUrl -Asset $asset
            $ok = $true

            try {
                Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            }
            catch {
                Write-NfWarn "Failed to install ${id}: download error ($($_.Exception.Message))."
                $ok = $false
            }

            if ($ok -and (-not (Test-Path $zipPath))) {
                Write-NfWarn "Failed to install ${id}: downloaded archive is missing."
                $ok = $false
            }

            if ($ok) {
                try {
                    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
                    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
                }
                catch {
                    Write-NfWarn "Failed to install ${id}: extraction error ($($_.Exception.Message))."
                    $ok = $false
                }
            }

            $fontFiles = @()
            if ($ok) {
                $fontFiles = @(Get-ChildItem -Path $extractDir -Recurse -Include *.ttf, *.otf -File -ErrorAction SilentlyContinue)
                if ($fontFiles.Count -eq 0) {
                    Write-NfWarn "Failed to install ${id}: archive contains no .ttf/.otf files."
                    $ok = $false
                }
            }

            if ($ok) {
                try {
                    if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }
                    foreach ($fontFile in $fontFiles) {
                        Copy-Item -Path $fontFile.FullName -Destination (Join-Path $fontDir $fontFile.Name) -Force -ErrorAction Stop
                    }
                }
                catch {
                    Write-NfWarn "Failed to install ${id}: could not copy font files ($($_.Exception.Message))."
                    $ok = $false
                }
            }

            if ($ok -and $script:IsWindowsHost) {
                foreach ($fontFile in $fontFiles) {
                    $target = Join-Path $fontDir $fontFile.Name
                    if (-not (Register-NfFontFile -FilePath $target)) { $ok = $false }
                }
            }
            elseif ($ok -and (-not $script:IsWindowsHost)) {
                Write-NfWarn 'Not running on Windows: font files were copied but registry registration was skipped.'
            }

            if ($ok) {
                if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
                New-Item -ItemType File -Path (Join-Path $markerDir $id) -Force | Out-Null
                Write-NfSuccess "Successfully installed ${id}."
            }
            else {
                $script:FailedFonts.Add($id)
            }
        }
    }
    finally {
        $ProgressPreference = $previousProgress
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-NfDirectFonts {
    param([string[]]$Ids)
    $markerDir = Get-NfDirectMarkerDir
    foreach ($id in $Ids) {
        $removedAny = $false

        foreach ($filePath in (Get-NfDirectFontFiles -Id $id)) {
            try {
                Remove-Item -Path $filePath -Force -ErrorAction Stop
                $removedAny = $true
            }
            catch {
                Write-NfWarn "Could not remove '$filePath': $($_.Exception.Message)"
            }
        }

        if ((Unregister-NfFontFilesById -Id $id) -gt 0) { $removedAny = $true }

        $marker = Join-Path $markerDir $id
        if (Test-Path $marker) {
            Remove-Item -Path $marker -Force -ErrorAction SilentlyContinue
            $removedAny = $true
        }

        if ($removedAny) {
            Write-NfSuccess "Successfully uninstalled ${id}."
        }
        else {
            Write-NfWarn "Nothing to remove for ${id}; marking as failed."
            $script:FailedFonts.Add($id)
        }
    }
}

###############################################################################
# Region: Catalog/dispatch layer (mirrors scripts/lib/fonts.sh)
###############################################################################

function Get-NfFonts {
    if ($script:CatalogLoaded -and $script:CachedFontListBackend -eq $script:ResolvedBackend) {
        return $script:CachedFontList
    }
    $list = Get-NfBackendFontCatalog $script:ResolvedBackend
    Set-NfCatalogCache -Name $script:ResolvedBackend -List $list
    return $script:CachedFontList
}

function Get-NfInstalledFonts {
    if ($script:InstalledLoaded) { return $script:CachedInstalledList }
    $list = @()
    switch ($script:ResolvedBackend) {
        'scoop' { $list = Get-NfScoopInstalledPackagesMapped }
        'winget' { $list = Get-NfWingetInstalledFonts }
        'choco' { $list = Get-NfChocoInstalledFonts }
        'direct' { $list = Get-NfDirectInstalledFonts }
        default { $list = @() }
    }
    $script:CachedInstalledList = @($list)
    $script:InstalledLoaded = $true
    return $script:CachedInstalledList
}

function Test-NfFontInstalled {
    param([string]$Id)
    switch ($script:ResolvedBackend) {
        'scoop' { return (Test-NfScoopFontInstalled -Id $Id) }
        'winget' { return (Test-NfWingetFontInstalled -Id $Id) }
        'choco' { return (Test-NfChocoFontInstalled -Id $Id) }
        'direct' { return (Test-NfDirectFontInstalled -Id $Id) }
        default { return $false }
    }
}

function Show-NfDryRunInstall {
    param([string]$Id)
    switch ($script:ResolvedBackend) {
        'scoop' { Show-NfScoopDryRunInstall -Id $Id }
        'winget' { Show-NfWingetDryRunInstall -Id $Id }
        'choco' { Show-NfChocoDryRunInstall -Id $Id }
        'direct' { Show-NfDirectDryRunInstall -Id $Id }
        default { Write-Output "[dry-run] Would install ${Id}." }
    }
}

function Show-NfDryRunUninstall {
    param([string]$Id)
    switch ($script:ResolvedBackend) {
        'scoop' { Show-NfScoopDryRunUninstall -Id $Id }
        'winget' { Show-NfWingetDryRunUninstall -Id $Id }
        'choco' { Show-NfChocoDryRunUninstall -Id $Id }
        'direct' { Show-NfDirectDryRunUninstall -Id $Id }
        default { Write-Output "[dry-run] Would uninstall ${Id}." }
    }
}

function Invoke-NfBackendInstall {
    param([string[]]$Ids)
    switch ($script:ResolvedBackend) {
        'scoop' { Invoke-NfScoopInstall -Ids $Ids }
        'winget' { Invoke-NfWingetInstall -Ids $Ids }
        'choco' { Invoke-NfChocoInstall -Ids $Ids }
        'direct' { Install-NfDirectFonts -Ids $Ids }
        default { Exit-Nf 2 "Unsupported backend '$($script:ResolvedBackend)'." }
    }
}

function Invoke-NfBackendUninstall {
    param([string[]]$Ids)
    switch ($script:ResolvedBackend) {
        'scoop' { Invoke-NfScoopUninstall -Ids $Ids }
        'winget' { Invoke-NfWingetUninstall -Ids $Ids }
        'choco' { Invoke-NfChocoUninstall -Ids $Ids }
        'direct' { Uninstall-NfDirectFonts -Ids $Ids }
        default { Exit-Nf 2 "Unsupported backend '$($script:ResolvedBackend)'." }
    }
}

# Invoke-NfInstallPipeline batches one backend transaction per operation,
# filtering already-installed fonts with a skip warning (mirrors bash).
function Invoke-NfInstallPipeline {
    param([string[]]$Ids)
    $script:FailedFonts = New-Object System.Collections.Generic.List[string]
    $pending = @()
    foreach ($id in $Ids) {
        if ($script:OptDryRun) {
            Show-NfDryRunInstall -Id $id
        }
        elseif (Test-NfFontInstalled -Id $id) {
            Write-NfWarn "${id} is already installed. Skipping."
        }
        else {
            $pending += $id
        }
    }
    if ($script:OptDryRun) { return }
    if ($pending.Count -eq 0) { return }
    Invoke-NfBackendInstall -Ids $pending
}

function Invoke-NfUninstallPipeline {
    param([string[]]$Ids)
    $script:FailedFonts = New-Object System.Collections.Generic.List[string]
    $pending = @()
    foreach ($id in $Ids) {
        if ($script:OptDryRun) {
            Show-NfDryRunUninstall -Id $id
        }
        elseif (-not (Test-NfFontInstalled -Id $id)) {
            Write-NfWarn "${id} is not installed. Skipping."
        }
        else {
            $pending += $id
        }
    }
    if ($script:OptDryRun) { return }
    if ($pending.Count -eq 0) { return }
    Invoke-NfBackendUninstall -Ids $pending
}

###############################################################################
# Region: Actions/workflows (mirrors scripts/lib/main.sh)
###############################################################################

function Show-NfCatalog {
    $catalog = Get-NfFonts
    if (@($catalog).Count -eq 0) {
        Exit-Nf 3 "No Nerd Fonts found for the '$($script:ResolvedBackend)' backend."
    }
    foreach ($id in $catalog) { Write-Output $id }
}

function Show-NfInstalledCatalog {
    $installed = Get-NfInstalledFonts
    if (@($installed).Count -eq 0) {
        Write-NfWarn 'No Nerd Fonts are currently installed.'
        return
    }
    foreach ($id in $installed) { Write-Output $id }
}

# Select-NfItemsInteractive is the native replacement for the bash fzf
# selector: a numbered console menu accepting comma-separated numbers,
# "a"/"all", or an empty answer to cancel.
function Select-NfItemsInteractive {
    param([string[]]$Items, [string]$PromptTitle)
    if (-not [Environment]::UserInteractive) {
        Write-NfWarn 'No interactive console available. Use -Fonts, -All or -UninstallAll instead.'
        return @()
    }

    Show-NfPlain $PromptTitle
    for ($index = 0; $index -lt $Items.Count; $index = $index + 1) {
        $number = $index + 1
        Show-NfPlain ("  {0,4}) {1}" -f $number, $Items[$index])
    }

    $answer = Read-Host "Selection (comma-separated numbers, 'a' for all, ENTER to cancel)"
    $answer = ('' + $answer).Trim()
    if (-not $answer) {
        Write-NfWarn 'No fonts selected. Exiting without changes.'
        return @()
    }

    if ($answer -ieq 'a' -or $answer -ieq 'all') { return @($Items) }

    $chosen = @()
    foreach ($token in $answer.Split(',')) {
        $trimmed = $token.Trim()
        if (-not $trimmed) { continue }
        $numeric = 0
        if (-not [int]::TryParse($trimmed, [ref]$numeric)) {
            Write-NfWarn "Ignoring invalid selection '${trimmed}'."
            continue
        }
        if ($numeric -lt 1 -or $numeric -gt $Items.Count) {
            Write-NfWarn "Ignoring out-of-range selection '${trimmed}'."
            continue
        }
        $chosen += $Items[$numeric - 1]
    }
    return $chosen
}

function Invoke-NfInstallWorkflow {
    $catalog = Get-NfFonts
    if (@($catalog).Count -eq 0) {
        Exit-Nf 3 "No Nerd Fonts found for the '$($script:ResolvedBackend)' backend."
    }

    if ($script:FontsWasBound) {
        $requested = Get-NfCanonicalIdsFromCsv -Csv $script:OptFonts
        $toInstall = @()
        foreach ($font in $requested) {
            if (Test-NfListContains -List $catalog -Value $font) {
                $toInstall += $font
            }
            else {
                Write-NfWarn "Unknown font '${font}'. Skipping."
            }
        }
        if ($toInstall.Count -eq 0) {
            Exit-Nf 3 'None of the requested fonts are available. Run with -List to see the valid names.'
        }

        Write-NfStep 'Fetching available Nerd Fonts...'
        Invoke-NfInstallPipeline -Ids $toInstall
        if ($script:FailedFonts.Count -gt 0) {
            Exit-Nf 4 "Some fonts failed to install ($($script:FailedFonts -join ', ')). Please review the output above."
        }
        return
    }

    Write-NfStep 'Fetching available Nerd Fonts...'

    if ($script:OptAll) {
        Write-NfStep 'Installing all available Nerd Fonts...'
        Invoke-NfInstallPipeline -Ids $catalog
        if ($script:FailedFonts.Count -gt 0) {
            Exit-Nf 4 "Some fonts failed to install ($($script:FailedFonts -join ', ')). Please review the output above."
        }
        return
    }

    $selected = Select-NfItemsInteractive -Items $catalog -PromptTitle 'Select the Nerd Fonts you want to install:'
    if (@($selected).Count -eq 0) { return }

    Write-NfStep 'Installing selected Nerd Fonts...'
    Invoke-NfInstallPipeline -Ids $selected
    if ($script:FailedFonts.Count -gt 0) {
        Exit-Nf 4 "Some fonts failed to install ($($script:FailedFonts -join ', ')). Please review the output above."
    }
}

function Invoke-NfUninstallWorkflow {
    $installed = Get-NfInstalledFonts

    if ($script:OptUninstallAll) {
        if (@($installed).Count -eq 0) {
            Write-NfWarn 'No Nerd Fonts are currently installed. Nothing to uninstall.'
            return
        }
        Write-NfStep 'Uninstalling all installed Nerd Fonts...'
        Invoke-NfUninstallPipeline -Ids $installed
        if ($script:FailedFonts.Count -gt 0) {
            Exit-Nf 4 "Some fonts failed to uninstall ($($script:FailedFonts -join ', ')). Please review the output above."
        }
        return
    }

    if ($script:FontsWasBound) {
        $requested = Get-NfCanonicalIdsFromCsv -Csv $script:OptFonts
        $toUninstall = @()
        foreach ($font in $requested) {
            if (Test-NfListContains -List $installed -Value $font) {
                $toUninstall += $font
            }
            else {
                Write-NfWarn "'${font}' is not installed. Skipping."
            }
        }
        if ($toUninstall.Count -eq 0) {
            Exit-Nf 3 'None of the requested fonts are installed. Run with -Installed to see what is present.'
        }

        Invoke-NfUninstallPipeline -Ids $toUninstall
        if ($script:FailedFonts.Count -gt 0) {
            Exit-Nf 4 "Some fonts failed to uninstall ($($script:FailedFonts -join ', ')). Please review the output above."
        }
        return
    }

    if (@($installed).Count -eq 0) {
        Write-NfWarn 'No Nerd Fonts are currently installed. Nothing to uninstall.'
        return
    }

    $selected = Select-NfItemsInteractive -Items $installed -PromptTitle 'Select the Nerd Fonts you want to uninstall:'
    if (@($selected).Count -eq 0) { return }

    Invoke-NfUninstallPipeline -Ids $selected
    if ($script:FailedFonts.Count -gt 0) {
        Exit-Nf 4 "Some fonts failed to uninstall ($($script:FailedFonts -join ', ')). Please review the output above."
    }
}

###############################################################################
# Region: Usage, version and main entrypoint
###############################################################################

function Show-NfUsage {
    $text = @'
Usage: install.ps1 [-All | -Fonts "a,b,c"] [options]

Install, inspect and uninstall Nerd Fonts on Windows through multiple
backends (scoop, winget, chocolatey or direct GitHub downloads).

Actions:
  (default)                  Interactive console multi-select installation.
  -All                       Install all available Nerd Fonts (non-interactive).
  -Fonts "FONT[,FONT]"       Install the named fonts (non-interactive). Values
                             are canonical ids (e.g., firacode, jetbrainsmono,
                             hack); unknown names warn and are skipped.
  -List                      Print the available Nerd Fonts (one per line) and exit.
  -Installed                 Print the installed Nerd Fonts ids (one per line) and exit.
  -Uninstall                 Uninstall fonts. Alone, opens the interactive
                             selector over the installed fonts. Combine with
                             "-Fonts a,b" to remove exactly those fonts.
  -UninstallAll              Remove every installed Nerd Font (implies -Uninstall).

Options:
  -Backend auto|scoop|winget|choco|direct
                             Installation backend (default: auto). With "auto",
                             the first manager reporting a non-empty Nerd Fonts
                             catalog wins, in this order:
                             scoop -> winget -> choco; when none qualifies,
                             fonts come straight from the official GitHub
                             releases ("direct"). An explicit backend is always
                             honored (even with an empty catalog).
  -DryRun                    Print what would be done without touching the system.
  -Quiet                     Suppress step/success/warning messages (errors
                             are still printed). Equivalent to QUIET=1.
  -NoColor                   Disable colored output. The NO_COLOR environment
                             variable is honored automatically as well.
  -Version                   Print version information and exit.
  -Help                      Show this help message and exit.

Environment variables:
  GITHUB_TOKEN               GitHub API token (direct backend; avoids 403s).
  DIRECT_CACHE_TTL_HOURS     Manifest cache TTL in hours (default: 24).
  DIRECT_NO_CACHE=1          Bypass the direct-backend manifest cache.
  NF_DEBUG_BACKEND=1         Print backend resolution debug info to stderr.
  NF_TEST_MANIFEST_FILE      (testing) Read the direct-backend manifest from
                             this file instead of the GitHub API.

Exit codes:
  0   Success.
  1   Invalid argument, usage or validation error.
  2   Missing dependency (e.g., manifest fetch failed).
  3   No Nerd Fonts found or available for the requested operation.
  4   Partial failure: some fonts failed to install or uninstall.

Examples:
  install.ps1                                     # Interactive selection
  install.ps1 -All                                # Install all fonts
  install.ps1 -Fonts "firacode"                   # Install named fonts
  install.ps1 -Fonts "firacode, hack" -DryRun
  install.ps1 -Backend scoop -List                # scoop bucket catalog
  install.ps1 -Installed                          # Show installed fonts
  install.ps1 -UninstallAll                       # Remove every Nerd Font

Full help: Get-Help .\scripts\install.ps1
'@
    Write-Host $text
}

function Exit-Nf {
    param([int]$Code, [string]$Message)
    if ($Message) { Write-NfError $Message }
    exit $Code
}

function Invoke-NfMain {
    try {
        Assert-NfValidOptions
    }
    catch [NfUsageException] {
        Write-NfError $_.Exception.Message
        exit 1
    }

    if ($script:OptVersion) {
        Write-Output "nerdfonts-installer $($script:NFVersion)"
        exit 0
    }

    if ($script:OptHelp) {
        Show-NfUsage
        exit 0
    }

    try {
        Resolve-NfBackend -Requested $script:OptBackend

        if ($script:OptList) {
            Show-NfCatalog
            exit 0
        }

        if ($script:OptInstalled) {
            Show-NfInstalledCatalog
            exit 0
        }

        if ($script:IsUninstallAction) {
            Invoke-NfUninstallWorkflow
            exit 0
        }

        Invoke-NfInstallWorkflow
        exit 0
    }
    catch [NfUsageException] {
        Write-NfError $_.Exception.Message
        exit 1
    }
    catch [System.Management.Automation.ParameterBindingException] {
        Write-NfError $_.Exception.Message
        exit 1
    }
    catch {
        Write-NfError "Unexpected failure: $($_.Exception.Message)"
        Write-NfDebug $_.ScriptStackTrace
        exit 2
    }
}

Invoke-NfMain
