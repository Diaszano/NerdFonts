#Requires -Version 5.1
<#
.SYNOPSIS
    Native Windows installer for Nerd Fonts (winget and direct GitHub downloads).
#>
[CmdletBinding()]
param(
    [switch]$All, [string]$Fonts, [switch]$List, [switch]$Installed,
    [switch]$Uninstall, [switch]$UninstallAll, [string]$Backend = 'auto',
    [switch]$DryRun, [switch]$Quiet, [switch]$NoColor, [switch]$Version, [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NFVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { 'dev' }
$script:GitHubRepo = if ($env:GITHUB_REPO) { $env:GITHUB_REPO } else { 'ryanoasis/nerd-fonts' }
$script:ColorsEnabled = (-not $NoColor) -and (-not $env:NO_COLOR)
$script:OptQuiet = [bool]$Quiet -or ($env:QUIET -eq '1')
$script:ResolvedBackend = 'auto'
$script:FailedFonts = New-Object System.Collections.Generic.List[string]

$script:KnownFonts = @('0xproto 3270 agave anonymouspro arimo aurulentsansmono bigblueterminal bitstreamverasansmono cascadiacode cascadiamono codenewroman comicshannsmono cousine daddytimemono dejavusansmono droidsansmono envycoder fantasquesansmono firacode firamono geistmono gohufont gomono hack hasklig heavydata hermit iawriter inconsolata inconsolatago inconsolatalgc intefont iosevka iosevkaterm jetbrainsmono lekton liberationmono lilex martianmono meslo monaspace monofur monoid mononoki mplus nerdfontssymbolsonly noto opencodemonospace overpass profont proggyclean recursive roboto robotomono sharetechmono sourcecodepro spacemono terminess tinos ubuntu ubuntumono ubuntusans victormono zedmono' -split '\s+')
$script:AssetMap = @{ '0xproto'='0xProto'; 'anonymouspro'='AnonymousPro'; 'aurulentsansmono'='AurulentSansMono'; 'bigblueterminal'='BigBlueTerminal'; 'bitstreamverasansmono'='BitstreamVeraSansMono'; 'cascadiacode'='CascadiaCode'; 'cascadiamono'='CascadiaMono'; 'codenewroman'='CodeNewRoman'; 'comicshannsmono'='ComicShannsMono'; 'daddytimemono'='DaddyTimeMono'; 'dejavusansmono'='DejaVuSansMono'; 'droidsansmono'='DroidSansMono'; 'envycoder'='EnvyCodeR'; 'fantasquesansmono'='FantasqueSansMono'; 'firacode'='FiraCode'; 'firamono'='FiraMono'; 'geistmono'='GeistMono'; 'gohufont'='Gohu'; 'gomono'='Go-Mono'; 'iawriter'='iA-Writer'; 'inconsolatago'='InconsolataGo'; 'inconsolatalgc'='InconsolataLGC'; 'intefont'='IntelOneMono'; 'iosevkaterm'='IosevkaTerm'; 'jetbrainsmono'='JetBrainsMono'; 'liberationmono'='LiberationMono'; 'martianmono'='MartianMono'; 'nerdfontssymbolsonly'='NerdFontsSymbolsOnly'; 'opencodemonospace'='OpenCodeMonospace'; 'proggyclean'='ProggyClean'; 'robotomono'='RobotoMono'; 'sharetechmono'='ShareTechMono'; 'sourcecodepro'='SourceCodePro'; 'spacemono'='SpaceMono'; 'terminess'='Terminus'; 'ubuntumono'='UbuntuMono'; 'ubuntusans'='UbuntuSans'; 'victormono'='VictorMono'; 'zedmono'='ZedMono' }

function Get-NfDirectAsset {
    param([string]$Id)
    $c = $Id.ToLowerInvariant().Replace('-', '')
    if ($script:AssetMap.ContainsKey($c)) { return "$($script:AssetMap[$c]).zip" }
    return "$((Get-Culture).TextInfo.ToTitleCase($c)).zip"
}

function Write-NfStep { param([string]$m) if (-not $script:OptQuiet) { Write-Host "`n$([char]0x279C)  $m`n" -ForegroundColor $(if ($script:ColorsEnabled) { 'Cyan' } else { 'White' }) } }
function Write-NfSuccess { param([string]$m) if (-not $script:OptQuiet) { Write-Host "`n$([char]0x2705)  $m`n" -ForegroundColor $(if ($script:ColorsEnabled) { 'Green' } else { 'White' }) } }
function Write-NfWarn { param([string]$m) if (-not $script:OptQuiet) { Write-Host "$([char]0x26A0)  $m" -ForegroundColor $(if ($script:ColorsEnabled) { 'Yellow' } else { 'White' }) } }
function Write-NfError { param([string]$m) [Console]::Error.WriteLine("$([char]0x2757)  $m") }
function Exit-Nf { param([int]$c, [string]$m) if ($m) { Write-NfError $m }; exit $c }

function Assert-NfValidOptions {
    if (@('auto', 'winget', 'direct') -notcontains $Backend.Trim().ToLowerInvariant()) {
        throw ("Invalid backend '{0}'. Valid backends: auto, winget, direct." -f $Backend)
    }
    if ($PSBoundParameters.ContainsKey('Fonts') -and [string]::IsNullOrWhiteSpace($Fonts)) { throw 'Option -Fonts requires a non-empty value.' }
    if (($List -or $Installed) -and ($All -or $PSBoundParameters.ContainsKey('Fonts') -or $Uninstall -or $UninstallAll -or $DryRun)) {
        throw "Option $(if ($List) { '-List' } else { '-Installed' }) cannot be combined with other actions."
    }
    if ($All -and $PSBoundParameters.ContainsKey('Fonts')) { throw 'Options -All and -Fonts cannot be combined.' }
    if (($Uninstall -or $UninstallAll) -and $All) { throw 'Option -Uninstall cannot be combined with -All.' }
}

function Resolve-NfBackend {
    param([string]$Req)
    if ($Req -eq 'direct') { return 'direct' }
    if ($Req -eq 'winget') {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-NfWarn "Backend 'winget' is not available on this system." }
        return 'winget'
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget' }
    return 'direct'
}

function Get-NfFontDir { if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') }; return (Join-Path ([IO.Path]::GetTempPath()) 'nerdfonts\fonts') }
function Get-NfMarkerDir { if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'nerdfonts-installer\installed') }; return (Join-Path ([IO.Path]::GetTempPath()) 'nerdfonts\installed') }
function Install-NfFontNative { param([string]$FilePath) if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { (New-Object -ComObject Shell.Application).Namespace(0x14).CopyHere($FilePath, 0x10) } }

function Test-NfFontInstalled {
    param([string]$Id)
    if ($script:ResolvedBackend -eq 'winget') {
        $pkg = "NerdFonts.$((Get-NfDirectAsset $Id) -replace '\.zip$', '')"
        $res = & winget list --exact --id $pkg 2>&1
        return ($LASTEXITCODE -eq 0 -and ($res -match [regex]::Escape($pkg)))
    }
    if (Test-Path (Join-Path (Get-NfMarkerDir) $Id)) { return $true }
    $fontDir = Get-NfFontDir
    if (Test-Path $fontDir) {
        $found = Get-ChildItem -Path $fontDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.ToLowerInvariant() -like "${Id}*nerdfont*" }
        if (@($found).Count -gt 0) { return $true }
    }
    return $false
}

