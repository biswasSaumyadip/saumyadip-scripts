#Requires -Version 7.0
# =============================================================================
# Microsoft.PowerShell_profile.ps1  (PowerShell 7 / pwsh only)
# High-performance developer profile. Every public function lives in THIS file
# so setup.ps1 can copy it onto the machine. After setup you can delete the
# installer folder — pwsh loads the copy under Documents\PowerShell and/or
# %LOCALAPPDATA%\dev-terminal. Functions defined here are owned by
# Show-Commands. Interactive chrome (theme, banner, PSReadLine) is skipped
# when $env:DEVPROFILE_NONINTERACTIVE is set (scheduled Update-AllTheThings).
# Windows PowerShell 5.1 gets a separate ASCII stub from setup.ps1.
# =============================================================================

$script:ProfilePath = $PSCommandPath
$script:ProfileAliases = [ordered]@{}
$script:DeferredDone = $false
$script:DevProfileInteractive = (
    -not $env:DEVPROFILE_NONINTERACTIVE -and
    [Environment]::UserInteractive -and
    $Host.Name -match 'ConsoleHost|Visual Studio Code Host|Visual Studio Code'
)

# Same constant setup.ps1 persists to the User environment. Fallback is the
# well-known Neovim path so the function never re-derives ad hoc.
if ([string]::IsNullOrWhiteSpace($env:NVIM_KEYMAPS_PATH)) {
    $env:NVIM_KEYMAPS_PATH = Join-Path $env:LOCALAPPDATA 'nvim\lua\config\keymaps.lua'
}
New-Variable -Name NvimKeymapsPath -Scope Script -Option None -Force -Value $env:NVIM_KEYMAPS_PATH

if ([string]::IsNullOrWhiteSpace($env:DEVTERMINAL_POSH_THEME)) {
    $env:DEVTERMINAL_POSH_THEME = Join-Path $env:LOCALAPPDATA 'dev-terminal\dev-terminal.omp.json'
}
if ([string]::IsNullOrWhiteSpace($env:DEVTERMINAL_PROFILE)) {
    $env:DEVTERMINAL_PROFILE = Join-Path $env:LOCALAPPDATA 'dev-terminal\Microsoft.PowerShell_profile.ps1'
}

# -----------------------------------------------------------------------------
# Internal helpers (underscore prefix — excluded from Show-Commands)
# -----------------------------------------------------------------------------
function _Test-HasCommand {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function _Remove-AliasIfPresent {
    param([Parameter(Mandatory)][string]$Name)
    if (Test-Path -Path "Alias:$Name") {
        Remove-Item -Path "Alias:$Name" -Force
    }
}

function _Set-ProfileAlias {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Synopsis = ''
    )
    _Remove-AliasIfPresent $Name
    Set-Alias -Name $Name -Value $Value -Scope Global -Force -Option AllScope
    $script:ProfileAliases[$Name] = [pscustomobject]@{
        Name     = $Name
        Value    = "$Value"
        Synopsis = $Synopsis
    }
}

function _Get-SysResourceData {
    param([switch]$Quick)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    $cpuPct = 0
    if ($cpus.Count -gt 0) {
        $cpuPct = [math]::Round((@($cpus | Measure-Object -Property LoadPercentage -Average).Average), 1)
    }
    $totalKb = [double]$os.TotalVisibleMemorySize
    $freeKb = [double]$os.FreePhysicalMemory
    $ramPct = if ($totalKb -gt 0) { [math]::Round((($totalKb - $freeKb) / $totalKb) * 100, 1) } else { 0 }

    $data = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        OS           = $os.Caption.Trim()
        Uptime       = (Get-Date) - $os.LastBootUpTime
        Shell        = "PowerShell $($PSVersionTable.PSVersion)"
        Path         = (Get-Location).Path
        CpuPercent   = $cpuPct
        RamPercent   = $ramPct
        RamUsedGb    = [math]::Round(($totalKb - $freeKb) / 1MB, 2)
        RamTotalGb   = [math]::Round($totalKb / 1MB, 2)
        TopCpu       = @()
        TopRam       = @()
    }

    if (-not $Quick) {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne 0 })
        $data.TopCpu = @(
            $procs | Sort-Object CPU -Descending | Select-Object -First 5 -Property Id, ProcessName, CPU, WorkingSet64
        )
        $data.TopRam = @(
            $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 -Property Id, ProcessName, CPU, WorkingSet64
        )
    }
    return [pscustomobject]$data
}

function _Write-PercentBar {
    param(
        [double]$Percent,
        [int]$Width = 22
    )
    $pct = [math]::Max(0, [math]::Min(100, $Percent))
    $filled = [int][math]::Round($Width * $pct / 100)
    $bar = ('█' * $filled) + ('░' * ($Width - $filled))
    $color = if ($pct -ge 90) { 'Red' } elseif ($pct -ge 70) { 'Yellow' } else { 'Green' }
    Write-Host -NoNewline $bar -ForegroundColor $color
    Write-Host -NoNewline (' {0,5:N1}%' -f $pct)
}

function _Show-JsonPretty {
    param($Text)
    if (_Test-HasCommand 'bat') {
        $Text | bat --paging=never --language json --style=plain --color=always
        return
    }
    Write-Output $Text
}

function _Read-DotEnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $map = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#')) { continue }
        $eq = $trim.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $trim.Substring(0, $eq).Trim()
        $val = $trim.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and (
                ($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))
            )) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $map[$key] = $val
    }
    return $map
}

function _Get-7Zip {
    param([switch]$Required)
    $cmd = Get-Command 7z, 7za, 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    if ($Required) {
        throw '7-Zip is not on PATH. Run setup.ps1 or: scoop install 7zip'
    }
    return $null
}

