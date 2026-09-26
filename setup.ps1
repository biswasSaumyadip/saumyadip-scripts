#Requires -Version 7.0
<#
.SYNOPSIS
    Production Windows developer-terminal bootstrap (Scoop, modules, runtimes, profile).
.DESCRIPTION
    Idempotent, modular installer for any Windows machine. Safe to re-run.
    Auto-elevates via UAC when not already administrator. Copies the profile
    (every Show-Commands function) and Oh My Posh themes onto this machine
    under %LOCALAPPDATA%\dev-terminal and the pwsh $PROFILE path. After a
    successful run you can delete this installer folder — pwsh does not
    need it. Optional stacks are gated by switches. Windows Terminal
    settings are JSON-merged (never blindly overwritten). Neovim is
    bootstrapped with lazy.nvim and a seed keymaps.lua that is never overwritten.
.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -SkipJavaStack -SkipCloudTools -PasswordManager none
.EXAMPLE
    .\setup.ps1 -SkipAutoUpdateTask -SkipElevation
#>
[CmdletBinding()]
param(
    [switch]$SkipElevation,
    [switch]$SkipCoreTools,
    [switch]$SkipNvimBootstrap,
    [switch]$SkipCppStack,
    [switch]$SkipJavaStack,
    [switch]$SkipNodeStack,
    [switch]$SkipCloudTools,
    [switch]$SkipK8sTools,
    [switch]$SkipDbTools,
    [switch]$SkipContainers,
    [switch]$SkipSecrets,
    [switch]$SkipPasswordManager,
    [ValidateSet('1password-cli', 'bitwarden-cli', 'none')]
    [string]$PasswordManager = '1password-cli',
    [switch]$SkipAutoUpdateTask,
    [string]$AutoUpdateTaskName = 'DevTerminal-Update-AllTheThings',
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$AutoUpdateDay = 'Sunday',
    [string]$AutoUpdateTime = '03:00',
    [switch]$SkipWindowsTerminal,
    [switch]$SkipProfileInstall,
    [switch]$SkipGitConfig,
    [string]$ScoopRoot = $(if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }),
    [ValidateSet(
        'One Half Dark', 'One Half Light', 'Campbell', 'Campbell Powershell',
        'Vintage', 'Solarized Dark', 'Solarized Light', 'Tango Dark', 'Tango Light'
    )]
    [string]$ColorScheme = 'One Half Dark',
    [string]$NerdFontFace = 'JetBrainsMono NF',
    [string]$NerdFontPackage = 'JetBrainsMono-NF'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -----------------------------------------------------------------------------
# Script-level constants (shared with the profile via NVIM_KEYMAPS_PATH)
# -----------------------------------------------------------------------------
New-Variable -Name NvimKeymapsPath -Scope Script -Option Constant -Force -Value (
    Join-Path $env:LOCALAPPDATA 'nvim\lua\config\keymaps.lua'
)
New-Variable -Name DevTerminalDir -Scope Script -Option Constant -Force -Value (
    Join-Path $env:LOCALAPPDATA 'dev-terminal'
)
New-Variable -Name UpdateWrapperPath -Scope Script -Option Constant -Force -Value (
    Join-Path $script:DevTerminalDir 'Update-AllTheThings.ps1'
)
New-Variable -Name PoshThemePath -Scope Script -Option Constant -Force -Value (
    Join-Path $script:DevTerminalDir 'dev-terminal.omp.json'
)
New-Variable -Name PoshThemeAsciiPath -Scope Script -Option Constant -Force -Value (
    Join-Path $script:DevTerminalDir 'dev-terminal-ascii.omp.json'
)
New-Variable -Name SystemProfilePath -Scope Script -Option Constant -Force -Value (
    Join-Path $script:DevTerminalDir 'Microsoft.PowerShell_profile.ps1'
)

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:InstalledProfilePath = $null
$script:InstalledProfilePaths = [System.Collections.Generic.List[string]]::new()
$script:StartedAt = Get-Date

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
    $script:Results.Add([pscustomobject]@{ Status = 'OK'; Message = $Message })
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  [SKIP] $Message" -ForegroundColor DarkYellow
    $script:Results.Add([pscustomobject]@{ Status = 'SKIP'; Message = $Message })
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    $script:Results.Add([pscustomobject]@{ Status = 'FAIL'; Message = $Message })
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HasCommand {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-PwshPath {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $guess = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $guess) { return $guess }
    return 'powershell.exe'
}

function Get-PwshProfileDirs {
    $dirs = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $candidates = @(
        $(if ($PROFILE) { Split-Path -Parent $PROFILE } else { $null })
        $(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell')
        $(Join-Path $env:USERPROFILE 'Documents\PowerShell')
    )
    foreach ($dir in $candidates) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $full = [IO.Path]::GetFullPath($dir)
        if ($seen.Add($full)) { [void]$dirs.Add($full) }
    }
    return $dirs
}

function Copy-InstalledFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Backup
    )
    $destDir = Split-Path -Parent $Destination
    if ($destDir) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    if ($Backup -and (Test-Path -LiteralPath $Destination)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Destination -Destination "$Destination.bak-$stamp" -Force
        Write-Ok "Backed up: $Destination.bak-$stamp"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Ok "Installed -> $Destination"
}

# -----------------------------------------------------------------------------
# Auto-elevation (same-user UAC). Scoop root stays $env:USERPROFILE\scoop.
# -----------------------------------------------------------------------------
if (-not $SkipElevation -and -not (Test-IsAdministrator)) {
    Write-Host 'Administrator rights required for scheduled tasks / fonts. Requesting UAC elevation...' -ForegroundColor Yellow
    $argList = [System.Collections.Generic.List[string]]::new()
    [void]$argList.Add('-NoProfile')
    [void]$argList.Add('-ExecutionPolicy')
    [void]$argList.Add('Bypass')
    [void]$argList.Add('-File')
    [void]$argList.Add($PSCommandPath)
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'SkipElevation') { continue }
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { [void]$argList.Add("-$($entry.Key)") }
        }
        else {
            [void]$argList.Add("-$($entry.Key)")
            [void]$argList.Add([string]$entry.Value)
        }
    }
    $proc = Start-Process -FilePath (Get-PwshPath) -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $(if ($null -ne $proc) { $proc.ExitCode } else { 1 })
}