function Get-NfInstalledFonts {
    $installed = @()
    if ($script:ResolvedBackend -eq 'winget') {
        $res = & winget list 2>&1
        foreach ($id in $script:KnownFonts) {
            $pkg = "NerdFonts.$((Get-NfDirectAsset $id) -replace '\.zip$', '')"
            if ($res -match [regex]::Escape($pkg)) { $installed += $id }
        }
        return @($installed | Sort-Object -Unique)
    }
    $markerDir = Get-NfMarkerDir
    if (Test-Path $markerDir) {
        $installed += Get-ChildItem -Path $markerDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
    }
    foreach ($id in $script:KnownFonts) {
        if ($installed -notcontains $id -and (Test-NfFontInstalled $id)) { $installed += $id }
    }
    return @($installed | Sort-Object -Unique)
}

function Show-NfDryRun {
    param([string]$Act, [string]$Id)
    if ($script:ResolvedBackend -eq 'winget') {
        Write-Output "[dry-run] Would $Act NerdFonts.$((Get-NfDirectAsset $Id) -replace '\.zip$', '') (winget --id --exact)."
    } else {
        $m = if ($Act -eq 'install') { "download https://github.com/$($script:GitHubRepo)/releases/latest/download/$(Get-NfDirectAsset $Id)." } else { "uninstall $Id (remove font files and install marker)." }
        Write-Output "[dry-run] Would $m"
    }
}