function _Get-7ZipPasswordArg {
    param($Password)
    if ($null -eq $Password -or $Password -eq '') { return $null }
    if ($Password -is [SecureString]) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { return ('-p' + [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return ('-p' + [string]$Password)
}

function _Invoke-7Zip {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $exe = _Get-7Zip -Required
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $exe @ArgumentList 2>&1
        $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        foreach ($line in @($output)) {
            if ($null -eq $line) { continue }
            Write-Host ("{0}" -f $line)
        }
        return $code
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function _Test-IsElevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function _Test-NerdFontFilesVisible {
    $sys = @(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Fonts') -Filter 'JetBrainsMono*NerdFont*.ttf' -File -ErrorAction SilentlyContinue)
    if ($sys.Count -gt 0) { return $true }
    # Per-user fonts are not loaded by elevated processes.
    if (_Test-IsElevated) { return $false }
    $userDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path -LiteralPath $userDir)) { return $false }
    $user = @(Get-ChildItem -LiteralPath $userDir -Filter 'JetBrainsMono*NerdFont*.ttf' -File -ErrorAction SilentlyContinue)
    return ($user.Count -gt 0)
}

function _Test-UseNerdFont {
    # Classic conhost (pwsh "Run as administrator") ignores WT settings.json and
    # uses Consolas — Nerd glyphs break even if the TTF is installed.
    $hostLikelyHasFont = (
        $env:WT_SESSION -or
        $env:TERM_PROGRAM -eq 'vscode' -or
        $Host.Name -match 'Visual Studio Code'
    )
    return $hostLikelyHasFont -and (_Test-NerdFontFilesVisible)
}

function _New-OhMyPoshRamThemeJson {
    param([switch]$NoNerdFont)
    $ramTemplate = if ($NoNerdFont) {
        'RAM {{ round .PhysicalPercentUsed .Precision }}% '
    }
    else {
        " $($([char]0xE266)) RAM {{ round .PhysicalPercentUsed .Precision }}% "
    }
    $ramSeg = [ordered]@{
        type                 = 'sysinfo'
        style                = $(if ($NoNerdFont) { 'plain' } else { 'diamond' })
        foreground           = $(if ($NoNerdFont) { '#56b6c2' } else { '#282c34' })
        foreground_templates = @(
            '{{ if gt .PhysicalPercentUsed 90 }}#e06c75{{ end }}'
            '{{ if gt .PhysicalPercentUsed 70 }}#e5c07b{{ end }}'
        )
        background           = '#56b6c2'
        background_templates = @(
            '{{ if gt .PhysicalPercentUsed 90 }}#e06c75{{ end }}'
            '{{ if gt .PhysicalPercentUsed 70 }}#e5c07b{{ end }}'
        )
        leading_diamond      = "$([char]0xE0B6)"
        trailing_diamond     = "$([char]0xE0B4)"
        template             = $ramTemplate
        properties           = [ordered]@{ precision = 1 }
        options              = [ordered]@{ precision = 1 }
    }
    if ($NoNerdFont) {
        $ramSeg.Remove('background')
        $ramSeg.Remove('background_templates')
        $ramSeg.Remove('leading_diamond')
        $ramSeg.Remove('trailing_diamond')
    }
    else {
        $ramSeg.Remove('foreground_templates')
    }

    $left = if ($NoNerdFont) {
        @(
            [ordered]@{
                type       = 'path'
                style      = 'plain'
                foreground = '#98c379'
                template   = '{{ .Path }} '
                properties = [ordered]@{ style = 'folder'; home_icon = '~' }
                options    = [ordered]@{ style = 'folder'; home_icon = '~' }
            }
            [ordered]@{
                type       = 'git'
                style      = 'plain'
                foreground = '#c678dd'
                template   = '{{ .HEAD }}{{ if .Working.Changed }}*{{ end }} '
            }
            [ordered]@{
                type                 = 'status'
                style                = 'plain'
                foreground           = '#98c379'
                foreground_templates = @('{{ if gt .Code 0 }}#e06c75{{ end }}')
                template             = '{{ if gt .Code 0 }}x{{ else }}${{ end }} '
                properties           = [ordered]@{ always_enabled = $true }
                options              = [ordered]@{ always_enabled = $true }
            }
        )
    }
    else {
        @(
            [ordered]@{
                type             = 'os'
                style            = 'diamond'
                leading_diamond  = "$([char]0xE0B6)"
                trailing_diamond = "$([char]0xE0B0)"
                foreground       = '#282c34'
                background       = '#61afef'
                template         = ' {{ .Icon }} '
            }
            [ordered]@{
                type             = 'path'
                style            = 'powerline'
                powerline_symbol = "$([char]0xE0B0)"
                foreground       = '#282c34'
                background       = '#98c379'
                template         = ' {{ .Path }} '
                properties       = [ordered]@{ style = 'folder'; home_icon = '~' }
                options          = [ordered]@{ style = 'folder'; home_icon = '~' }
            }
            [ordered]@{
                type                 = 'git'
                style                = 'powerline'
                powerline_symbol     = "$([char]0xE0B0)"
                foreground           = '#282c34'
                background           = '#c678dd'
                background_templates = @('{{ if or (.Working.Changed) (.Staging.Changed) }}#e5c07b{{ end }}')
                template             = ' {{ .HEAD }}{{ if .Working.Changed }} *{{ end }}{{ if .Staging.Changed }} +{{ end }} '
            }
            [ordered]@{
                type                 = 'status'
                style                = 'diamond'
                trailing_diamond     = "$([char]0xE0B4)"
                foreground           = '#ffffff'
                background           = '#98c379'
                background_templates = @('{{ if gt .Code 0 }}#e06c75{{ end }}')
                template             = " {{ if gt .Code 0 }}$([char]0x2718){{ else }}$([char]0x2714){{ end }} "
                properties           = [ordered]@{ always_enabled = $true }
                options              = [ordered]@{ always_enabled = $true }
            }
        )
    }

    $theme = [ordered]@{
        version                 = 3
        final_space             = $true
        console_title_template  = '{{ .Shell }} in {{ .Folder }}'
        blocks                  = @(
            [ordered]@{
                type      = 'prompt'
                alignment = 'left'
                segments  = $left
            }
            [ordered]@{
                type     = 'rprompt'
                overflow = 'hidden'
                segments = @($ramSeg)
            }
        )
    }
    return ($theme | ConvertTo-Json -Depth 20)
}

function _Test-OhMyPoshThemeBroken {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $true }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    if ($raw -match 'sub \.PhysicalTotalMemory|divf \(sub') { return $true }
    if ($raw -notmatch 'PhysicalPercentUsed') { return $true }
    if ($raw -notmatch 'type"\s*:\s*"sysinfo"|"type": "sysinfo"') { return $true }
    return $false
}

function _Ensure-OhMyPoshRamTheme {
    param([switch]$NoNerdFont)
    $name = if ($NoNerdFont) { 'dev-terminal-ascii.omp.json' } else { 'dev-terminal.omp.json' }
    $destDir = Join-Path $env:LOCALAPPDATA 'dev-terminal'
    $dest = Join-Path $destDir $name
    $search = [System.Collections.Generic.List[string]]::new()
    if (-not $NoNerdFont -and $env:DEVTERMINAL_POSH_THEME) {
        [void]$search.Add($env:DEVTERMINAL_POSH_THEME)
    }
    [void]$search.Add($dest)
    [void]$search.Add((Join-Path (Split-Path $script:ProfilePath -Parent) "themes\$name"))
    foreach ($candidate in $search) {
        if ($candidate -and -not (_Test-OhMyPoshThemeBroken $candidate)) { return $candidate }
    }

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $json = _New-OhMyPoshRamThemeJson -NoNerdFont:$NoNerdFont
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($dest, $json, $utf8)
    return $dest
}

function _Get-OhMyPoshTheme {
    param([switch]$NoNerdFont)
    try {
        $custom = _Ensure-OhMyPoshRamTheme -NoNerdFont:$NoNerdFont
        if ($custom) { return $custom }
    }
    catch { }

    $names = if ($NoNerdFont) {
        @('pure.omp.json', 'minimal.omp.json', 'paradox.omp.json')
    }
    else {
        @('jandedobbeleer.omp.json', 'atomic.omp.json', 'paradox.omp.json', 'agnoster.omp.json', 'pure.omp.json')
    }
    $dirs = [System.Collections.Generic.List[string]]::new()
    if ($env:POSH_THEMES_PATH) { [void]$dirs.Add($env:POSH_THEMES_PATH) }
    if (_Test-HasCommand 'scoop') {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $prefix = scoop prefix oh-my-posh 2>$null
            if ($prefix) { [void]$dirs.Add((Join-Path $prefix 'themes')) }
        }
        catch { }
        finally { $ErrorActionPreference = $prev }
    }
    [void]$dirs.Add((Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\themes'))
    foreach ($dir in $dirs) {
        foreach ($name in $names) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        $any = Get-ChildItem -Path $dir -Filter '*.omp.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($any) { return $any.FullName }
    }
    return $null
}

function _Register-CliCompletions {
    if (Get-Module -ListAvailable -Name posh-git -ErrorAction SilentlyContinue) {
        Import-Module posh-git -ErrorAction SilentlyContinue
    }
    $generators = @(
        @{ Name = 'docker';  Get = { docker completion powershell } }
        @{ Name = 'kubectl'; Get = { kubectl completion powershell } }
        @{ Name = 'gh';      Get = { gh completion -s powershell } }
    )
    foreach ($g in $generators) {
        if (-not (_Test-HasCommand $g.Name)) { continue }
        try {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $text = & $g.Get 2>$null
            $ErrorActionPreference = $prev
            if ($text) { Invoke-Expression $text }
        }
        catch { }
    }
}

function Initialize-DevProfileDeferred {
    <#
    .SYNOPSIS
        One-shot deferred import of Terminal-Icons, PSFzf, and CLI completions.
    .DESCRIPTION
        Runs at most once per session. Triggered from PowerShell.OnIdle and
        from the Ctrl+R / Ctrl+T key handlers so first keystroke still works
        if idle has not fired yet. Safe to call repeatedly.
    .EXAMPLE
        Initialize-DevProfileDeferred
    #>
    if ($script:DeferredDone) { return }
    $script:DeferredDone = $true
    if ($script:UseNerdFont) {
        Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    }
    Import-Module PSFzf -ErrorAction SilentlyContinue
    if (Get-Module PSFzf) {
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' -ErrorAction SilentlyContinue
    }
    _Register-CliCompletions
}

# -----------------------------------------------------------------------------
# 1. Shell engine, theming, PSReadLine (interactive only)
# -----------------------------------------------------------------------------
$script:UseNerdFont = _Test-UseNerdFont

if ($script:DevProfileInteractive) {
    if (-not $script:UseNerdFont -and (_Test-IsElevated)) {
        Write-Host 'Nerd Font icons disabled in this elevated session (per-user fonts are invisible to Administrator). Re-run setup.ps1 elevated to copy JetBrainsMono NF into C:\Windows\Fonts, then open an elevated Windows Terminal tab (not conhost).' -ForegroundColor DarkYellow
    }

    if (_Test-HasCommand 'oh-my-posh') {
        try {
            $theme = _Get-OhMyPoshTheme -NoNerdFont:(-not $script:UseNerdFont)
            if ($theme) { oh-my-posh init pwsh --config $theme | Invoke-Expression }
            else { oh-my-posh init pwsh | Invoke-Expression }
        }
        catch { }
    }

    if (_Test-HasCommand 'zoxide') {
        try { Invoke-Expression (& { zoxide init powershell | Out-String }) } catch { }
    }

    if (_Test-HasCommand 'fnm') {
        try { fnm env --use-on-cd | Out-String | Invoke-Expression } catch { }
    }

    if (Get-Module -ListAvailable -Name PSReadLine -ErrorAction SilentlyContinue) {
        Import-Module PSReadLine -ErrorAction SilentlyContinue
        try { Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop }
        catch { Set-PSReadLineOption -PredictionSource History -ErrorAction SilentlyContinue }
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
        Set-PSReadLineOption -EditMode Windows -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineKeyHandler -Key 'Ctrl+r' -BriefDescription 'FzfHistory' -LongDescription 'fzf command history' -ScriptBlock {
            Initialize-DevProfileDeferred
            if (Get-Command Invoke-FzfPsReadlineHandlerHistory -ErrorAction SilentlyContinue) {
                Invoke-FzfPsReadlineHandlerHistory
            }
            elseif (_Test-HasCommand 'fzf') {
                $hist = Get-Content (Get-PSReadLineOption).HistorySavePath -ErrorAction SilentlyContinue
                $pick = $hist | Select-Object -Unique | fzf --tac --no-sort --height 40%
                if ($pick) { [Microsoft.PowerShell.PSConsoleReadLine]::Insert($pick) }
            }
        }
        Set-PSReadLineKeyHandler -Key 'Ctrl+t' -BriefDescription 'FzfFiles' -LongDescription 'PSFzf file search' -ScriptBlock {
            Initialize-DevProfileDeferred
            if (Get-Command Invoke-FzfPsReadlineHandlerProvider -ErrorAction SilentlyContinue) {
                Invoke-FzfPsReadlineHandlerProvider
            }
            elseif (_Test-HasCommand 'fzf') {
                $pick = fzf --height 40%
                if ($pick) { [Microsoft.PowerShell.PSConsoleReadLine]::Insert($pick) }
            }
        }
    }

    Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -SupportEvent -Action {
        Initialize-DevProfileDeferred
    } | Out-Null
}

# =============================================================================
# Public commands
# =============================================================================

function Show-WelcomeBanner {
    <#
    .SYNOPSIS
        Fastfetch-style startup splash (OS, uptime, shell, path, CPU/RAM).
    .DESCRIPTION
        Prints a compact system banner. Reuses _Get-SysResourceData (-Quick)
        so the numbers match Get-SysResource without paying for process lists.
    .EXAMPLE
        Show-WelcomeBanner
    #>
    $d = _Get-SysResourceData -Quick
    $up = '{0}d {1}h {2}m' -f $d.Uptime.Days, $d.Uptime.Hours, $d.Uptime.Minutes
    $title = "$($d.UserName)@$($d.ComputerName)"
    $rows = @(
        @{ K = 'OS';     V = $d.OS }
        @{ K = 'Uptime'; V = $up }
        @{ K = 'Shell';  V = $d.Shell }
        @{ K = 'Path';   V = $d.Path }
        @{ K = 'CPU';    V = ('{0,4:N1}%' -f $d.CpuPercent) }
        @{ K = 'RAM';    V = ('{0,4:N1}%  ({1} / {2} GB)' -f $d.RamPercent, $d.RamUsedGb, $d.RamTotalGb) }
    )
    $inner = 58
    Write-Host ""
    Write-Host ('  ┌' + ('─' * $inner) + '┐') -ForegroundColor Cyan
    Write-Host ('  │ ' + $title.PadRight($inner - 2) + ' │') -ForegroundColor Cyan
    Write-Host ('  ├' + ('─' * $inner) + '┤') -ForegroundColor DarkCyan
    foreach ($row in $rows) {
        $line = '{0,-8} {1}' -f $row.K, $row.V
        if ($line.Length -gt ($inner - 2)) { $line = $line.Substring(0, $inner - 5) + '...' }
        Write-Host '  │ ' -NoNewline -ForegroundColor DarkCyan
        Write-Host $line.PadRight($inner - 2) -NoNewline
        Write-Host ' │' -ForegroundColor DarkCyan
    }
    Write-Host ('  └' + ('─' * $inner) + '┘') -ForegroundColor Cyan
    Write-Host '  Show-Commands  ·  Get-SysResource  ·  Update-AllTheThings' -ForegroundColor DarkGray
    Write-Host ""
}

# -----------------------------------------------------------------------------
# 2. Linux-native parity
# -----------------------------------------------------------------------------
# Built-in aliases win over functions — strip the ones we replace.
@('cat', 'ls') | ForEach-Object { _Remove-AliasIfPresent $_ }

function touch {
    <#
    .SYNOPSIS
        Create a file or refresh its last-write timestamp (Unix touch).
    .DESCRIPTION
        For each path: creates an empty file when missing, otherwise updates
        LastWriteTime to now. Directories are created as needed for the parent.
    .EXAMPLE
        touch README.md, notes.txt
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Path
    )
    foreach ($p in $Path) {
        $parent = Split-Path -Parent $p
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $p) {
            (Get-Item -LiteralPath $p).LastWriteTime = Get-Date
        }
        else {
            New-Item -ItemType File -Path $p | Out-Null
        }
    }
}

function which {
    <#
    .SYNOPSIS
        Resolve a command to its type and source path (Unix which).
    .DESCRIPTION
        Wraps Get-Command -All and prints Name, CommandType, Source, Definition
        so aliases, functions, and native executables are all visible.
    .EXAMPLE
        which git
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    Get-Command -Name $Name -All -ErrorAction Stop |
        Select-Object Name, CommandType, Source, @{ n = 'Definition'; e = { $_.Definition } }
}

function cat {
    <#
    .SYNOPSIS
        Print file contents via bat, falling back to Get-Content.
    .DESCRIPTION
        Uses bat --paging=never when installed so syntax highlighting stays
        inline. Otherwise delegates to Get-Content.
    .EXAMPLE
        cat .\setup.ps1
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'bat') { bat --paging=never @Passthru }
    else { Get-Content @Passthru }
}