# -----------------------------------------------------------------------------
# PATH / Scoop root (must happen before any scoop invocation)
# -----------------------------------------------------------------------------
$env:SCOOP = $ScoopRoot
[Environment]::SetEnvironmentVariable('SCOOP', $ScoopRoot, 'User')
$script:ScoopShims = Join-Path $ScoopRoot 'shims'
if (Test-Path -LiteralPath $script:ScoopShims) {
    if (-not ($env:PATH.Split(';') -contains $script:ScoopShims)) {
        $env:PATH = "$script:ScoopShims;$env:PATH"
    }
}

function Invoke-External {
    <#
    .SYNOPSIS
        Run a native command without letting native stderr abort the script.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList
        if ($null -eq $LASTEXITCODE) { return 0 }
        return $LASTEXITCODE
    }
    catch {
        Write-Host "  !! ${FilePath}: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return 1
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Test-IsIgnorableScoopError {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return [bool]($Message -match @(
            'being used by another process'
            'Access to the path .+ is denied'
            'already installed'
            'was already installed'
            'already exists'
            'cannot overwrite'
        ) -join '|')
}

function Test-WindowsNerdFontInstalled {
    param(
        [string]$FaceName = $NerdFontFace,
        [string]$FilePattern = 'JetBrainsMono*NerdFont*.ttf'
    )
    $fontDirs = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'),
        (Join-Path $env:WINDIR 'Fonts')
    )
    foreach ($dir in $fontDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $hits = @(Get-ChildItem -LiteralPath $dir -Filter $FilePattern -File -ErrorAction SilentlyContinue)
        if ($hits.Count -gt 0) { return $true }
    }

    $regKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )
    foreach ($key in $regKeys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        try {
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                $name = [string]$prop.Name
                $value = [string]$prop.Value
                if ($name -match 'JetBrainsMono' -or $name -match [regex]::Escape($FaceName) -or $value -match 'JetBrainsMono') {
                    return $true
                }
            }
        }
        catch {
            # Registry read is best-effort; file-system check above is authoritative.
        }
    }
    return $false
}

function Invoke-ScoopInstall {
    param([Parameter(Mandatory)][string]$Package)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ignored = 0
    try {
        $output = & scoop install $Package 2>&1
        foreach ($item in @($output)) {
            $text = if ($null -eq $item) { '' }
            elseif ($item -is [System.Management.Automation.ErrorRecord]) { $item.ToString() }
            else { [string]$item }
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if (Test-IsIgnorableScoopError $text) {
                $ignored++
                continue
            }
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                Write-Host "  !! $text" -ForegroundColor DarkYellow
            }
            else {
                Write-Host "  $text" -ForegroundColor DarkGray
            }
        }
        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        return [pscustomobject]@{ ExitCode = $code; IgnoredErrorCount = $ignored }
    }
    catch {
        $msg = $_.Exception.Message
        if (Test-IsIgnorableScoopError $msg) {
            return [pscustomobject]@{ ExitCode = 0; IgnoredErrorCount = 1 }
        }
        Write-Host "  !! $msg" -ForegroundColor DarkYellow
        return [pscustomobject]@{ ExitCode = 1; IgnoredErrorCount = $ignored }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Test-ScoopApp {
    param([Parameter(Mandatory)][string]$Name)
    $leaf = ($Name -split '/')[-1]
    $appDir = Join-Path $ScoopRoot "apps\$leaf"
    return (Test-Path -LiteralPath $appDir)
}

function Install-ScoopPackage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Fallback = @()
    )
    $candidates = @($Name) + @($Fallback)
    foreach ($pkg in $candidates) {
        try {
            $leaf = ($pkg -split '/')[-1]
            if (Test-ScoopApp $pkg) {
                Write-Skip "Already installed: $leaf"
                return $true
            }
            Write-Host "  -> scoop install $pkg" -ForegroundColor DarkGray
            $result = Invoke-ScoopInstall -Package $pkg
            if ($result.ExitCode -eq 0 -or (Test-ScoopApp $pkg)) {
                if ($result.IgnoredErrorCount -gt 0) {
                    Write-Skip "Installed $leaf (ignored $($result.IgnoredErrorCount) in-use/access-denied file error(s))"
                }
                else {
                    Write-Ok "Installed $leaf"
                }
                return $true
            }
            Write-Host "  !! candidate failed: $pkg (exit $($result.ExitCode))" -ForegroundColor DarkYellow
        }
        catch {
            $leaf = ($pkg -split '/')[-1]
            if (Test-ScoopApp $pkg) {
                Write-Skip "Installer threw but $leaf is present: $($_.Exception.Message)"
                return $true
            }
            Write-Host "  !! ${pkg}: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    Write-Fail "Could not install $($candidates -join ' | ')"
    return $false
}

function Get-NerdFontTtfFiles {
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'),
        (Join-Path $ScoopRoot "apps\$NerdFontPackage\current"),
        (Join-Path $ScoopRoot 'apps\JetBrainsMono-NF\current'),
        (Join-Path $ScoopRoot 'apps\JetBrainsMono-NF-Mono\current')
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Recurse -Filter 'JetBrainsMono*NerdFont*.ttf' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($seen.Add($_.Name)) { [void]$files.Add($_.FullName) }
            }
    }
    return @($files)
}

function Test-NerdFontMachineInstalled {
    $dir = Join-Path $env:WINDIR 'Fonts'
    $hits = @(Get-ChildItem -LiteralPath $dir -Filter 'JetBrainsMono*NerdFont*.ttf' -File -ErrorAction SilentlyContinue)
    return ($hits.Count -gt 0)
}