function Install-NfFonts {
    param([string[]]$Ids)
    $fontDir = Get-NfFontDir; $markerDir = Get-NfMarkerDir
    foreach ($id in $Ids) {
        if ($DryRun) { Show-NfDryRun -Act 'install' -Id $id; continue }
        if (Test-NfFontInstalled $id) { Write-NfWarn "$id is already installed. Skipping."; continue }
        if ($script:ResolvedBackend -eq 'winget') {
            $pkg = "NerdFonts.$((Get-NfDirectAsset $id) -replace '\.zip$', '')"
            Write-Host "Installing $pkg..."
            & winget install --exact --id $pkg --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) { Write-NfSuccess "Successfully installed $pkg." }
            else { Write-NfWarn "Failed to install $pkg."; $script:FailedFonts.Add($id) }
            continue
        }
        $asset = Get-NfDirectAsset $id; $url = "https://github.com/$($script:GitHubRepo)/releases/latest/download/$asset"
        $tempZip = Join-Path ([IO.Path]::GetTempPath()) $asset; $tempExtract = Join-Path ([IO.Path]::GetTempPath()) "nf-extract-$id"
        $ok = $true
        try {
            Invoke-WebRequest -Uri $url -OutFile $tempZip -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
            New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop
            if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }
            $files = @(Get-ChildItem -Path $tempExtract -Recurse -Include *.ttf, *.otf -File -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) { Write-NfWarn "Failed to install ${id}: archive contains no .ttf/.otf files."; $ok = $false }
            else {
                foreach ($f in $files) {
                    $dest = Join-Path $fontDir $f.Name
                    Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction Stop
                    Install-NfFontNative -FilePath $dest
                }
            }
        } catch { Write-NfWarn "Failed to install ${id}: $($_.Exception.Message)"; $ok = $false }
        finally { Remove-Item -Path $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }

        if ($ok) {
            if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
            New-Item -ItemType File -Path (Join-Path $markerDir $id) -Force | Out-Null
            Write-NfSuccess "Successfully installed $id."
        } else { $script:FailedFonts.Add($id) }
    }
}

function Uninstall-NfFonts {
    param([string[]]$Ids)
    $fontDir = Get-NfFontDir; $markerDir = Get-NfMarkerDir
    foreach ($id in $Ids) {
        if ($DryRun) { Show-NfDryRun -Act 'uninstall' -Id $id; continue }
        if (-not (Test-NfFontInstalled $id)) { Write-NfWarn "$id is not installed. Skipping."; continue }
        if ($script:ResolvedBackend -eq 'winget') {
            $pkg = "NerdFonts.$((Get-NfDirectAsset $id) -replace '\.zip$', '')"
            Write-Host "Uninstalling $pkg..."
            & winget uninstall --exact --id $pkg --silent
            if ($LASTEXITCODE -eq 0) { Write-NfSuccess "Successfully uninstalled $pkg." }
            else { Write-NfWarn "Failed to uninstall $pkg."; $script:FailedFonts.Add($id) }
            continue
        }
        $removed = $false; $marker = Join-Path $markerDir $id
        if (Test-Path $marker) { Remove-Item -Path $marker -Force -ErrorAction SilentlyContinue; $removed = $true }
        if (Test-Path $fontDir) {
            $files = @(Get-ChildItem -Path $fontDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.ToLowerInvariant() -like "${id}*nerdfont*" })
            foreach ($f in $files) { Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue; $removed = $true }
        }
        if ($removed) { Write-NfSuccess "Successfully uninstalled $id." }
        else { Write-NfWarn "Nothing to remove for $id; marking as failed."; $script:FailedFonts.Add($id) }
    }
}