function ls {
    <#
    .SYNOPSIS
        List directory entries with eza icons/git, else Get-ChildItem.
    .DESCRIPTION
        Preferred command is eza --icons --git --group-directories-first.
        Any extra arguments are forwarded to eza or Get-ChildItem.
    .EXAMPLE
        ls
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'eza') { eza --icons --git --group-directories-first @Passthru }
    else { Get-ChildItem @Passthru }
}

function ll {
    <#
    .SYNOPSIS
        Long listing (eza -l) with icons and git status.
    .DESCRIPTION
        eza -l --icons --git --group-directories-first, or Get-ChildItem
        formatted as a table when eza is missing.
    .EXAMPLE
        ll
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'eza') { eza -l --icons --git --group-directories-first @Passthru }
    else { Get-ChildItem @Passthru | Format-Table -AutoSize }
}

function la {
    <#
    .SYNOPSIS
        List all entries including hidden (eza -la).
    .DESCRIPTION
        eza -la --icons --git --group-directories-first, or Get-ChildItem
        -Force when eza is missing.
    .EXAMPLE
        la
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'eza') { eza -la --icons --git --group-directories-first @Passthru }
    else { Get-ChildItem -Force @Passthru }
}

function grep {
    <#
    .SYNOPSIS
        Search file contents with ripgrep, falling back to Select-String.
    .DESCRIPTION
        First argument is the pattern; remaining arguments are forwarded to
        rg or used as Select-String -Path when rg is not installed.
    .EXAMPLE
        grep TODO .\src
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Pattern,
        [Parameter(ValueFromRemainingArguments)][object[]]$Rest
    )
    if (_Test-HasCommand 'rg') { rg $Pattern @Rest }
    elseif ($Rest) { Select-String -Pattern $Pattern -Path $Rest }
    else { $input | Select-String -Pattern $Pattern }
}

function find {
    <#
    .SYNOPSIS
        Find files with fd, falling back to Get-ChildItem -Recurse.
    .DESCRIPTION
        Forwards all arguments to fd when present. Without fd, treats the
        first argument as a root path (default .) and recurses.
    .EXAMPLE
        find .ps1
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'fd') { fd @Passthru }
    else {
        $root = if ($Passthru -and $Passthru.Count -gt 0) { [string]$Passthru[0] } else { '.' }
        Get-ChildItem -Path $root -Recurse -ErrorAction SilentlyContinue
    }
}

function top {
    <#
    .SYNOPSIS
        Launch btop as an interactive process monitor.
    .DESCRIPTION
        Starts btop when installed; otherwise falls back to Get-Process
        sorted by CPU so the alias never silently fails.
    .EXAMPLE
        top
    #>
    [CmdletBinding()]
    param()
    if (_Test-HasCommand 'btop') { btop }
    else { Get-Process | Sort-Object CPU -Descending | Select-Object -First 20 }
}

function df {
    <#
    .SYNOPSIS
        Show disk free space via duf (or Get-Volume / Get-PSDrive).
    .DESCRIPTION
        Prefers duf for a modern table. Falls back to Get-Volume, then
        Get-PSDrive FileSystem.
    .EXAMPLE
        df
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'duf') { duf @Passthru }
    elseif (Get-Command Get-Volume -ErrorAction SilentlyContinue) { Get-Volume }
    else { Get-PSDrive -PSProvider FileSystem }
}

function du {
    <#
    .SYNOPSIS
        Show directory disk usage via dust (or Measure-Object).
    .DESCRIPTION
        Forwards to dust when installed. Otherwise sums File Size under the
        given path (default: current directory).
    .EXAMPLE
        du
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (_Test-HasCommand 'dust') { dust @Passthru }
    else {
        $target = if ($Passthru) { [string]$Passthru[0] } else { (Get-Location).Path }
        $bytes = (Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        [pscustomobject]@{ Path = $target; SizeMB = [math]::Round($bytes / 1MB, 2) }
    }
}

# -----------------------------------------------------------------------------
# 3. Process, network & system diagnostics
# -----------------------------------------------------------------------------
function Kill-Port {
    <#
    .SYNOPSIS
        Force-kill every process listening on the given TCP port(s).
    .DESCRIPTION
        Resolves OwningProcess from Get-NetTCPConnection (Listen) and calls
        Stop-Process -Force. PID 0 / idle is ignored. Reports what was killed.
    .EXAMPLE
        Kill-Port 3000, 8080
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int[]]$Port
    )
    foreach ($p in $Port) {
        $conns = @(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
        if ($conns.Count -eq 0) {
            Write-Host "Nothing listening on port $p" -ForegroundColor DarkYellow
            continue
        }
        $pids = @($conns.OwningProcess | Sort-Object -Unique | Where-Object { $_ -and $_ -ne 0 })
        foreach ($procId in $pids) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $label = if ($proc) { $proc.ProcessName } else { '?' }
            if ($PSCmdlet.ShouldProcess("$label ($procId)", "Kill listener on :$p")) {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Write-Host "Killed $label ($procId) on port $p" -ForegroundColor Green
            }
        }
    }
}

function Test-Port {
    <#
    .SYNOPSIS
        Read-only TCP connect probe against host:port (does not kill).
    .DESCRIPTION
        Uses TcpClient with a timeout. Returns ComputerName, Port, and
        TcpTestSucceeded. Distinct from Kill-Port — this never touches processes.
    .EXAMPLE
        Test-Port -ComputerName localhost -Port 5432
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$ComputerName = 'localhost',
        [Parameter(Mandatory, Position = 1)][int]$Port,
        [int]$TimeoutMs = 2000
    )
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) {
            try { $client.EndConnect($async) } catch { $ok = $false }
        }
        [pscustomobject]@{
            ComputerName     = $ComputerName
            Port             = $Port
            TcpTestSucceeded = [bool]$ok
            TimeoutMs        = $TimeoutMs
        }
    }
    finally {
        $client.Dispose()
    }
}

function Get-MyIP {
    <#
    .SYNOPSIS
        Show local IPv4, default gateway, and public IP.
    .DESCRIPTION
        Local addresses come from Get-NetIPAddress (non-loopback). Gateway is
        the lowest-metric 0.0.0.0/0 route. Public IP is fetched from ipify.
    .EXAMPLE
        Get-MyIP
    #>
    [CmdletBinding()]
    param()
    $local = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -Property InterfaceAlias, IPAddress, PrefixLength
    )
    $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1
    $public = $null
    try {
        $public = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    }
    catch {
        try { $public = (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 5).Trim() }
        catch { $public = '(unavailable)' }
    }
    [pscustomobject]@{
        LocalIPv4    = ($local | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) ($($_.InterfaceAlias))" }) -join '; '
        Gateway      = $gw.NextHop
        Interface    = $gw.InterfaceAlias
        PublicIPv4   = $public
    }
}