function Install-NerdFontMachineWide {
    <#
    .SYNOPSIS
        Copy JetBrainsMono NF into C:\Windows\Fonts so elevated processes can see it.
    .DESCRIPTION
        Windows does not expose per-user fonts (LocalAppData\Microsoft\Windows\Fonts)
        to Administrator tokens. Elevated Windows Terminal / pwsh then fall back to
        Consolas/Cascadia and Nerd Font icons render as tofu.
    #>
    if (-not (Test-IsAdministrator)) {
        Write-Skip 'Not elevated; cannot publish Nerd Font to C:\Windows\Fonts (admin sessions will show broken icons)'
        return
    }
    if (Test-NerdFontMachineInstalled) {
        Write-Skip 'JetBrainsMono Nerd Font already in C:\Windows\Fonts (visible when elevated)'
        return
    }

    $sources = @(Get-NerdFontTtfFiles)
    if ($sources.Count -eq 0) {
        Write-Skip 'No JetBrainsMono Nerd Font TTF sources found for a machine-wide copy'
        return
    }

    $destDir = Join-Path $env:WINDIR 'Fonts'
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $copied = 0
    foreach ($src in $sources) {
        $leaf = [IO.Path]::GetFileName($src)
        $dest = Join-Path $destDir $leaf
        try {
            if (-not (Test-Path -LiteralPath $dest)) {
                Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
            }
            $display = ('{0} (TrueType)' -f ([IO.Path]::GetFileNameWithoutExtension($leaf)))
            New-ItemProperty -Path $reg -Name $display -Value $leaf -PropertyType String -Force | Out-Null
            $copied++
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'being used by another process|Access to the path') {
                Write-Host "  !! $leaf locked; close Terminal/Cursor and re-run to finish the system font copy" -ForegroundColor DarkYellow
            }
            else {
                Write-Host "  !! system font ${leaf}: $msg" -ForegroundColor DarkYellow
            }
        }
    }

    if ($copied -gt 0) {
        Write-Ok "Published $copied Nerd Font file(s) to C:\Windows\Fonts so elevated sessions can use $NerdFontFace"
    }
    elseif (-not (Test-NerdFontMachineInstalled)) {
        Write-Fail 'Could not copy Nerd Font into C:\Windows\Fonts. Close apps using the font and re-run setup elevated.'
    }
}

function Install-NerdFontSafe {
    Write-Step "Nerd Font ($NerdFontFace)"
    try {
        if (Test-WindowsNerdFontInstalled) {
            Write-Skip "$NerdFontFace already present under Windows Fonts; skipping scoop copy (files are often locked by Terminal/Cursor)."
        }
        elseif (Test-ScoopApp $NerdFontPackage) {
            Write-Skip "Scoop package already installed: $NerdFontPackage"
        }
        else {
            $installed = $false
            $candidates = @("nerd-fonts/$NerdFontPackage", $NerdFontPackage, 'nerd-fonts/JetBrainsMono-NF-Mono')
            foreach ($pkg in $candidates) {
                Write-Host "  -> scoop install $pkg" -ForegroundColor DarkGray
                $result = Invoke-ScoopInstall -Package $pkg
                if (Test-WindowsNerdFontInstalled -or (Test-ScoopApp $pkg) -or $result.ExitCode -eq 0) {
                    if ($result.IgnoredErrorCount -gt 0) {
                        Write-Skip "$NerdFontFace available; ignored $($result.IgnoredErrorCount) locked/denied font copy error(s)"
                    }
                    else {
                        Write-Ok "Installed $NerdFontPackage"
                    }
                    $installed = $true
                    break
                }
            }
            if (-not $installed -and -not (Test-WindowsNerdFontInstalled)) {
                Write-Fail "Could not install $NerdFontPackage. Close Windows Terminal, Cursor, or VS Code (they lock the TTF files) and re-run."
                return $false
            }
        }

        # User-scope fonts are invisible to elevated pwsh/WT. Always try HKLM.
        Install-NerdFontMachineWide
        return $true
    }
    catch {
        if (Test-WindowsNerdFontInstalled) {
            Write-Skip "Font installer threw but $NerdFontFace is already registered: $($_.Exception.Message)"
            try { Install-NerdFontMachineWide } catch { }
            return $true
        }
        Write-Fail "Nerd Font install: $($_.Exception.Message)"
        return $false
    }
}

function Install-ScoopGroup {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Packages
    )
    Write-Step $Label
    foreach ($pkg in $Packages) {
        [void](Install-ScoopPackage -Name $pkg)
    }
}

function Add-ScoopBucketSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Url
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $listed = scoop bucket list 2>$null
        $names = @($listed | ForEach-Object {
                if ($_ -is [string]) { ($_ -split '\s+')[0] }
                elseif ($_.PSObject.Properties['Name']) { $_.Name }
                else { "$_" }
            })
        if ($names -contains $Name) {
            Write-Skip "Bucket already present: $Name"
            return
        }
        $args = @('bucket', 'add', $Name)
        if ($Url) { $args += $Url }
        $code = Invoke-External -FilePath 'scoop' -ArgumentList $args
        if ($code -eq 0) { Write-Ok "Added bucket $Name" }
        else { Write-Fail "Failed to add bucket $Name (exit $code)" }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'already exists') { Write-Skip "Bucket already present: $Name" }
        else { Write-Fail "Bucket ${Name}: $msg" }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function ConvertFrom-JsonRelaxed {
    param([Parameter(Mandatory)][string]$Text)
    try {
        return ($Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    }
    catch {
        $stripped = [regex]::Replace($Text, '/\*[\s\S]*?\*/', '')
        $stripped = [regex]::Replace($stripped, '(?m)^\s*//.*$', '')
        $stripped = [regex]::Replace($stripped, ',(\s*[}\]])', '$1')
        return ($stripped | ConvertFrom-Json -AsHashtable)
    }
}

# =============================================================================
# 1. Core infrastructure — Scoop, gsudo, buckets, Nerd Font
# =============================================================================
function Install-ScoopCore {
    Write-Step 'Scoop + gsudo + buckets'

    if (-not (Test-HasCommand 'scoop')) {
        Write-Host '  -> Installing Scoop (https://get.scoop.sh)' -ForegroundColor DarkGray
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        $installer = Invoke-RestMethod -Uri 'https://get.scoop.sh' -TimeoutSec 60
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Invoke-Expression $installer
        }
        finally {
            $ErrorActionPreference = $prev
        }
        if (Test-Path -LiteralPath $script:ScoopShims) {
            $env:PATH = "$script:ScoopShims;$env:PATH"
        }
        if (-not (Test-HasCommand 'scoop')) {
            throw 'Scoop installation finished but scoop is not on PATH. Open a new shell and re-run setup.ps1.'
        }
        Write-Ok "Scoop installed at $ScoopRoot"
    }
    else {
        Write-Skip "Scoop already on PATH"
    }

    $code = Invoke-External -FilePath 'scoop' -ArgumentList @('config', 'root', $ScoopRoot)
    if ($code -eq 0) { Write-Ok "Scoop root = $ScoopRoot" }
    else { Write-Skip "scoop config root returned $code (non-fatal)" }

    # git is required for buckets
    [void](Install-ScoopPackage -Name 'git')

    Add-ScoopBucketSafe -Name 'main'
    Add-ScoopBucketSafe -Name 'extras'
    Add-ScoopBucketSafe -Name 'nerd-fonts'
    Add-ScoopBucketSafe -Name 'versions'
    Add-ScoopBucketSafe -Name 'java'

    [void](Install-ScoopPackage -Name 'gsudo')
    [void](Install-NerdFontSafe)
}