function Select-NfItemsInteractive {
    param([string[]]$Items, [string]$PromptTitle)
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) { return ($Items | Out-GridView -Title $PromptTitle -OutputMode Multiple) }
    Write-Host $PromptTitle
    $Items | ForEach-Object { Write-Host " - $_" }
    $sel = Read-Host "Digite os nomes das fontes separados por vírgula"
    return ($sel -split '\s*,\s*' | Where-Object { $_ })
}

function Show-NfUsage {
    Write-Host @"
Usage: install.ps1 [-All | -Fonts "a,b"] [-List] [-Installed] [-Uninstall] [-Backend auto|winget|direct] [-DryRun] [-Quiet] [-NoColor] [-Version] [-Help]

Actions:
  (default)                    Interactive console multi-select installation.
  -All                         Install all available Nerd Fonts.
  -Fonts "a,b"                 Install named fonts (canonical ids, e.g. firacode, hack).
  -List / -Installed           Print available or installed Nerd Fonts and exit.
  -Uninstall / -UninstallAll   Uninstall fonts (interactive, with -Fonts, or all).

Options:
  -Backend auto|winget|direct  Installation backend (default: auto).
  -DryRun / -Quiet / -NoColor  Simulation, silence, or plain text mode.
  -Version / -Help             Print version or this help message and exit.
"@
}

function Invoke-NfMain {
    try { Assert-NfValidOptions } catch { Write-NfError $_.Exception.Message; exit 1 }
    if ($Version) { Write-Output "nerdfonts-installer $($script:NFVersion)"; exit 0 }
    if ($Help) { Show-NfUsage; exit 0 }

    $script:ResolvedBackend = Resolve-NfBackend -Req $Backend.Trim().ToLowerInvariant()
    if ($List) { $script:KnownFonts | ForEach-Object { Write-Output $_ }; exit 0 }
    if ($Installed) {
        $inst = Get-NfInstalledFonts
        if (@($inst).Count -eq 0) { Write-NfWarn 'No Nerd Fonts are currently installed.'; exit 0 }
        $inst | ForEach-Object { Write-Output $_ }
        exit 0
    }

    $isUn = [bool]($Uninstall -or $UninstallAll)
    $pool = if ($isUn) { Get-NfInstalledFonts } else { $script:KnownFonts }
    $targets = @()

    if ($UninstallAll -or $All) {
        if ($isUn -and @($pool).Count -eq 0) { Write-NfWarn 'No Nerd Fonts are currently installed. Nothing to uninstall.'; exit 0 }
        $targets = $pool
    } elseif ($PSBoundParameters.ContainsKey('Fonts')) {
        $req = $Fonts -split '\s*,\s*' | Where-Object { $_ }
        $targets = @($req | Where-Object { $pool -contains $_ })
        foreach ($f in $req) { if ($pool -notcontains $f) { Write-NfWarn "'$f' is $(if ($isUn) { 'not installed' } else { 'unknown' }). Skipping." } }
        if ($targets.Count -eq 0) { Exit-Nf 3 "None of the requested fonts are $(if ($isUn) { 'installed. Run with -Installed to see what is present.' } else { 'available. Run with -List to see the valid names.' })" }
    } else {
        if ($isUn -and @($pool).Count -eq 0) { Write-NfWarn 'No Nerd Fonts are currently installed. Nothing to uninstall.'; exit 0 }
        $title = if ($isUn) { 'Select the Nerd Fonts you want to uninstall:' } else { 'Select the Nerd Fonts you want to install:' }
        $targets = @(Select-NfItemsInteractive -Items $pool -PromptTitle $title)
    }

    if ($targets.Count -gt 0) {
        Write-NfStep "$(if ($isUn) { 'Uninstalling' } else { 'Installing' }) fonts..."
        if ($isUn) { Uninstall-NfFonts -Ids $targets } else { Install-NfFonts -Ids $targets }
    }
    if ($script:FailedFonts.Count -gt 0) { Exit-Nf 4 "Some fonts failed to $(if ($isUn) { 'uninstall' } else { 'install' }) ($($script:FailedFonts -join ', '))." }
    exit 0
}

Invoke-NfMain