function Start-Serve {
    <#
    .SYNOPSIS
        Serve the current directory over HTTP on a chosen port.
    .DESCRIPTION
        Tries python -m http.server, then npx serve, then a raw .NET
        HttpListener with a small static-file + directory-listing fallback.
        Binds 127.0.0.1 so no admin URL ACL is required. Ctrl+C stops it.
    .EXAMPLE
        Start-Serve -Port 8080
    #>
    [CmdletBinding()]
    param([int]$Port = 8080)
    $root = (Get-Location).ProviderPath
    Write-Host "Serving $root -> http://127.0.0.1:$Port/" -ForegroundColor Cyan

    if (_Test-HasCommand 'python') {
        python -m http.server $Port --bind 127.0.0.1
        return
    }
    if (_Test-HasCommand 'python3') {
        python3 -m http.server $Port --bind 127.0.0.1
        return
    }
    if (_Test-HasCommand 'py') {
        py -3 -m http.server $Port --bind 127.0.0.1
        return
    }
    if (_Test-HasCommand 'npx') {
        npx --yes serve -l tcp://127.0.0.1:$Port
        return
    }

    $mime = @{
        '.html' = 'text/html'; '.htm' = 'text/html'; '.css' = 'text/css'
        '.js' = 'text/javascript'; '.json' = 'application/json'; '.svg' = 'image/svg+xml'
        '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
        '.gif' = 'image/gif'; '.txt' = 'text/plain'; '.md' = 'text/plain'
        '.wasm' = 'application/wasm'; '.woff2' = 'font/woff2'
    }
    $listener = [System.Net.HttpListener]::new()
    $prefix = "http://127.0.0.1:$Port/"
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    Write-Host "HttpListener on $prefix  (Ctrl+C to stop)" -ForegroundColor Green
    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            $rel = [Uri]::UnescapeDataString($ctx.Request.Url.LocalPath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar))
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
            $full = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $rel))
            $rootFull = [IO.Path]::GetFullPath($root)
            if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                $ctx.Response.StatusCode = 403
                $ctx.Response.Close()
                continue
            }
            if ((Test-Path -LiteralPath $full -PathType Container) -or -not (Test-Path -LiteralPath $full)) {
                $asDir = if (Test-Path -LiteralPath $full -PathType Container) { $full } else { $null }
                $index = if ($asDir) { Join-Path $asDir 'index.html' } else { $null }
                if ($index -and (Test-Path -LiteralPath $index)) { $full = $index }
                elseif ($asDir) {
                    $listing = Get-ChildItem -LiteralPath $asDir | ForEach-Object { $_.Name }
                    $html = "<pre>$([string]::Join("`n", $listing))</pre>"
                    $bytes = [Text.Encoding]::UTF8.GetBytes($html)
                    $ctx.Response.ContentType = 'text/html'
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.Close()
                    continue
                }
                else {
                    $ctx.Response.StatusCode = 404
                    $ctx.Response.Close()
                    continue
                }
            }
            $bytes = [IO.File]::ReadAllBytes($full)
            $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
            $ctx.Response.ContentType = $(if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' })
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
}

function Get-SysResource {
    <#
    .SYNOPSIS
        ANSI-colored CPU/RAM dashboard plus the top 5 CPU and RAM processes.
    .DESCRIPTION
        Pulls OS/CPU counters via CIM (same source as Show-WelcomeBanner) and
        lists the heaviest processes. Use this when you want the full panel;
        the welcome banner uses the quick subset.
    .EXAMPLE
        Get-SysResource
    #>
    [CmdletBinding()]
    param()
    $d = _Get-SysResourceData
    Write-Host ""
    Write-Host "  $($d.OS)  ·  $($d.Shell)" -ForegroundColor Cyan
    Write-Host -NoNewline '  CPU  '
    _Write-PercentBar -Percent $d.CpuPercent
    Write-Host ""
    Write-Host -NoNewline '  RAM  '
    _Write-PercentBar -Percent $d.RamPercent
    Write-Host ("  {0} / {1} GB" -f $d.RamUsedGb, $d.RamTotalGb)
    Write-Host ""
    Write-Host '  Top CPU' -ForegroundColor Yellow
    $d.TopCpu | ForEach-Object {
        '{0,8}  {1,-28}  CPU={2,10:N1}  RAM={3,7:N1} MB' -f $_.Id, $_.ProcessName, $_.CPU, ($_.WorkingSet64 / 1MB)
    } | Write-Host
    Write-Host ""
    Write-Host '  Top RAM' -ForegroundColor Yellow
    $d.TopRam | ForEach-Object {
        '{0,8}  {1,-28}  CPU={2,10:N1}  RAM={3,7:N1} MB' -f $_.Id, $_.ProcessName, $_.CPU, ($_.WorkingSet64 / 1MB)
    } | Write-Host
    Write-Host ""
}

function Invoke-RestTest {
    <#
    .SYNOPSIS
        Lightweight curl/Postman-style REST call with pretty-printed JSON.
    .DESCRIPTION
        Accepts method, headers, and body. Non-string bodies are serialized
        with ConvertTo-Json. Prints status, headers of interest, and the
        response body via Get-JsonPretty when the payload looks like JSON.
    .EXAMPLE
        Invoke-RestTest -Uri https://httpbin.org/get
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')]
        [string]$Method = 'GET',
        [hashtable]$Headers,
        $Body,
        [string]$ContentType = 'application/json'
    )
    $params = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true }
    if ($Headers) { $params.Headers = $Headers }
    if ($null -ne $Body) {
        $params.Body = $(if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress })
        $params.ContentType = $ContentType
    }
    $resp = Invoke-WebRequest @params
    Write-Host "$($resp.StatusCode) $($resp.StatusDescription)" -ForegroundColor Green
    $ct = $resp.Headers['Content-Type']
    Write-Host "Content-Type: $ct" -ForegroundColor DarkGray
    $text = $resp.Content
    if ($text -and $text.TrimStart() -match '^[\[{]') {
        try { Get-JsonPretty -InputObject $text }
        catch { _Show-JsonPretty -Text $text }
    }
    else {
        Write-Output $text
    }
}

# -----------------------------------------------------------------------------
# 4. Developer productivity & file helpers
# -----------------------------------------------------------------------------
function mkcd {
    <#
    .SYNOPSIS
        Create a directory chain and cd into it.
    .DESCRIPTION
        New-Item -Force on the full path, then Set-Location. Equivalent to
        mkdir -p && cd on Unix.
    .EXAMPLE
        mkcd .\src\app
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $item = New-Item -ItemType Directory -Path $Path -Force
    Set-Location -LiteralPath $item.FullName
}

function Copy-CurrentPath {
    <#
    .SYNOPSIS
        Copy the current directory path to the clipboard.
    .DESCRIPTION
        Uses the filesystem ProviderPath (not a PowerShell drive qualifier).
        Prints the path and copies it. Works in Windows Terminal, VS Code,
        and any host that exposes Set-Clipboard.
    .EXAMPLE
        Copy-CurrentPath
    #>
    [CmdletBinding()]
    param()
    $path = (Get-Location).ProviderPath
    try { Set-Clipboard -Value $path } catch { }
    Write-Host $path -ForegroundColor Green
    $path
}

function New-GuidStr {
    <#
    .SYNOPSIS
        Generate a GUID, print it, and copy it to the clipboard.
    .DESCRIPTION
        Uses [guid]::NewGuid(). Optional -NoDash returns the 32-char form.
        Clipboard copy is best-effort (skipped on hosts without a clipboard).
    .EXAMPLE
        New-GuidStr
    #>
    [CmdletBinding()]
    param([switch]$NoDash)
    $g = [guid]::NewGuid()
    $text = if ($NoDash) { $g.ToString('N') } else { $g.ToString() }
    try { Set-Clipboard -Value $text } catch { }
    $text
}

function Extract-File {
    <#
    .SYNOPSIS
        Universal archive unpacker using 7-Zip (with Expand-Archive fallback).
    .DESCRIPTION
        Extracts -Path into -Destination (default: a folder named after the
        archive). Prefers 7z x -y. Zip files fall back to Expand-Archive.
    .EXAMPLE
        Extract-File -Path .\payload.zip
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [string]$Destination
    )
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not $Destination) {
        $Destination = Join-Path (Split-Path $resolved -Parent) ([IO.Path]::GetFileNameWithoutExtension($resolved))
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $seven = _Get-7Zip
    if ($seven) {
        $code = _Invoke-7Zip -ArgumentList @('x', '-y', "-o$Destination", $resolved)
        if ($code -ne 0) { throw "7-Zip extract failed (exit $code): $resolved" }
        return
    }
    if ([IO.Path]::GetExtension($resolved) -eq '.zip') {
        Expand-Archive -LiteralPath $resolved -DestinationPath $Destination -Force
        return
    }
    throw '7-Zip is not on PATH and the archive is not a .zip (Expand-Archive cannot handle it).'
}

function Compress-Dir {
    <#
    .SYNOPSIS
        Zip or tarball a folder with a timestamped archive name.
    .DESCRIPTION
        Default format is zip via 7z (or Compress-Archive). Use -Format tgz
        or tar when 7-Zip is available. Output lands next to the folder.
    .EXAMPLE
        Compress-Dir -Path .\dist -Format zip
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [ValidateSet('zip', 'tar', 'tgz', '7z')][string]$Format = 'zip'
    )
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = Join-Path (Split-Path $resolved -Parent) ("$([IO.Path]::GetFileName($resolved))-$stamp")
    $seven = _Get-7Zip
    switch ($Format) {
        'zip' {
            $out = "$base.zip"
            if ($seven) { & $seven a -tzip $out $resolved }
            else { Compress-Archive -Path $resolved -DestinationPath $out -Force }
        }
        '7z' {
            if (-not $seven) { throw '7-Zip is required for -Format 7z' }
            $out = "$base.7z"
            & $seven a -t7z $out $resolved
        }
        'tar' {
            if (-not $seven) { throw '7-Zip is required for -Format tar' }
            $out = "$base.tar"
            & $seven a -ttar $out $resolved
        }
        'tgz' {
            if (-not $seven) { throw '7-Zip is required for -Format tgz' }
            $tar = "$base.tar"
            $out = "$base.tar.gz"
            & $seven a -ttar $tar $resolved
            & $seven a -tgzip $out $tar
            Remove-Item -LiteralPath $tar -Force
        }
    }
    Write-Host "Wrote $out" -ForegroundColor Green
    $out
}

function Get-7Zip {
    <#
    .SYNOPSIS
        Resolve the 7-Zip executable (7z / 7za) on PATH.
    .DESCRIPTION
        Returns the full path of the first 7z.exe found. Throws if 7-Zip is
        missing so other archive commands fail with a clear install hint.
    .EXAMPLE
        Get-7Zip
    #>
    [CmdletBinding()]
    param()
    _Get-7Zip -Required
}

function Get-7ZipList {
    <#
    .SYNOPSIS
        List archive members via 7-Zip (7z l -slt) as objects.
    .DESCRIPTION
        Parses the technical listing into Path, Size, PackedSize, Modified,
        Attributes, CRC, Encrypted, Method. Works for 7z, zip, tar, rar,
        wim, and anything else your 7z build can read.
    .EXAMPLE
        Get-7ZipList -Path .\payload.7z
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [object]$Password
    )
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $exe = _Get-7Zip -Required
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add('l')
    [void]$args.Add('-slt')
    $pArg = _Get-7ZipPasswordArg -Password $Password
    if ($pArg) { [void]$args.Add($pArg) }
    [void]$args.Add($resolved)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = @(& $exe @args 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -and $code -ne 0) {
        throw "7-Zip list failed (exit $code): $resolved"
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in $raw) {
        if ($line -match '^Path = (.+)$') {
            if ($current) { $rows.Add([pscustomobject]$current) }
            $current = [ordered]@{ Path = $Matches[1] }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^([A-Za-z][A-Za-z0-9 ]*) = (.*)$') {
            $key = ($Matches[1] -replace '\s', '')
            $current[$key] = $Matches[2]
        }
    }
    if ($current) { $rows.Add([pscustomobject]$current) }
    $archiveName = [IO.Path]::GetFileName($resolved)
    $rows | Where-Object {
        $_.Path -and
        $_.Path -ne $resolved -and
        $_.Path -ne $archiveName
    }
}

function Test-7ZipArchive {
    <#
    .SYNOPSIS
        Test archive integrity with 7-Zip (7z t).
    .DESCRIPTION
        Runs a CRC/header test. Returns $true on exit 0, $false otherwise,
        and prints 7-Zip's own summary. Use -Password for encrypted archives.
    .EXAMPLE
        Test-7ZipArchive -Path .\payload.7z
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [object]$Password
    )
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add('t')
    $pArg = _Get-7ZipPasswordArg -Password $Password
    if ($pArg) { [void]$args.Add($pArg) }
    [void]$args.Add($resolved)
    $code = _Invoke-7Zip -ArgumentList $args
    $ok = ($code -eq 0)
    if ($ok) { Write-Host "OK  $resolved" -ForegroundColor Green }
    else { Write-Host "FAIL (exit $code)  $resolved" -ForegroundColor Red }
    return $ok
}

function New-7ZipArchive {
    <#
    .SYNOPSIS
        Create a 7-Zip archive from files and/or directories.
    .DESCRIPTION
        Wraps 7z a. Supports format, compression level (0-9), optional
        password (+ header encryption for .7z), and volume splitting
        (e.g. 100m). Destination is created/overwritten with -y.
    .EXAMPLE
        New-7ZipArchive -Destination .\dist.7z -Path .\src, .\README.md -Level 9
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Destination,
        [Parameter(Mandatory, Position = 1, ValueFromRemainingArguments)]
        [string[]]$Path,
        [ValidateSet('7z', 'zip', 'tar', 'gzip', 'bzip2', 'xz', 'wim')]
        [string]$Format = '7z',
        [ValidateRange(0, 9)][int]$Level = 5,
        [object]$Password,
        [switch]$EncryptHeaders,
        [string]$VolumeSize
    )
    $resolved = foreach ($p in $Path) { (Resolve-Path -LiteralPath $p).Path }
    $destDir = Split-Path -Parent $Destination
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add('a')
    [void]$args.Add('-y')
    [void]$args.Add("-t$Format")
    [void]$args.Add("-mx=$Level")
    $pArg = _Get-7ZipPasswordArg -Password $Password
    if ($pArg) {
        [void]$args.Add($pArg)
        if ($EncryptHeaders -and $Format -eq '7z') { [void]$args.Add('-mhe=on') }
    }
    if ($VolumeSize) { [void]$args.Add("-v$VolumeSize") }
    [void]$args.Add($Destination)
    foreach ($p in $resolved) { [void]$args.Add($p) }
    $code = _Invoke-7Zip -ArgumentList $args
    if ($code -ne 0) { throw "7-Zip create failed (exit $code): $Destination" }
    Write-Host "Wrote $Destination" -ForegroundColor Green
    (Resolve-Path -LiteralPath $Destination).Path
}

function Add-7ZipItem {
    <#
    .SYNOPSIS
        Add files or folders to an existing 7-Zip archive (7z a).
    .DESCRIPTION
        Updates or creates the archive at -Archive. Same password/level
        switches as New-7ZipArchive. Use this to append without rebuilding.
    .EXAMPLE
        Add-7ZipItem -Archive .\dist.7z -Path .\notes.txt
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path,
        [ValidateRange(0, 9)][int]$Level = 5,
        [object]$Password
    )
    $resolved = foreach ($p in $Path) { (Resolve-Path -LiteralPath $p).Path }
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add('a')
    [void]$args.Add('-y')
    [void]$args.Add("-mx=$Level")
    $pArg = _Get-7ZipPasswordArg -Password $Password
    if ($pArg) { [void]$args.Add($pArg) }
    [void]$args.Add($Archive)
    foreach ($p in $resolved) { [void]$args.Add($p) }
    $code = _Invoke-7Zip -ArgumentList $args
    if ($code -ne 0) { throw "7-Zip add failed (exit $code): $Archive" }
    Write-Host "Updated $Archive" -ForegroundColor Green
}

function Remove-7ZipItem {
    <#
    .SYNOPSIS
        Delete members from a 7-Zip archive by inner path (7z d).
    .DESCRIPTION
        -Item is the path inside the archive (as shown by Get-7ZipList),
        not a filesystem path. Wildcards follow 7-Zip rules (* and ?).
    .EXAMPLE
        Remove-7ZipItem -Archive .\dist.7z -Item 'src\*.tmp', 'Thumbs.db'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string[]]$Item,
        [object]$Password
    )
    $resolved = (Resolve-Path -LiteralPath $Archive).Path
    if (-not $PSCmdlet.ShouldProcess($resolved, "delete $($Item -join ', ')")) { return }
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add('d')
    [void]$args.Add('-y')
    $pArg = _Get-7ZipPasswordArg -Password $Password
    if ($pArg) { [void]$args.Add($pArg) }
    [void]$args.Add($resolved)
    foreach ($i in $Item) { [void]$args.Add($i) }
    $code = _Invoke-7Zip -ArgumentList $args
    if ($code -ne 0) { throw "7-Zip delete failed (exit $code): $resolved" }
}

function Expand-7ZipArchive {
    <#
    .SYNOPSIS
        Extract a 7-Zip archive with destination, password, and item filters.
    .DESCRIPTION
        Uses 7z x (full paths) by default, or 7z e with -Flat (no folders).
        -Item limits extraction to named members. -Force answers yes to
        overwrite prompts. Prefer this over Extract-File when you need
        passwords or a partial extract.
    .EXAMPLE
        Expand-7ZipArchive -Path .\payload.7z -Destination .\out -Force
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [string]$Destination,
        [string[]]$Item,
        [object]$Password,
        [switch]$Flat,
        [switch]$Force
    )
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not $Destination) {
        $Destination = Join-Path (Split-Path $resolved -Parent) ([IO.Path]::GetFileNameWithoutExtension($resolved))
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $args = [System.Collections.Generic.List[string]]::new()
    [void]$args.Add($(if ($Flat) { 'e' } else { 'x' }))
    if ($Force) { [void]$args.Add('-y') }
    [void]$args.Add("-o$Destination")
    $pArg = _Get-7ZipPasswordArg -Password $Password
    if ($pArg) { [void]$args.Add($pArg) }
    [void]$args.Add($resolved)
    foreach ($i in @($Item)) { if ($i) { [void]$args.Add($i) } }
    $code = _Invoke-7Zip -ArgumentList $args
    if ($code -ne 0) { throw "7-Zip extract failed (exit $code): $resolved" }
    Write-Host "Extracted -> $Destination" -ForegroundColor Green
    (Resolve-Path -LiteralPath $Destination).Path
}

function Get-EnvPath {
    <#
    .SYNOPSIS
        Print a deduplicated, formatted User / Machine / Session PATH.
    .DESCRIPTION
        Splits each PATH scope, de-dupes case-insensitively, and flags
        entries whose directory no longer exists.
    .EXAMPLE
        Get-EnvPath
    #>
    [CmdletBinding()]
    param()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($scope in @('Session', 'User', 'Machine')) {
        $raw = if ($scope -eq 'Session') { $env:PATH } else { [Environment]::GetEnvironmentVariable('Path', $scope) }
        $i = 0
        foreach ($part in ($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $i++
            $dup = -not $seen.Add($part)
            $exists = Test-Path -LiteralPath $part
            [pscustomobject]@{
                Scope  = $scope
                Index  = $i
                Path   = $part
                Exists = $exists
                Dup    = $dup
            }
        }
    }
}

function Add-EnvPath {
    <#
    .SYNOPSIS
        Permanently add a directory to the User PATH (and this session).
    .DESCRIPTION
        Resolves the directory, skips it when already present (case-insensitive),
        writes User (or Machine with -Machine) PATH, and prepends the session PATH.
    .EXAMPLE
        Add-EnvPath -Directory C:\tools\bin
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [switch]$Machine
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        throw "Directory does not exist: $Directory"
    }
    $full = [IO.Path]::GetFullPath($Directory)
    $scope = if ($Machine) { 'Machine' } else { 'User' }
    $current = [Environment]::GetEnvironmentVariable('Path', $scope)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($p in ($current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if (-not ($parts -contains $p)) { [void]$parts.Add($p) }
    }
    $already = $parts | Where-Object { $_.Equals($full, [StringComparison]::OrdinalIgnoreCase) }
    if ($already) {
        Write-Host "Already on $scope PATH: $full" -ForegroundColor DarkYellow
    }
    else {
        [void]$parts.Add($full)
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), $scope)
        Write-Host "Added to $scope PATH: $full" -ForegroundColor Green
    }
    if (-not ($env:PATH.Split(';') -contains $full)) {
        $env:PATH = "$full;$env:PATH"
    }
}

function Update-AllTheThings {
    <#
    .SYNOPSIS
        Update Scoop apps, installed PowerShell modules, and winget packages.
    .DESCRIPTION
        Runs scoop update / scoop update *, Update-Module for every
        Get-InstalledModule, then winget upgrade --all. Designed to be called
        interactively or from the weekly scheduled task wrapper.
    .EXAMPLE
        Update-AllTheThings
    #>
    [CmdletBinding()]
    param()
    $failed = 0
    if (_Test-HasCommand 'scoop') {
        Write-Host '==> scoop update' -ForegroundColor Cyan
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        scoop update
        scoop update *
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { $failed++ }
        $ErrorActionPreference = $prev
    }
    else {
        Write-Host 'scoop not found — skipping' -ForegroundColor DarkYellow
    }

    Write-Host '==> Update-Module' -ForegroundColor Cyan
    $mods = @(Get-InstalledModule -ErrorAction SilentlyContinue)
    foreach ($m in $mods) {
        try { Update-Module -Name $m.Name -Force -ErrorAction Stop }
        catch {
            Write-Host "  module $($m.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow
            $failed++
        }
    }
    if ($mods.Count -eq 0) { Write-Host '  no CurrentUser modules from PSGallery' -ForegroundColor DarkGray }

    if (_Test-HasCommand 'winget') {
        Write-Host '==> winget upgrade --all' -ForegroundColor Cyan
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        winget upgrade --all --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { $failed++ }
        $ErrorActionPreference = $prev
    }
    else {
        Write-Host 'winget not found — skipping' -ForegroundColor DarkYellow
    }

    if ($failed -gt 0) {
        Write-Host "Update-AllTheThings finished with $failed issue(s)" -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }
    Write-Host 'Update-AllTheThings finished cleanly' -ForegroundColor Green
    $global:LASTEXITCODE = 0
}

function New-SshKeyStr {
    <#
    .SYNOPSIS
        Generate an ED25519 SSH key, add it to ssh-agent, copy the public key.
    .DESCRIPTION
        Writes ~/.ssh/id_ed25519 or a timestamped key if that file exists.
        Starts the OpenSSH Authentication Agent when needed, ssh-add's the
        key, and copies the .pub file to the clipboard.
    .EXAMPLE
        New-SshKeyStr
    #>
    [CmdletBinding()]
    param(
        [string]$Comment = "$env:USERNAME@$env:COMPUTERNAME",
        [string]$File
    )
    if (-not (_Test-HasCommand 'ssh-keygen')) {
        throw 'ssh-keygen not found. Install OpenSSH Client (Windows Optional Feature) or scoop install openssh.'
    }
    $sshDir = Join-Path $HOME '.ssh'
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    if (-not $File) {
        $default = Join-Path $sshDir 'id_ed25519'
        $File = if (Test-Path -LiteralPath $default) {
            Join-Path $sshDir ("id_ed25519_{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
        }
        else { $default }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    ssh-keygen -t ed25519 -f $File -C $Comment -q -N '""'
    $ErrorActionPreference = $prev
    if (-not (Test-Path -LiteralPath "$File.pub")) { throw "ssh-keygen did not create $File.pub" }

    try {
        $svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.StartType -eq 'Disabled') { Set-Service -Name ssh-agent -StartupType Manual }
            if ($svc.Status -ne 'Running') { Start-Service -Name ssh-agent }
        }
    }
    catch {
        Write-Host "ssh-agent service: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    if (_Test-HasCommand 'ssh-add') { ssh-add $File }

    $pub = (Get-Content -LiteralPath "$File.pub" -Raw).Trim()
    try { Set-Clipboard -Value $pub } catch { }
    Write-Host "Public key copied to clipboard:" -ForegroundColor Green
    Write-Host $pub
    [pscustomobject]@{ PrivateKey = $File; PublicKey = "$File.pub"; Fingerprint = $pub }
}

function New-Password {
    <#
    .SYNOPSIS
        Generate a cryptographically random password via .NET RNG.
    .DESCRIPTION
        Uses RandomNumberGenerator (not Get-Random) with rejection sampling
        so charset mapping is unbiased. Optional -Copy sends it to clipboard.
    .EXAMPLE
        New-Password -Length 24 -Copy
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(8, 256)][int]$Length = 20,
        [string]$Charset = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+',
        [switch]$Copy
    )
    $chars = $Charset.ToCharArray()
    if ($chars.Length -lt 2) { throw 'Charset must contain at least 2 characters.' }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $result = [char[]]::new($Length)
        $buf = [byte[]]::new(4)
        $max = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$chars.Length)
        for ($i = 0; $i -lt $Length; $i++) {
            do {
                $rng.GetBytes($buf)
                $n = [BitConverter]::ToUInt32($buf, 0)
            } while ($n -ge $max)
            $result[$i] = $chars[$n % $chars.Length]
        }
        $password = -join $result
    }
    finally {
        $rng.Dispose()
    }
    if ($Copy) { try { Set-Clipboard -Value $password } catch { } }
    $password
}

function Verify-Checksum {
    <#
    .SYNOPSIS
        Compare a file hash (SHA256 default) against a published digest.
    .DESCRIPTION
        Wraps Get-FileHash. -Hash may be a hex string or a file containing
        the digest. Reports MATCH or MISMATCH and returns a boolean.
    .EXAMPLE
        Verify-Checksum -Path .\app.zip -Hash ABCDEF1234
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Hash,
        [ValidateSet('SHA256', 'SHA1', 'SHA384', 'SHA512', 'MD5')]
        [string]$Algorithm = 'SHA256'
    )
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $expected = $Hash.Trim()
    if (Test-Path -LiteralPath $expected -PathType Leaf) {
        $expected = ((Get-Content -LiteralPath $expected -TotalCount 1) -split '\s+')[0]
    }
    $expected = ($expected -replace '[\s\-:]', '').ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $resolved -Algorithm $Algorithm).Hash.ToUpperInvariant()
    $ok = $actual -eq $expected
    if ($ok) { Write-Host "MATCH  $Algorithm  $actual" -ForegroundColor Green }
    else {
        Write-Host "MISMATCH  $Algorithm" -ForegroundColor Red
        Write-Host "  expected $expected"
        Write-Host "  actual   $actual"
    }
    return $ok
}

function ConvertTo-Base64 {
    <#
    .SYNOPSIS
        Base64-encode a string or file (pipeline-friendly).
    .DESCRIPTION
        Strings are UTF-8 encoded. Use -FromFile (or pipe a file path that
        exists) to encode raw bytes. Output is a single line of Base64.
    .EXAMPLE
        'hello' | ConvertTo-Base64
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path')]
        $InputObject,
        [switch]$FromFile
    )
    process {
        $asString = [string]$InputObject
        $isFile = $FromFile -or (Test-Path -LiteralPath $asString -PathType Leaf)
        if ($isFile) {
            $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $asString).Path)
        }
        else {
            $bytes = [Text.Encoding]::UTF8.GetBytes($asString)
        }
        [Convert]::ToBase64String($bytes)
    }
}

function ConvertFrom-Base64 {
    <#
    .SYNOPSIS
        Decode a Base64 string to UTF-8 text (or raw bytes with -AsBytes).
    .DESCRIPTION
        Accepts pipeline input. Whitespace is stripped before decoding.
        -OutFile writes the raw bytes to disk.
    .EXAMPLE
        'aGVsbG8=' | ConvertFrom-Base64
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$InputObject,
        [switch]$AsBytes,
        [string]$OutFile
    )
    process {
        $clean = $InputObject -replace '\s', ''
        $bytes = [Convert]::FromBase64String($clean)
        if ($OutFile) {
            $dir = Split-Path -Parent $OutFile
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [IO.File]::WriteAllBytes($OutFile, $bytes)
            return (Resolve-Path -LiteralPath $OutFile).Path
        }
        if ($AsBytes) { return $bytes }
        [Text.Encoding]::UTF8.GetString($bytes)
    }
}

function Get-JsonPretty {
    <#
    .SYNOPSIS
        Indent and colorize JSON from a string or pipeline object.
    .DESCRIPTION
        Parses raw JSON text (or serializes objects) to a depth-32 indent,
        then highlights with bat -l json when bat is available.
    .EXAMPLE
        '{"a":1}' | Get-JsonPretty
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $InputObject
    )
    process {
        if ($InputObject -is [string]) {
            try { $obj = $InputObject | ConvertFrom-Json -ErrorAction Stop }
            catch { $obj = $InputObject }
        }
        else {
            $obj = $InputObject
        }
        $text = $obj | ConvertTo-Json -Depth 32
        _Show-JsonPretty -Text $text
    }
}

function Get-DotEnvDiff {
    <#
    .SYNOPSIS
        Diff two .env files and report added, removed, and changed keys.
    .DESCRIPTION
        Parses KEY=VALUE lines (comments and blanks ignored, optional quotes
        stripped) and compares Left vs Right. Useful for local vs staging.
    .EXAMPLE
        Get-DotEnvDiff -Left .env -Right .env.staging
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    $a = _Read-DotEnvFile -Path (Resolve-Path -LiteralPath $Left).Path
    $b = _Read-DotEnvFile -Path (Resolve-Path -LiteralPath $Right).Path
    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in $a.Keys) { [void]$keys.Add($k) }
    foreach ($k in $b.Keys) { [void]$keys.Add($k) }
    $rows = foreach ($k in ($keys | Sort-Object)) {
        $inA = $a.Contains($k)
        $inB = $b.Contains($k)
        $status = if ($inA -and -not $inB) { 'Removed' }
        elseif ($inB -and -not $inA) { 'Added' }
        elseif ($a[$k] -cne $b[$k]) { 'Changed' }
        else { 'Same' }
        if ($status -eq 'Same') { continue }
        [pscustomobject]@{
            Key    = $k
            Status = $status
            Left   = $(if ($inA) { $a[$k] } else { $null })
            Right  = $(if ($inB) { $b[$k] } else { $null })
        }
    }
    $rows
}

function Show-NvimKeymaps {
    <#
    .SYNOPSIS
        Print (or edit) the Neovim keymaps.lua bootstrapped by setup.ps1.
    .DESCRIPTION
        Reads $env:NVIM_KEYMAPS_PATH (set by setup.ps1 to
        %LOCALAPPDATA%\nvim\lua\config\keymaps.lua). Pretty-prints with bat
        (Lua syntax) when available. -Edit opens $env:EDITOR or nvim.
        Errors clearly if setup has not created the file yet.
    .EXAMPLE
        Show-NvimKeymaps
    #>
    [CmdletBinding()]
    param([switch]$Edit)
    $path = $script:NvimKeymapsPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $env:NVIM_KEYMAPS_PATH }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw @"
Neovim keymaps file not found: $path
Run setup.ps1 (without -SkipNvimBootstrap / -SkipCoreTools) so it can seed
%LOCALAPPDATA%\nvim\lua\config\keymaps.lua. The resolved path is stored in
NVIM_KEYMAPS_PATH and the script-level `$NvimKeymapsPath constant.
"@
    }
    if ($Edit) {
        $editor = $env:EDITOR
        if ([string]::IsNullOrWhiteSpace($editor)) {
            $editor = if (_Test-HasCommand 'nvim') { 'nvim' } elseif (_Test-HasCommand 'code') { 'code' } else { 'notepad' }
        }
        & $editor $path
        return
    }
    if (_Test-HasCommand 'bat') {
        bat --paging=never --language lua --style=numbers --color=always $path
    }
    else {
        Get-Content -LiteralPath $path
    }
}