# =============================================================================
# 2. Windows Terminal — locate active settings.json, backup, JSON-merge
# =============================================================================
function Get-WindowsTerminalSettingsPath {
    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    $store = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.WindowsTerminal*_8wekyb3d8bbwe' }

    foreach ($pkg in $store) {
        $settings = Join-Path $pkg.FullName 'LocalState\settings.json'
        if (Test-Path -LiteralPath $settings) {
            [void]$candidates.Add((Get-Item -LiteralPath $settings))
        }
    }

    $unpackaged = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
    if (Test-Path -LiteralPath $unpackaged) {
        [void]$candidates.Add((Get-Item -LiteralPath $unpackaged))
    }

    if ($candidates.Count -eq 0) { return $null }

    # Prefer the most recently written file — that is the "active" instance.
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Get-HashtableValue {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.ContainsKey($Key)) { return $Map[$Key] }
        return $null
    }
    $prop = $Map.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

function Set-HashtableValue {
    param($Map, [string]$Key, $Value)
    if ($Map -is [System.Collections.IDictionary]) {
        $Map[$Key] = $Value
        return
    }
    $Map | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}

function Update-WindowsTerminalSettings {
    if ($SkipWindowsTerminal) {
        Write-Skip 'Windows Terminal configuration opted out'
        return
    }

    Write-Step 'Windows Terminal settings.json merge'
    $path = Get-WindowsTerminalSettingsPath
    if (-not $path) {
        Write-Skip 'Windows Terminal settings.json not found (is Windows Terminal installed and launched once?)'
        return
    }

    Write-Host "  -> Active settings: $path" -ForegroundColor DarkGray
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$path.bak-$stamp"
    Copy-Item -LiteralPath $path -Destination $backup -Force
    Write-Ok "Backup written: $backup"

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $settings = ConvertFrom-JsonRelaxed -Text $raw

    $profiles = Get-HashtableValue $settings 'profiles'
    if ($null -eq $profiles) {
        $profiles = [ordered]@{ defaults = [ordered]@{}; list = @() }
        Set-HashtableValue $settings 'profiles' $profiles
    }

    # Legacy WT format: profiles is a raw array. Promote to { defaults, list }.
    if ($profiles -is [System.Collections.IList]) {
        $profiles = [ordered]@{ defaults = [ordered]@{}; list = @($profiles) }
        Set-HashtableValue $settings 'profiles' $profiles
    }

    $defaults = Get-HashtableValue $profiles 'defaults'
    if ($null -eq $defaults) {
        $defaults = [ordered]@{}
        Set-HashtableValue $profiles 'defaults' $defaults
    }

    $font = Get-HashtableValue $defaults 'font'
    if ($null -eq $font) {
        $font = [ordered]@{}
        Set-HashtableValue $defaults 'font' $font
    }
    Set-HashtableValue $font 'face' $NerdFontFace
    Set-HashtableValue $defaults 'colorScheme' $ColorScheme

    $list = @(Get-HashtableValue $profiles 'list')
    $preferred = $null
    foreach ($entry in $list) {
        $name = [string](Get-HashtableValue $entry 'name')
        $source = [string](Get-HashtableValue $entry 'source')
        if ($source -eq 'Windows.Terminal.PowershellCore') { $preferred = $entry; break }
        if ($name -eq 'PowerShell') { $preferred = $entry }
    }
    if (-not $preferred) {
        foreach ($entry in $list) {
            $name = [string](Get-HashtableValue $entry 'name')
            if ($name -match 'PowerShell' -and $name -notmatch 'Windows PowerShell') {
                $preferred = $entry
                break
            }
        }
    }
    if ($preferred) {
        $guid = Get-HashtableValue $preferred 'guid'
        if ($guid) {
            Set-HashtableValue $settings 'defaultProfile' ([string]$guid)
            $pFont = Get-HashtableValue $preferred 'font'
            if ($null -eq $pFont) {
                $pFont = [ordered]@{}
                Set-HashtableValue $preferred 'font' $pFont
            }
            Set-HashtableValue $pFont 'face' $NerdFontFace
            Set-HashtableValue $preferred 'colorScheme' $ColorScheme
            Write-Ok "Default startup profile: $(Get-HashtableValue $preferred 'name') ($guid)"
        }
    }
    else {
        Write-Skip 'No PowerShell profile GUID found; defaults.font / colorScheme still applied'
    }

    $json = $settings | ConvertTo-Json -Depth 100
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8)
    Write-Ok "Patched font.face='$NerdFontFace', colorScheme='$ColorScheme' (existing keys preserved)"
}

# =============================================================================
# 3. PowerShell modules
# =============================================================================
function Install-PsGalleryModules {
    Write-Step 'PowerShell module ecosystem'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }

        $modules = @('Terminal-Icons', 'posh-git', 'PSFzf')
        foreach ($name in $modules) {
            $existing = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Skip "Module already installed: $name"
                continue
            }
            Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
            Write-Ok "Installed module $name"
        }
    }
    catch {
        Write-Fail "Module install: $($_.Exception.Message)"
    }
}

# =============================================================================
# 4. Neovim bootstrap (lazy.nvim + Java/JS/Python/C++ plugins)
# =============================================================================
function Test-NvimFileManaged {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    return [bool]($raw -match 'managed by setup\.ps1|generated/merged by setup\.ps1')
}

function Copy-NvimManagedTree {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestRoot
    )
    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        Write-Fail "Neovim config source missing: $SourceRoot"
        return
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $files = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction Stop)
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $dest = Join-Path $DestRoot $rel
        $isKeymaps = $rel -replace '\\', '/' -eq 'lua/config/keymaps.lua'
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null

        if ($isKeymaps) {
            if (-not (Test-Path -LiteralPath $dest)) {
                [System.IO.File]::WriteAllText($dest, [System.IO.File]::ReadAllText($file.FullName), $utf8)
                Write-Ok "Seeded keymaps -> $dest"
            }
            else {
                $existing = Get-Content -LiteralPath $dest -Raw -ErrorAction SilentlyContinue
                if ($existing -notmatch 'NvimTreeToggle|<leader>e') {
                    $extras = @'

-- setup.ps1 plugin maps (appended once; edit freely)
local map = vim.keymap.set
map("n", "<leader>e", "<cmd>NvimTreeToggle<CR>", { desc = "File tree" })
map("n", "<leader>o", "<cmd>NvimTreeFindFileToggle<CR>", { desc = "Tree reveal file" })
map("n", "<leader>ff", "<cmd>Telescope find_files<CR>", { desc = "Find files" })
map("n", "<leader>fg", "<cmd>Telescope live_grep<CR>", { desc = "Live grep" })
map("n", "<leader>fb", "<cmd>Telescope buffers<CR>", { desc = "Buffers" })
map("n", "<leader>gg", "<cmd>LazyGit<CR>", { desc = "Lazygit" })
map("n", "<leader>tt", "<cmd>ToggleTerm<CR>", { desc = "Toggle terminal" })
map("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", { desc = "Trouble diagnostics" })
'@
                    Add-Content -LiteralPath $dest -Value $extras -Encoding utf8
                    Write-Ok "Appended plugin keymaps to existing keymaps.lua"
                }
                else {
                    Write-Skip 'Leaving existing keymaps.lua untouched'
                }
            }
            continue
        }

        if ((Test-Path -LiteralPath $dest) -and -not (Test-NvimFileManaged $dest)) {
            Write-Skip "Leaving user-owned nvim file: $rel"
            continue
        }

        [System.IO.File]::WriteAllText($dest, [System.IO.File]::ReadAllText($file.FullName), $utf8)
        Write-Ok "Nvim config -> $rel"
    }
}