# -----------------------------------------------------------------------------
# 5. Docker, DB & Git
# -----------------------------------------------------------------------------
function dprune {
    <#
    .SYNOPSIS
        Safely prune dangling Docker images, volumes, and stopped containers.
    .DESCRIPTION
        Runs container / image / volume prune without -a, so tagged images
        and named volumes in use are left alone. Refuses to run if docker
        is missing or the daemon is unreachable.
    .EXAMPLE
        dprune
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (_Test-HasCommand 'docker')) { throw 'docker is not on PATH.' }
    if (-not $PSCmdlet.ShouldProcess('docker', 'prune dangling containers/images/volumes')) { return }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker container prune -f
    docker image prune -f
    docker volume prune -f
    $ErrorActionPreference = $prev
    Write-Host 'Left tagged images and in-use volumes intact.' -ForegroundColor DarkGray
}

function dco {
    <#
    .SYNOPSIS
        docker compose (v2) with docker-compose v1 fallback.
    .DESCRIPTION
        Forwards remaining arguments to `docker compose` when the v2 plugin
        exists, otherwise to the docker-compose binary.
    .EXAMPLE
        dco ps
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][object[]]$Passthru)
    if (-not (_Test-HasCommand 'docker') -and -not (_Test-HasCommand 'docker-compose')) {
        throw 'Neither docker nor docker-compose is on PATH.'
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $v2 = $false
    if (_Test-HasCommand 'docker') {
        docker compose version 1>$null 2>$null
        $v2 = ($LASTEXITCODE -eq 0)
    }
    $ErrorActionPreference = $prev
    if ($v2) { docker compose @Passthru }
    elseif (_Test-HasCommand 'docker-compose') { docker-compose @Passthru }
    else { throw 'docker compose plugin is not available.' }
}