function Install-NvimBootstrap {
    if ($SkipNvimBootstrap) {
        Write-Skip 'Neovim bootstrap opted out'
        return
    }
    if (-not (Test-HasCommand 'nvim') -and -not (Test-ScoopApp 'neovim')) {
        Write-Skip 'Neovim not installed; skipping bootstrap'
        return
    }

    Write-Step 'Neovim bootstrap (lazy.nvim + Java/JS/Python/C++ + file tree)'

    if (-not (Test-HasCommand 'python') -and -not (Test-HasCommand 'python3') -and -not (Test-HasCommand 'py')) {
        [void](Install-ScoopPackage -Name 'python')
    }

    $nvimHome = Join-Path $env:LOCALAPPDATA 'nvim'
    New-Item -ItemType Directory -Path (Join-Path $nvimHome 'lua\config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $nvimHome 'lua\plugins') -Force | Out-Null
    Write-Ok "Ensured $nvimHome (lua\config, lua\plugins)"

    $lazyPath = Join-Path $env:LOCALAPPDATA 'nvim-data\lazy\lazy.nvim'
    $lazyInit = Join-Path $lazyPath 'lua\lazy\init.lua'
    if (-not (Test-Path -LiteralPath $lazyInit)) {
        $lazyParent = Split-Path -Parent $lazyPath
        New-Item -ItemType Directory -Path $lazyParent -Force | Out-Null
        if (Test-Path -LiteralPath $lazyPath) {
            Remove-Item -LiteralPath $lazyPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        $code = Invoke-External -FilePath 'git' -ArgumentList @(
            'clone', '--filter=blob:none', '--branch=stable',
            'https://github.com/folke/lazy.nvim.git', $lazyPath
        )
        if ($code -eq 0) { Write-Ok "Cloned lazy.nvim -> $lazyPath" }
        else { Write-Fail "git clone lazy.nvim failed (exit $code)" }
    }
    else {
        Write-Skip 'lazy.nvim already present'
    }

    Copy-NvimManagedTree -SourceRoot (Join-Path $PSScriptRoot 'nvim') -DestRoot $nvimHome

    $initPath = Join-Path $nvimHome 'init.lua'
    if (Test-Path -LiteralPath $initPath) {
        $existing = Get-Content -LiteralPath $initPath -Raw -ErrorAction SilentlyContinue
        if ($existing -notmatch 'config\.options') {
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText(
                $initPath,
                ($existing.TrimEnd() + "`r`npcall(require, `"config.options`")`r`n"),
                $utf8
            )
            Write-Ok 'Appended config.options require to init.lua'
        }
        if ($existing -notmatch 'config\.keymaps') {
            Add-Content -LiteralPath $initPath -Value "`r`npcall(require, `"config.keymaps`")" -Encoding utf8
            Write-Ok 'Appended config.keymaps require to init.lua'
        }
    }

    [Environment]::SetEnvironmentVariable('NVIM_KEYMAPS_PATH', $script:NvimKeymapsPath, 'User')
    $env:NVIM_KEYMAPS_PATH = $script:NvimKeymapsPath
    Write-Ok "User env NVIM_KEYMAPS_PATH = $($script:NvimKeymapsPath)"

    if (Test-HasCommand 'nvim') {
        Write-Step 'Neovim plugin sync (first launch may still download Mason LSPs)'
        $syncCode = Invoke-External -FilePath 'nvim' -ArgumentList @(
            '--headless',
            '+Lazy! sync',
            '+qa'
        )
        if ($syncCode -eq 0) { Write-Ok 'lazy.nvim plugin sync finished' }
        else { Write-Skip "lazy.nvim sync exited $syncCode (plugins install on first nvim launch)" }
    }
}

# =============================================================================
# 5. Optional compiler / editor / runtime stacks
# =============================================================================
function Install-OptionalStacks {
    if (-not $SkipCoreTools) {
        Install-ScoopGroup -Label 'Core tools (git, editors, archiver)' -Packages @(
            'git', 'extras/vscode', 'extras/notepadplusplus', 'neovim', '7zip'
        )
        Install-NvimBootstrap
    }
    else {
        Write-Skip 'Core tools opted out'
    }

    if (-not $SkipCppStack) {
        Install-ScoopGroup -Label 'C++ stack' -Packages @('gcc', 'make', 'cmake')
    }
    else {
        Write-Skip 'C++ stack opted out'
    }

    if (-not $SkipJavaStack) {
        Write-Step 'Java stack (Corretto LTS, Gradle, Maven)'
        [void](Install-ScoopPackage -Name 'java/corretto-lts-jdk' -Fallback @('java/temurin-lts-jdk', 'java/openjdk', 'corretto-lts-jdk', 'temurin-lts-jdk'))
        [void](Install-ScoopPackage -Name 'gradle')
        [void](Install-ScoopPackage -Name 'maven')
    }
    else {
        Write-Skip 'Java stack opted out'
    }

    if (-not $SkipNodeStack) {
        Install-ScoopGroup -Label 'JavaScript / Node stack' -Packages @('fnm', 'pnpm')
    }
    else {
        Write-Skip 'Node stack opted out'
    }
}

# =============================================================================
# 6. Modern Rust CLI + monitors + extras
# =============================================================================
function Install-RustCliStack {
    Install-ScoopGroup -Label 'Modern Rust CLI stack' -Packages @(
        'oh-my-posh', 'zoxide', 'fzf', 'ripgrep', 'fd', 'bat', 'eza',
        'jq', 'yq', 'lazygit'
    )
    Install-ScoopGroup -Label 'System monitors' -Packages @('btop', 'procs', 'dust', 'duf')
    Install-ScoopGroup -Label 'Benchmark / stats extras' -Packages @('hyperfine', 'tokei')
}

# =============================================================================
# 7. Containers, cloud, databases, Kubernetes, IaC
# =============================================================================
function Install-CloudContainerStack {
    if (-not $SkipContainers) {
        Write-Step 'Container TUIs'
        [void](Install-ScoopPackage -Name 'extras/lazydocker' -Fallback @('lazydocker'))
    }
    else {
        Write-Skip 'Container tools opted out'
    }

    if (-not $SkipDbTools) {
        Write-Step 'Database CLI utilities'
        [void](Install-ScoopPackage -Name 'redis')
        [void](Install-ScoopPackage -Name 'mysql' -Fallback @('mariadb'))
    }
    else {
        Write-Skip 'Database tools opted out'
    }

    if (-not $SkipCloudTools) {
        Write-Step 'Cloud CLIs'
        [void](Install-ScoopPackage -Name 'aws' -Fallback @('aws-cli'))
        [void](Install-ScoopPackage -Name 'azure-cli')
        [void](Install-ScoopPackage -Name 'gcloud' -Fallback @('extras/gcloud', 'google-cloud-sdk'))
    }
    else {
        Write-Skip 'Cloud CLIs opted out'
    }

    if (-not $SkipK8sTools) {
        Install-ScoopGroup -Label 'Kubernetes + IaC' -Packages @('kubectl', 'helm', 'k9s', 'terraform')
    }
    else {
        Write-Skip 'Kubernetes / IaC opted out'
    }

    [void](Install-ScoopPackage -Name 'gh')
}

# =============================================================================
# 8. Secrets, env, file-watching, cheatsheets
# =============================================================================
function Install-SecretsAndUtils {
    if (-not $SkipSecrets) {
        Install-ScoopGroup -Label 'Secrets / env / file-watch' -Packages @(
            'age', 'sops', 'direnv', 'watchexec'
        )
    }
    else {
        Write-Skip 'Secrets / env / watchexec opted out'
    }

    $pm = $PasswordManager
    if ($SkipPasswordManager -or $pm -eq 'none') {
        Write-Skip 'Password-manager CLI opted out'
    }
    else {
        Write-Step "Password-manager CLI ($pm)"
        [void](Install-ScoopPackage -Name $pm -Fallback @("extras/$pm"))
    }

    Install-ScoopGroup -Label 'Cheatsheets + task runner' -Packages @('tldr', 'just')
}

# =============================================================================
# 9. Git automations (delta + sane defaults)
# =============================================================================
function Set-GitDeltaAndDefaults {
    if ($SkipGitConfig) {
        Write-Skip 'Git configuration opted out'
        return
    }
    if (-not (Test-HasCommand 'git')) {
        Write-Skip 'git not on PATH; cannot configure'
        return
    }

    Write-Step 'Git automations (delta, defaults)'
    [void](Install-ScoopPackage -Name 'delta')

    $configs = [ordered]@{
        'init.defaultBranch'          = 'main'
        'core.autocrlf'               = 'input'
        'core.pager'                  = 'delta'
        'interactive.diffFilter'      = 'delta --color-only'
        'delta.navigate'              = 'true'
        'delta.light'                 = 'false'
        'delta.side-by-side'          = 'false'
        'delta.line-numbers'          = 'true'
        'merge.conflictstyle'         = 'zdiff3'
        'diff.colorMoved'             = 'default'
        'pager.diff'                  = 'delta'
        'pager.log'                   = 'delta'
        'pager.show'                  = 'delta'
    }

    foreach ($key in $configs.Keys) {
        $code = Invoke-External -FilePath 'git' -ArgumentList @('config', '--global', $key, $configs[$key])
        if ($code -eq 0) { Write-Ok "git config --global $key = $($configs[$key])" }
        else { Write-Fail "git config $key failed (exit $code)" }
    }
}

# =============================================================================
# 10. Native tab-completion for the current setup session
# =============================================================================
function Register-NativeCompletions {
    Write-Step 'Native tab-completion (current session; profile re-registers on load)'

    if (Get-Module -ListAvailable -Name posh-git -ErrorAction SilentlyContinue) {
        Import-Module posh-git -ErrorAction SilentlyContinue
        Write-Ok 'posh-git imported (git completion)'
    }
    else {
        Write-Skip 'posh-git not available'
    }

    $generators = @(
        @{ Name = 'docker';  Script = { docker completion powershell } }
        @{ Name = 'kubectl'; Script = { kubectl completion powershell } }
        @{ Name = 'gh';      Script = { gh completion -s powershell } }
    )

    foreach ($g in $generators) {
        if (-not (Test-HasCommand $g.Name)) {
            Write-Skip "$($g.Name) not installed; completion skipped"
            continue
        }
        try {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $scriptText = & $g.Script 2>$null
            $ErrorActionPreference = $prev
            if ($scriptText) {
                Invoke-Expression $scriptText
                Write-Ok "Registered $($g.Name) tab-completion (this session)"
            }
            else {
                Write-Skip "$($g.Name) produced no completion script"
            }
        }
        catch {
            Write-Skip "$($g.Name) completion: $($_.Exception.Message)"
        }
    }
}

# =============================================================================
# 11. Install / refresh the PowerShell profile
# =============================================================================
function Install-DevProfile {
    if ($SkipProfileInstall) {
        Write-Skip 'Profile install opted out — leave the installer folder on disk; functions will not be copied to this machine'
        return
    }

    Write-Step 'PowerShell profile (copy functions onto this machine)'
    $source = Join-Path $PSScriptRoot 'Microsoft.PowerShell_profile.ps1'
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Fail "Profile source missing: $source"
        return
    }

    New-Item -ItemType Directory -Path $script:DevTerminalDir -Force | Out-Null
    Copy-InstalledFile -Source $source -Destination $script:SystemProfilePath -Backup
    [void]$script:InstalledProfilePaths.Add($script:SystemProfilePath)
    [Environment]::SetEnvironmentVariable('DEVTERMINAL_PROFILE', $script:SystemProfilePath, 'User')
    $env:DEVTERMINAL_PROFILE = $script:SystemProfilePath
    Write-Ok "User env DEVTERMINAL_PROFILE = $($script:SystemProfilePath)"

    foreach ($dir in Get-PwshProfileDirs) {
        $dest = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
        Copy-InstalledFile -Source $source -Destination $dest -Backup
        if (-not ($script:InstalledProfilePaths -contains $dest)) {
            [void]$script:InstalledProfilePaths.Add($dest)
        }
        $script:InstalledProfilePath = $dest
    }
    if ($PROFILE -and (Test-Path -LiteralPath $PROFILE)) {
        $script:InstalledProfilePath = $PROFILE
    }
    elseif (-not $script:InstalledProfilePath) {
        $script:InstalledProfilePath = $script:SystemProfilePath
    }

    $legacyRoots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in Get-PwshProfileDirs) {
        $parent = Split-Path -Parent $dir
        if ($parent) { [void]$legacyRoots.Add($parent) }
    }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ($docs) { [void]$legacyRoots.Add($docs) }

    foreach ($root in $legacyRoots) {
        $legacyDir = Join-Path $root 'WindowsPowerShell'
        $legacy = Join-Path $legacyDir 'Microsoft.PowerShell_profile.ps1'
        try {
            New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
            if (Test-Path -LiteralPath $legacy) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                Copy-Item -LiteralPath $legacy -Destination "$legacy.bak-$stamp" -Force
            }
            $sysEsc = $script:SystemProfilePath
            $stub = @"
# ASCII stub for Windows PowerShell 5.1. Do not paste the pwsh profile here.
# Functions live on this machine at:
#   $sysEsc
#   Documents\PowerShell\Microsoft.PowerShell_profile.ps1
if (`$PSVersionTable.PSVersion.Major -lt 7) {
    `$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    Write-Host 'Dev profile requires PowerShell 7. This host is Windows PowerShell 5.1.' -ForegroundColor Yellow
    if (`$pwsh) {
        Write-Host ("Start pwsh: {0}" -f `$pwsh.Source) -ForegroundColor Yellow
    }
    else {
        Write-Host 'Install: winget install Microsoft.PowerShell' -ForegroundColor Yellow
    }
}
"@
            Set-Content -LiteralPath $legacy -Value $stub -Encoding Ascii
            Write-Ok "Installed Windows PowerShell 5.1 stub -> $legacy"
        }
        catch {
            Write-Skip "5.1 profile stub skipped ($legacy): $($_.Exception.Message)"
        }
    }
}

# =============================================================================
# 11b. Oh My Posh theme with right-prompt RAM utilization
# =============================================================================
function Publish-OhMyPoshThemesFromInstalledProfile {
    $sys = $script:SystemProfilePath
    if (-not (Test-Path -LiteralPath $sys)) { $sys = $script:InstalledProfilePath }
    if (-not $sys -or -not (Test-Path -LiteralPath $sys)) {
        Write-Fail 'No installed profile to generate Oh My Posh themes from'
        return $false
    }

    New-Item -ItemType Directory -Path $script:DevTerminalDir -Force | Out-Null
    $sysEsc = $sys.Replace("'", "''")
    $code = @"
`$ErrorActionPreference = 'Stop'
`$env:DEVPROFILE_NONINTERACTIVE = '1'
. '$sysEsc'
`$null = _Ensure-OhMyPoshRamTheme
`$null = _Ensure-OhMyPoshRamTheme -NoNerdFont
"@
    $codePath = Join-Path $script:DevTerminalDir '_gen-posh-theme.ps1'
    Set-Content -LiteralPath $codePath -Value $code -Encoding utf8
    try {
        $exit = Invoke-External -FilePath (Get-PwshPath) -ArgumentList @('-NoProfile', '-File', $codePath)
        if ($exit -ne 0) {
            Write-Fail "Theme generate failed (exit $exit)"
            return $false
        }
        Write-Ok 'Generated Oh My Posh themes from the installed profile'
        return $true
    }
    finally {
        Remove-Item -LiteralPath $codePath -Force -ErrorAction SilentlyContinue
    }
}

function Install-OhMyPoshTheme {
    Write-Step 'Oh My Posh theme (system copy, right-prompt RAM)'
    $names = @('dev-terminal.omp.json', 'dev-terminal-ascii.omp.json')
    $srcDir = Join-Path $PSScriptRoot 'themes'
    $haveSource = $true
    foreach ($name in $names) {
        if (-not (Test-Path -LiteralPath (Join-Path $srcDir $name))) {
            $haveSource = $false
            break
        }
    }

    $destDirs = [System.Collections.Generic.List[string]]::new()
    [void]$destDirs.Add($script:DevTerminalDir)
    foreach ($dir in Get-PwshProfileDirs) {
        [void]$destDirs.Add((Join-Path $dir 'themes'))
    }

    if ($haveSource) {
        foreach ($dir in $destDirs) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            foreach ($name in $names) {
                Copy-InstalledFile -Source (Join-Path $srcDir $name) -Destination (Join-Path $dir $name)
            }
        }
    }
    else {
        Write-Skip 'Installer themes/ folder not present; generating on this machine'
        if (-not (Publish-OhMyPoshThemesFromInstalledProfile)) { return }
        foreach ($dir in $destDirs) {
            if ($dir -eq $script:DevTerminalDir) { continue }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            foreach ($name in $names) {
                $from = Join-Path $script:DevTerminalDir $name
                if (Test-Path -LiteralPath $from) {
                    Copy-InstalledFile -Source $from -Destination (Join-Path $dir $name)
                }
            }
        }
    }

    [Environment]::SetEnvironmentVariable('DEVTERMINAL_POSH_THEME', $script:PoshThemePath, 'User')
    $env:DEVTERMINAL_POSH_THEME = $script:PoshThemePath
    Write-Ok "User env DEVTERMINAL_POSH_THEME = $($script:PoshThemePath)"
}