function glog {
    <#
    .SYNOPSIS
        Pretty-printed git commit graph (all branches).
    .DESCRIPTION
        git log --graph --decorate --all with a compact color format:
        hash, decorations, subject, relative date, author.
    .EXAMPLE
        glog
    #>
    [CmdletBinding()]
    param([int]$MaxCount = 40)
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    git log --graph --decorate --all --max-count=$MaxCount `
        --pretty=format:'%C(auto)%h%d %s %C(black)%C(bold)%cr %C(auto)%an'
}

function gundo {
    <#
    .SYNOPSIS
        Soft-reset the previous commit (keeps changes staged).
    .DESCRIPTION
        Equivalent to git reset --soft HEAD~1. Does not touch the working
        tree or the index beyond un-committing HEAD.
    .EXAMPLE
        gundo
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    $subject = git log -1 --pretty=%s
    if ($PSCmdlet.ShouldProcess($subject, 'git reset --soft HEAD~1')) {
        git reset --soft HEAD~1
    }
}

function gclean {
    <#
    .SYNOPSIS
        Delete local branches already merged into main or master.
    .DESCRIPTION
        Checks out main (or master), lists merged branches, and deletes
        those that are not main/master. Refuses to run outside a git repo.
    .EXAMPLE
        gclean
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    git rev-parse --is-inside-work-tree 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Not a git repository.' }
    $base = $null
    git show-ref --verify --quiet refs/heads/main
    if ($LASTEXITCODE -eq 0) { $base = 'main' }
    else {
        git show-ref --verify --quiet refs/heads/master
        if ($LASTEXITCODE -eq 0) { $base = 'master' }
    }
    if (-not $base) { throw 'Neither main nor master exists in this repo.' }
    git checkout $base
    $merged = @(git branch --merged $base)
    foreach ($line in $merged) {
        $name = $line.Trim().TrimStart('*').Trim()
        if ($name -match '^(main|master)$') { continue }
        if (-not $name) { continue }
        if ($PSCmdlet.ShouldProcess($name, "git branch -d (merged into $base)")) {
            git branch -d $name
        }
    }
}

function gquick {
    <#
    .SYNOPSIS
        git add -A, commit with the given message, and push.
    .DESCRIPTION
        Fast path for dirty trees you intend to publish immediately.
        Requires a commit message. Push uses the current upstream (or
        -u origin HEAD when none is set).
    .EXAMPLE
        gquick 'fix: handle empty body'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    git add -A
    git commit -m $Message
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 1>$null 2>$null
    $hasUpstream = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if ($hasUpstream) { git push }
    else { git push -u origin HEAD }
}

function gwip {
    <#
    .SYNOPSIS
        Commit all current changes as a WIP checkpoint.
    .DESCRIPTION
        git add -A and commit with a message prefixed WIP: so gunwip can
        safely identify and soft-reset it. Does not push.
    .EXAMPLE
        gwip
    #>
    [CmdletBinding()]
    param([string]$Note = 'checkpoint')
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    git add -A
    $stamp = Get-Date -Format 'o'
    git commit -m "WIP: $Note $stamp" --no-verify
}

function gunwip {
    <#
    .SYNOPSIS
        Soft-reset the most recent WIP commit created by gwip.
    .DESCRIPTION
        Inspects HEAD's subject. If it does not start with "WIP" the command
        refuses, so a real commit cannot be undone by accident.
    .EXAMPLE
        gunwip
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    $subject = git log -1 --pretty=%s
    if ($subject -notmatch '^WIP(\s|:)') {
        throw "HEAD is not a gwip checkpoint (subject: $subject)"
    }
    if ($PSCmdlet.ShouldProcess($subject, 'git reset --soft HEAD~1')) {
        git reset --soft HEAD~1
    }
}

function gswitch {
    <#
    .SYNOPSIS
        Interactive fzf branch switcher (local and remote).
    .DESCRIPTION
        Lists git branch -a, lets you pick with fzf, strips remotes/origin/
        prefixes, and checks out the branch (creating a tracking branch
        when the selection only exists on the remote).
    .EXAMPLE
        gswitch
    #>
    [CmdletBinding()]
    param()
    if (-not (_Test-HasCommand 'git')) { throw 'git is not on PATH.' }
    if (-not (_Test-HasCommand 'fzf')) { throw 'gswitch requires fzf (scoop install fzf).' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pick = git branch -a --format='%(refname:short)' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch 'HEAD' } |
        Sort-Object -Unique |
        fzf --prompt 'branch> ' --height 40%
    $ErrorActionPreference = $prev
    if (-not $pick) { return }
    $branch = $pick.Trim() -replace '^remotes/', '' -replace '^origin/', ''
    git checkout $branch
    if ($LASTEXITCODE -ne 0) {
        git checkout -t "origin/$branch"
    }
}

# -----------------------------------------------------------------------------
# 6. Java helpers
# -----------------------------------------------------------------------------
function Get-JavaProcesses {
    <#
    .SYNOPSIS
        jps-style listing of running JVMs with PID, main class, and memory.
    .DESCRIPTION
        Uses jps -lvm when a JDK is on PATH, then enriches with WorkingSet
        from Get-Process / Win32_Process. Falls back to process-command-line
        parsing when jps is missing.
    .EXAMPLE
        Get-JavaProcesses
    #>
    [CmdletBinding()]
    param()
    $memByPid = @{}
    Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe' OR Name='jshell.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { $memByPid[$_.ProcessId] = $_ }

    $rows = [System.Collections.Generic.List[object]]::new()
    if (_Test-HasCommand 'jps') {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $jps = @(jps -l 2>$null)
        $ErrorActionPreference = $prev
        foreach ($line in $jps) {
            if ($line -notmatch '^\s*(\d+)\s+(.*)$') { continue }
            $procId = [int]$Matches[1]
            $main = $Matches[2]
            $cim = $memByPid[$procId]
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $rows.Add([pscustomobject]@{
                    PID       = $procId
                    MainClass = $main
                    MemoryMB  = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { $null }
                    Command   = if ($cim) { $cim.CommandLine } else { $null }
                })
        }
    }

    foreach ($procId in $memByPid.Keys) {
        if ($rows | Where-Object { $_.PID -eq $procId }) { continue }
        $cim = $memByPid[$procId]
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $main = $cim.CommandLine
        if ($main -and $main -match '\s(-jar\s+\S+|\S+\.[A-Za-z0-9_]+)\s') { $main = $Matches[1] }
        $rows.Add([pscustomobject]@{
                PID       = $procId
                MainClass = $main
                MemoryMB  = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { $null }
                Command   = $cim.CommandLine
            })
    }
    $rows
}

function _Get-JdkVersionLabel {
    param([string]$Home)
    $rel = Join-Path $Home 'release'
    if (Test-Path -LiteralPath $rel) {
        foreach ($line in Get-Content -LiteralPath $rel -ErrorAction SilentlyContinue) {
            if ($line -match '^JAVA_VERSION="?([^"]+)"?') { return $Matches[1] }
        }
    }
    return $null
}

function _Get-InstalledJdkHomes {
    $homes = [System.Collections.Generic.List[string]]::new()
    $roots = @(
        (Join-Path $env:USERPROFILE 'scoop\apps')
        'C:\Program Files\Java'
        'C:\Program Files\Eclipse Adoptium'
        'C:\Program Files\Amazon Corretto'
        'C:\Program Files\Microsoft'
        'C:\Program Files\BellSoft'
        'C:\Program Files\Microsoft\jdk'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($bin in @(
                    (Join-Path $_.FullName 'bin\java.exe')
                    (Join-Path $_.FullName 'current\bin\java.exe')
                )) {
                if (Test-Path -LiteralPath $bin) {
                    [void]$homes.Add((Split-Path (Split-Path $bin -Parent) -Parent))
                }
            }
        }
    }
    return @($homes | Sort-Object -Unique)
}

function Get-JavaHome {
    <#
    .SYNOPSIS
        List installed JDKs and mark the active JAVA_HOME.
    .DESCRIPTION
        Discovers JDKs under Scoop and Program Files (Temurin, Corretto,
        Microsoft, BellSoft). Prints version from the JDK release file
        when present. The row matching $env:JAVA_HOME is marked current.
    .EXAMPLE
        Get-JavaHome
    #>
    [CmdletBinding()]
    param()
    $current = $env:JAVA_HOME
    $rows = foreach ($home in _Get-InstalledJdkHomes) {
        $ver = _Get-JdkVersionLabel -Home $home
        $isCurrent = $current -and (
            $home.Equals($current, [StringComparison]::OrdinalIgnoreCase) -or
            $current.StartsWith($home, [StringComparison]::OrdinalIgnoreCase)
        )
        [pscustomobject]@{
            Current = $isCurrent
            Version = $(if ($ver) { $ver } else { '?' })
            Path    = $home
        }
    }
    if (-not $rows) {
        Write-Host 'No JDKs found. Run setup.ps1 or install a JDK (scoop bucket java).' -ForegroundColor DarkYellow
        return
    }
    Write-Host ""
    if ($current) {
        Write-Host "  JAVA_HOME=$current" -ForegroundColor Cyan
    }
    else {
        Write-Host '  JAVA_HOME is not set' -ForegroundColor DarkYellow
    }
    foreach ($row in $rows) {
        $mark = if ($row.Current) { '*' } else { ' ' }
        $color = if ($row.Current) { 'Green' } else { 'Gray' }
        Write-Host ("  {0}  {1,-12}  {2}" -f $mark, $row.Version, $row.Path) -ForegroundColor $color
    }
    Write-Host '  Switch:  Set-JavaHome 21   or   Switch-Jdk' -ForegroundColor DarkGray
    Write-Host ""
    $rows
}

function Set-JavaHome {
    <#
    .SYNOPSIS
        Switch the session JDK (JAVA_HOME + PATH).
    .DESCRIPTION
        Discovers JDKs under Scoop and Program Files. Pass a version
        substring (17, 21, corretto, temurin) or a full path. With no
        argument, lists candidates and uses fzf when available.
    .EXAMPLE
        Set-JavaHome 21
    #>
    [CmdletBinding()]
    param([string]$PathOrVersion)
    $unique = _Get-InstalledJdkHomes
    if (-not $PathOrVersion) {
        if ((_Test-HasCommand 'fzf') -and $unique) {
            $labels = foreach ($home in $unique) {
                $ver = _Get-JdkVersionLabel -Home $home
                if ($ver) { "$ver  $home" } else { $home }
            }
            $pick = $labels | fzf --prompt 'JAVA_HOME> ' --height 40%
            if (-not $pick) { return }
            $PathOrVersion = ($pick -split '\s{2,}', 2)[-1].Trim()
            if (-not (Test-Path -LiteralPath $PathOrVersion)) { $PathOrVersion = $pick.Trim() }
        }
        else {
            Get-JavaHome
            return
        }
    }
    $chosen = $null
    if (Test-Path -LiteralPath $PathOrVersion) {
        $chosen = (Resolve-Path -LiteralPath $PathOrVersion).Path
        if (Test-Path (Join-Path $chosen 'current\bin\java.exe')) {
            $chosen = Join-Path $chosen 'current'
        }
    }
    else {
        $chosen = $unique | Where-Object {
            $_ -match [regex]::Escape($PathOrVersion) -or
            ((_Get-JdkVersionLabel -Home $_) -like "*$PathOrVersion*")
        } | Select-Object -First 1
        if ($chosen -and (Test-Path (Join-Path $chosen 'current\bin\java.exe'))) {
            $chosen = Join-Path $chosen 'current'
        }
    }
    if (-not $chosen -or -not (Test-Path (Join-Path $chosen 'bin\java.exe'))) {
        throw "No JDK matched '$PathOrVersion'. Run Get-JavaHome to list candidates."
    }
    $oldHome = $env:JAVA_HOME
    $env:JAVA_HOME = $chosen
    $parts = [System.Collections.Generic.List[string]]::new()
    [void]$parts.Add((Join-Path $chosen 'bin'))
    foreach ($p in ($env:PATH -split ';')) {
        if (-not $p) { continue }
        if ($oldHome -and $p.StartsWith($oldHome, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($p -match '[\\/](java|jdk|jre|corretto|temurin|microsoft-jdk)[^\\/]*[\\/](current[\\/])?bin\\?$') { continue }
        [void]$parts.Add($p)
    }
    $env:PATH = ($parts -join ';')
    $ver = _Get-JdkVersionLabel -Home $chosen
    Write-Host "JAVA_HOME=$($env:JAVA_HOME)$(if ($ver) { "  ($ver)" })" -ForegroundColor Green
    if (_Test-HasCommand 'java') { java -version 2>&1 | Write-Host }
}

function Switch-Jdk {
    <#
    .SYNOPSIS
        Interactive JDK version switcher (same as Set-JavaHome).
    .DESCRIPTION
        Wrapper around Set-JavaHome. With no argument, pick from installed
        JDKs. Pass 17, 21, temurin, corretto, or a path to switch directly.
    .EXAMPLE
        Switch-Jdk 21
    #>
    [CmdletBinding()]
    param([string]$PathOrVersion)
    Set-JavaHome -PathOrVersion $PathOrVersion
}

# -----------------------------------------------------------------------------
# 7. Dynamic reflection engine
# -----------------------------------------------------------------------------
function _Get-ProfileCommandCategory {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$AliasTarget
    )
    $lookup = $Name
    if ($AliasTarget) { $lookup = $AliasTarget }

    $map = @{
        'Show-WelcomeBanner'       = 'Profile'
        'Show-Commands'            = 'Profile'
        'Show-Command'             = 'Profile'
        'Initialize-DevProfileDeferred' = 'Profile'
        'touch'                    = 'Linux-native'
        'which'                    = 'Linux-native'
        'cat'                      = 'Linux-native'
        'ls'                       = 'Linux-native'
        'll'                       = 'Linux-native'
        'la'                       = 'Linux-native'
        'grep'                     = 'Linux-native'
        'find'                     = 'Linux-native'
        'top'                      = 'Linux-native'
        'df'                       = 'Linux-native'
        'du'                       = 'Linux-native'
        'Clear-Host'               = 'Linux-native'
        'Kill-Port'                = 'Network & process'
        'Test-Port'                = 'Network & process'
        'Get-MyIP'                 = 'Network & process'
        'Start-Serve'              = 'Network & process'
        'Get-SysResource'          = 'System'
        'Invoke-RestTest'          = 'HTTP'
        'mkcd'                     = 'Files'
        'Copy-CurrentPath'         = 'Files'
        'Extract-File'             = 'Files'
        'Compress-Dir'             = 'Files'
        'Get-7Zip'                 = '7-Zip archives'
        'Get-7ZipList'             = '7-Zip archives'
        'Test-7ZipArchive'         = '7-Zip archives'
        'New-7ZipArchive'          = '7-Zip archives'
        'Add-7ZipItem'             = '7-Zip archives'
        'Remove-7ZipItem'          = '7-Zip archives'
        'Expand-7ZipArchive'       = '7-Zip archives'
        'Get-EnvPath'              = 'Environment'
        'Add-EnvPath'              = 'Environment'
        'Update-AllTheThings'      = 'Environment'
        'New-GuidStr'              = 'Crypto & encoding'
        'New-Password'             = 'Crypto & encoding'
        'New-SshKeyStr'            = 'Crypto & encoding'
        'Verify-Checksum'          = 'Crypto & encoding'
        'ConvertTo-Base64'         = 'Crypto & encoding'
        'ConvertFrom-Base64'       = 'Crypto & encoding'
        'Get-JsonPretty'           = 'JSON & env'
        'Get-DotEnvDiff'           = 'JSON & env'
        'Show-NvimKeymaps'         = 'Neovim'
        'dprune'                   = 'Docker'
        'dco'                      = 'Docker'
        'glog'                     = 'Git'
        'gundo'                    = 'Git'
        'gclean'                   = 'Git'
        'gquick'                   = 'Git'
        'gwip'                     = 'Git'
        'gunwip'                   = 'Git'
        'gswitch'                  = 'Git'
        'Get-JavaProcesses'        = 'Java'
        'Get-JavaHome'             = 'Java'
        'Set-JavaHome'             = 'Java'
        'Switch-Jdk'               = 'Java'
    }

    if ($map.ContainsKey($lookup)) { return $map[$lookup] }
    if ($map.ContainsKey($Name)) { return $map[$Name] }
    if ($Name -match '^g(log|undo|clean|quick|wip|unwip|switch)$') { return 'Git' }
    if ($Name -match '^(zls|ztest|znew|zadd|zrm|zx)$' -or $lookup -match '7Zip|7-Zip') { return '7-Zip archives' }
    if ($Name -match '^(dco|dprune)$') { return 'Docker' }
    return 'Other'
}

function _Get-OwnedProfileFiles {
    $owned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @(
            $script:ProfilePath
            $env:DEVTERMINAL_PROFILE
            (Join-Path $env:LOCALAPPDATA 'dev-terminal\Microsoft.PowerShell_profile.ps1')
        )) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            [void]$owned.Add([IO.Path]::GetFullPath($p))
        }
    }
    return $owned
}

function _Get-WindowsHelpMap {
    if ($script:WindowsHelpMap) { return $script:WindowsHelpMap }
    $map = @{}
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Get-Help -Name * -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -and $_.Category -in @('Cmdlet', 'Function', 'Alias', 'ExternalScript') } |
            ForEach-Object {
                $synopsis = (([string]$_.Synopsis) -replace '\s+', ' ').Trim()
                if ($synopsis -and $synopsis -notmatch '^Get-Help') {
                    $map[$_.Name] = $synopsis
                }
            }
    }
    catch { }
    finally {
        $ProgressPreference = $prev
    }
    $script:WindowsHelpMap = $map
    return $map
}

function _Write-CommandCatalog {
    param(
        [Parameter(Mandatory)]$Rows,
        [string[]]$CategoryOrder
    )
    $nameWidth = @($Rows | ForEach-Object { $_.Command.Length } | Measure-Object -Maximum).Maximum
    if ($nameWidth -lt 8) { $nameWidth = 8 }
    if ($nameWidth -gt 36) { $nameWidth = 36 }
    $fmt = '  {0,-' + $nameWidth + '}  '
    $ruleWidth = 62
    if ($Host.UI.RawUI -and $Host.UI.RawUI.WindowSize.Width -gt 40) {
        $ruleWidth = [math]::Min(62, [math]::Max(36, $Host.UI.RawUI.WindowSize.Width - 2))
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($cat in $CategoryOrder) { [void]$seen.Add($cat) }
    $extra = @($Rows | ForEach-Object { $_.Category } | Sort-Object -Unique | Where-Object { -not $seen.Contains($_) })
    $allCats = @($CategoryOrder) + $extra

    foreach ($cat in $allCats) {
        $group = @($Rows | Where-Object { $_.Category -eq $cat } | Sort-Object Command)
        if ($group.Count -eq 0) { continue }
        Write-Host " $cat" -ForegroundColor Cyan
        Write-Host (' ' + ('─' * $ruleWidth)) -ForegroundColor DarkCyan
        foreach ($row in $group) {
            $name = $row.Command
            if ($name.Length -gt $nameWidth) { $name = $name.Substring(0, $nameWidth - 1) + '…' }
            Write-Host -NoNewline ($fmt -f $name) -ForegroundColor Yellow
            Write-Host $row.Description
        }
        Write-Host ""
    }
}

function Show-Commands {
    <#
    .SYNOPSIS
        Terminal catalog of user profile commands, or Windows commands.
    .DESCRIPTION
        Prints to the console with Write-Host. Never opens the Windows
        Show-Command GUI. Default (-User) lists this profile's commands.
        -Windows lists loaded Windows/PowerShell cmdlets with descriptions.
        Pass both flags to show both lists.
    .EXAMPLE
        Show-Commands
    .EXAMPLE
        Show-Commands -User
    .EXAMPLE
        Show-Commands -Windows
    .EXAMPLE
        Show-Commands -User -Windows
    #>
    [CmdletBinding()]
    param(
        [switch]$User,
        [switch]$Windows
    )
    $showUser = $User -or -not $Windows
    $showWindows = [bool]$Windows

    $ownedFiles = _Get-OwnedProfileFiles
    $profileNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rows = [System.Collections.Generic.List[object]]::new()

    Get-ChildItem Function: | Where-Object {
        $_.Name -notmatch '^_' -and
        $_.ScriptBlock -and
        $_.ScriptBlock.File -and
        $ownedFiles.Contains([IO.Path]::GetFullPath($_.ScriptBlock.File))
    } | ForEach-Object {
        [void]$profileNames.Add($_.Name)
        $help = $null
        try { $help = $_.ScriptBlock.Ast.GetHelpContent() } catch { }
        $synopsis = ''
        if ($help -and $help.Synopsis) {
            $synopsis = (([string]$help.Synopsis) -replace '\s+', ' ').Trim()
        }
        if (-not $synopsis) { $synopsis = '(no description)' }
        $rows.Add([pscustomobject]@{
                Command     = $_.Name
                Description = $synopsis
                Category    = _Get-ProfileCommandCategory -Name $_.Name
            })
    }

    foreach ($alias in $script:ProfileAliases.Values) {
        [void]$profileNames.Add($alias.Name)
        $synopsis = if ($alias.Synopsis) { $alias.Synopsis } else { "Alias for $($alias.Value)" }
        $rows.Add([pscustomobject]@{
                Command     = $alias.Name
                Description = $synopsis
                Category    = _Get-ProfileCommandCategory -Name $alias.Name -AliasTarget $alias.Value
            })
    }

    $order = @(
        'Profile', 'Linux-native', 'Network & process', 'System', 'HTTP',
        'Files', '7-Zip archives', 'Environment', 'Crypto & encoding',
        'JSON & env', 'Neovim', 'Docker', 'Git', 'Java', 'Other'
    )

    Write-Host ""
    if ($showUser) {
        Write-Host ' User commands  (Show-Commands -Windows for Windows/PowerShell commands)' -ForegroundColor Green
        _Write-CommandCatalog -Rows $rows -CategoryOrder $order
    }

    if (-not $showWindows) { return }

    Write-Host ' Collecting Windows/PowerShell command descriptions...' -ForegroundColor DarkGray
    $helpMap = _Get-WindowsHelpMap
    $winRows = [System.Collections.Generic.List[object]]::new()
    $cmds = @(Get-Command -CommandType Cmdlet, Function, Alias -ErrorAction SilentlyContinue)
    foreach ($cmd in $cmds) {
        if ($profileNames.Contains($cmd.Name)) { continue }
        if ($cmd.Name -match '^_') { continue }
        if ($cmd.Name -eq 'Show-Command' -and $cmd.CommandType -eq 'Cmdlet') { continue }
        if ($cmd.ScriptBlock -and $cmd.ScriptBlock.File -and $ownedFiles.Contains([IO.Path]::GetFullPath($cmd.ScriptBlock.File))) {
            continue
        }
        $source = if ($cmd.Source) { [string]$cmd.Source } else { $cmd.CommandType.ToString() }
        $desc = $null
        if ($helpMap.ContainsKey($cmd.Name)) { $desc = $helpMap[$cmd.Name] }
        if (-not $desc) {
            if ($cmd.CommandType -eq 'Alias' -and $cmd.ReferencedCommand) {
                $desc = "Alias for $($cmd.ReferencedCommand.Name)"
            }
            else {
                $desc = "$($cmd.CommandType) from $source"
            }
        }
        $winRows.Add([pscustomobject]@{
                Command     = $cmd.Name
                Description = $desc
                Category    = "Windows · $source"
            })
    }

    Write-Host " Windows commands ($($winRows.Count))" -ForegroundColor Green
    _Write-CommandCatalog -Rows $winRows -CategoryOrder @()
}

function Show-Command {
    <#
    .SYNOPSIS
        Terminal catalog of user or Windows commands (overrides the GUI).
    .DESCRIPTION
        Same as Show-Commands. Replaces the built-in Show-Command WPF
        dialog so typing Show-Command never opens a GUI. Default is
        user/profile commands. Use -Windows for Windows/PowerShell commands.
    .EXAMPLE
        Show-Command
    .EXAMPLE
        Show-Command -Windows
    .EXAMPLE
        Show-Command -User -Windows
    #>
    [CmdletBinding()]
    param(
        [switch]$User,
        [switch]$Windows
    )
    Show-Commands -User:$User -Windows:$Windows
}

# -----------------------------------------------------------------------------
# Aliases that are true drop-ins (no extra logic)
# -----------------------------------------------------------------------------
_Set-ProfileAlias -Name clear -Value Clear-Host -Synopsis 'Clear the host buffer (Unix clear).'
_Set-ProfileAlias -Name ccp -Value Copy-CurrentPath -Synopsis 'Copy the current directory path to the clipboard.'
_Set-ProfileAlias -Name jdk -Value Switch-Jdk -Synopsis 'Switch the session JDK (JAVA_HOME + PATH).'
_Set-ProfileAlias -Name Welcome-Banner -Value Show-WelcomeBanner -Synopsis 'Alias for Show-WelcomeBanner.'
_Set-ProfileAlias -Name zls -Value Get-7ZipList -Synopsis 'List archive contents (7z l).'
_Set-ProfileAlias -Name ztest -Value Test-7ZipArchive -Synopsis 'Test archive integrity (7z t).'
_Set-ProfileAlias -Name znew -Value New-7ZipArchive -Synopsis 'Create a 7-Zip archive (7z a).'
_Set-ProfileAlias -Name zadd -Value Add-7ZipItem -Synopsis 'Add files to a 7-Zip archive.'
_Set-ProfileAlias -Name zrm -Value Remove-7ZipItem -Synopsis 'Delete members from a 7-Zip archive.'
_Set-ProfileAlias -Name zx -Value Expand-7ZipArchive -Synopsis 'Extract a 7-Zip archive (7z x).'

if ($script:DevProfileInteractive) {
    Show-WelcomeBanner
}