# =============================================================================
# 12. Weekly scheduled task that runs Update-AllTheThings
# =============================================================================
function Write-UpdateWrapper {
    New-Item -ItemType Directory -Path $script:DevTerminalDir -Force | Out-Null
    $profilePath = $script:SystemProfilePath
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $profilePath = $script:InstalledProfilePath
    }
    if (-not $profilePath) {
        $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }

    $wrapper = @"
# Auto-generated by setup.ps1. Do not edit by hand; re-run setup to refresh.
#Requires -Version 7.0
`$ErrorActionPreference = 'Continue'
`$ProgressPreference = 'SilentlyContinue'
`$env:DEVPROFILE_NONINTERACTIVE = '1'
`$profilePath = '$($profilePath.Replace("'", "''"))'
if (Test-Path -LiteralPath `$profilePath) {
    . `$profilePath
}
if (Get-Command Update-AllTheThings -ErrorAction SilentlyContinue) {
    Update-AllTheThings
    exit `$LASTEXITCODE
}
if (Get-Command scoop -ErrorAction SilentlyContinue) {
    scoop update
    scoop update *
}
Get-InstalledModule -ErrorAction SilentlyContinue | ForEach-Object {
    Update-Module -Name `$_.Name -Force -ErrorAction SilentlyContinue
}
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget upgrade --all --accept-package-agreements --accept-source-agreements --disable-interactivity
}
"@
    Set-Content -LiteralPath $script:UpdateWrapperPath -Value $wrapper -Encoding utf8
    Write-Ok "Update wrapper -> $($script:UpdateWrapperPath)"
}

function Register-AutoUpdateTask {
    if ($SkipAutoUpdateTask) {
        Write-Skip 'Weekly Update-AllTheThings scheduled task opted out'
        return
    }

    Write-Step "Scheduled task '$AutoUpdateTaskName'"
    try {
        Write-UpdateWrapper

        $existing = Get-ScheduledTask -TaskName $AutoUpdateTaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Skip "Task already registered: $AutoUpdateTaskName"
            return
        }

        $timeOfDay = [TimeSpan]::Zero
        if (-not [TimeSpan]::TryParse($AutoUpdateTime, [ref]$timeOfDay)) {
            throw "Invalid -AutoUpdateTime '$AutoUpdateTime'. Use HH:mm or HH:mm:ss (e.g. 03:00)."
        }
        # New-ScheduledTaskTrigger -At requires DateTime, not TimeSpan.
        $at = [DateTime]::Today.Add($timeOfDay)

        $pwsh = Get-PwshPath
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoLogo -NonInteractive -WindowStyle Hidden -File `"$($script:UpdateWrapperPath)`""
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $AutoUpdateDay -At $at
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -Hidden `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask `
            -TaskName $AutoUpdateTaskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description 'Weekly silent Update-AllTheThings (scoop, PowerShell modules, winget)' `
            -Force | Out-Null
        Write-Ok "Registered weekly task $AutoUpdateTaskName ($AutoUpdateDay at $AutoUpdateTime)"
    }
    catch {
        Write-Fail "Scheduled task '$AutoUpdateTaskName': $($_.Exception.Message)"
        Write-Host "  Wrapper is still at $($script:UpdateWrapperPath) — register manually or re-run setup." -ForegroundColor DarkYellow
    }
}

# =============================================================================
# Main
# =============================================================================
function Write-Summary {
    Write-Host ""
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host " setup.ps1 finished in $([int]((Get-Date) - $script:StartedAt).TotalSeconds)s" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    $ok = @($script:Results | Where-Object Status -eq 'OK').Count
    $skip = @($script:Results | Where-Object Status -eq 'SKIP').Count
    $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
    Write-Host "  OK: $ok   SKIP: $skip   FAIL: $fail"
    Write-Host "  Nvim keymaps: $($script:NvimKeymapsPath)"
    Write-Host "  NVIM_KEYMAPS_PATH (User): $([Environment]::GetEnvironmentVariable('NVIM_KEYMAPS_PATH', 'User'))"
    if ($script:InstalledProfilePaths.Count -gt 0) {
        Write-Host '  Profile copies (this machine):'
        foreach ($p in $script:InstalledProfilePaths) {
            Write-Host "    $p"
        }
    }
    elseif ($script:InstalledProfilePath) {
        Write-Host "  Profile: $($script:InstalledProfilePath)"
    }
    if (Test-Path -LiteralPath $script:PoshThemePath) {
        Write-Host "  Oh My Posh theme: $($script:PoshThemePath)"
    }
    if (-not $SkipAutoUpdateTask) {
        Write-Host "  Auto-update task: $AutoUpdateTaskName"
    }
    $fails = @($script:Results | Where-Object Status -eq 'FAIL')
    if ($fails.Count -gt 0) {
        Write-Host ""
        Write-Host 'Failures:' -ForegroundColor Red
        $fails | ForEach-Object { Write-Host "  - $($_.Message)" -ForegroundColor Red }
    }
    Write-Host ""
    if (-not $SkipProfileInstall -and (Test-Path -LiteralPath $script:SystemProfilePath)) {
        Write-Host 'This machine now owns the functions. You can delete the folder you ran setup from.' -ForegroundColor Green
        Write-Host "  System copy: $($script:SystemProfilePath)" -ForegroundColor DarkGray
    }
    Write-Host 'Open a new Windows Terminal tab to load the profile (Show-Commands, Show-WelcomeBanner).' -ForegroundColor Green
}

try {
    Write-Host ""
    Write-Host '  Dev Terminal setup  |  idempotent  |  $ErrorActionPreference = Stop' -ForegroundColor Cyan
    Write-Host "  Scoop root: $ScoopRoot" -ForegroundColor DarkGray
    Write-Host "  Elevated:   $(Test-IsAdministrator)" -ForegroundColor DarkGray
    Write-Host "  Keymaps:    $($script:NvimKeymapsPath)" -ForegroundColor DarkGray

    Install-ScoopCore
    Install-PsGalleryModules
    Install-OptionalStacks
    Install-RustCliStack
    Install-CloudContainerStack
    Install-SecretsAndUtils
    Set-GitDeltaAndDefaults
    Update-WindowsTerminalSettings
    Register-NativeCompletions
    Install-DevProfile
    Install-OhMyPoshTheme
    Register-AutoUpdateTask
    Write-Summary

    $failCount = @($script:Results | Where-Object Status -eq 'FAIL').Count
    if ($failCount -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}
