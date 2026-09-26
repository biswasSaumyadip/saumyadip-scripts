# Dev Terminal (Windows)

PowerShell 7 profile and one-shot installer for a new Windows machine. Run `setup.ps1`, then you can delete this folder. Every command lives in the copied profile on the machine.

```powershell
pwsh -NoProfile -File .\setup.ps1
```

After setup, open a **new** Windows Terminal tab. The prompt shows RAM on the right. Run `Show-Commands` for the in-shell catalog.

---

## What gets installed

| Item | Location |
| --- | --- |
| Command library (this profile) | `%LOCALAPPDATA%\dev-terminal\Microsoft.PowerShell_profile.ps1` |
| pwsh `$PROFILE` (same file) | `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` |
| Oh My Posh theme (RAM on the right) | `%LOCALAPPDATA%\dev-terminal\dev-terminal.omp.json` |
| Neovim keymaps seed | `%LOCALAPPDATA%\nvim\lua\config\keymaps.lua` |
| Weekly updater wrapper | `%LOCALAPPDATA%\dev-terminal\Update-AllTheThings.ps1` |

Do **not** use `-SkipProfileInstall` if you plan to delete this folder.

Requires **PowerShell 7** (`winget install Microsoft.PowerShell`). Windows PowerShell 5.1 only gets a stub that tells you to start `pwsh`.

---

## setup.ps1

Idempotent. Safe to re-run. Requests UAC when not already elevated (fonts and the scheduled task).

```powershell
.\setup.ps1
.\setup.ps1 -SkipJavaStack -SkipCloudTools -PasswordManager none
.\setup.ps1 -SkipAutoUpdateTask -SkipElevation
```

### Switches

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-SkipElevation` | off | Do not re-launch as Administrator |
| `-SkipCoreTools` | off | Skip core Scoop tools |
| `-SkipNvimBootstrap` | off | Do not seed Neovim lazy.nvim / keymaps |
| `-SkipCppStack` | off | Skip gcc / make / cmake |
| `-SkipJavaStack` | off | Skip Corretto LTS, Gradle, Maven |
| `-SkipNodeStack` | off | Skip fnm / pnpm |
| `-SkipCloudTools` | off | Skip AWS / Azure / gcloud CLIs |
| `-SkipK8sTools` | off | Skip kubectl / helm / k9s / terraform |
| `-SkipDbTools` | off | Skip redis / mysql |
| `-SkipContainers` | off | Skip lazydocker |
| `-SkipSecrets` | off | Skip age / sops / direnv / watchexec |
| `-SkipPasswordManager` | off | Skip password-manager CLI |
| `-PasswordManager` | `1password-cli` | `1password-cli`, `bitwarden-cli`, or `none` |
| `-SkipAutoUpdateTask` | off | Do not register the weekly update task |
| `-AutoUpdateTaskName` | `DevTerminal-Update-AllTheThings` | Scheduled task name |
| `-AutoUpdateDay` | `Sunday` | Day of week |
| `-AutoUpdateTime` | `03:00` | Time of day |
| `-SkipWindowsTerminal` | off | Do not patch Windows Terminal settings |
| `-SkipProfileInstall` | off | Do not copy the profile onto the machine |
| `-SkipGitConfig` | off | Do not set git + delta defaults |
| `-ScoopRoot` | `%USERPROFILE%\scoop` | Scoop install root |
| `-ColorScheme` | `One Half Dark` | Windows Terminal scheme |
| `-NerdFontFace` | `JetBrainsMono NF` | Terminal font face |
| `-NerdFontPackage` | `JetBrainsMono-NF` | Scoop font package |

---

## Prompt

Oh My Posh is initialized from the copied theme. The **right side** shows current RAM utilization (`RAM 42.3%`). Color: cyan under 70%, yellow at 70%+, red at 90%+.

Elevated conhost sessions (no Nerd Font) use `dev-terminal-ascii.omp.json` instead.

---

## Show-Commands (no GUI)

`Show-Command` is overridden so it never opens the Windows WPF dialog. Both names print in the terminal: command name + description, grouped by category.

| Command | What you get |
| --- | --- |
| `Show-Commands` | **User / profile commands only** (default) |
| `Show-Commands -User` | Same as default |
| `Show-Commands -Windows` | Loaded Windows/PowerShell cmdlets, functions, and aliases |
| `Show-Commands -User -Windows` | Both lists |

`Show-Command` accepts the same flags.

---

## User commands

In the shell, `Get-Help <Name> -Examples` works for every function below.

### Profile

| Command | Description | Example |
| --- | --- | --- |
| `Show-WelcomeBanner` | Startup splash (OS, uptime, shell, path, CPU/RAM) | `Show-WelcomeBanner` |
| `Welcome-Banner` | Alias for `Show-WelcomeBanner` | `Welcome-Banner` |
| `Show-Commands` | Terminal catalog of user (or Windows) commands | `Show-Commands` |
| `Show-Command` | Same as `Show-Commands` (not the Windows GUI) | `Show-Command -Windows` |
| `Initialize-DevProfileDeferred` | One-shot import of Terminal-Icons, PSFzf, CLI completions | `Initialize-DevProfileDeferred` |

### Linux-native

| Command | Description | Example |
| --- | --- | --- |
| `touch` | Create a file or refresh its last-write timestamp | `touch README.md, notes.txt` |
| `which` | Resolve a command to type and source path | `which git` |
| `cat` | Print file contents via `bat`, else `Get-Content` | `cat .\setup.ps1` |
| `ls` | List entries with eza icons/git, else `Get-ChildItem` | `ls` |
| `ll` | Long listing (`eza -l`) | `ll` |
| `la` | List all, including hidden (`eza -la`) | `la` |
| `grep` | Search with ripgrep, else `Select-String` | `grep TODO .\src` |
| `find` | Find files with `fd`, else recursive `Get-ChildItem` | `find .ps1` |
| `top` | Launch `btop`, else top CPU processes | `top` |
| `df` | Disk free via `duf`, else `Get-Volume` | `df` |
| `du` | Directory usage via `dust`, else `Measure-Object` | `du` |
| `clear` | Clear the host buffer | `clear` |

### Network and process

| Command | Description | Example |
| --- | --- | --- |
| `Kill-Port` | Force-kill every process listening on the given TCP port(s) | `Kill-Port 3000, 8080` |
| `Test-Port` | Read-only TCP connect probe (does not kill) | `Test-Port -ComputerName localhost -Port 5432` |
| `Get-MyIP` | Local IPv4, default gateway, public IP | `Get-MyIP` |
| `Start-Serve` | HTTP-serve the current directory (binds `127.0.0.1`) | `Start-Serve -Port 8080` |

### System and HTTP

| Command | Description | Example |
| --- | --- | --- |
| `Get-SysResource` | CPU/RAM bars plus top 5 CPU and RAM processes | `Get-SysResource` |
| `Invoke-RestTest` | Lightweight REST call with pretty-printed JSON | `Invoke-RestTest -Uri https://httpbin.org/get` |

### Files

| Command | Description | Example |
| --- | --- | --- |
| `mkcd` | Create a directory chain and `cd` into it | `mkcd .\src\app` |
| `Copy-CurrentPath` | Copy the current directory path to the clipboard | `Copy-CurrentPath` |
| `ccp` | Alias for `Copy-CurrentPath` | `ccp` |
| `Extract-File` | Unpack an archive with 7-Zip (`Expand-Archive` fallback) | `Extract-File -Path .\payload.zip` |
| `Compress-Dir` | Zip or tarball a folder with a timestamped name | `Compress-Dir -Path .\dist -Format zip` |

### 7-Zip archives

| Command | Description | Example |
| --- | --- | --- |
| `Get-7Zip` | Resolve `7z` / `7za` on PATH | `Get-7Zip` |
| `Get-7ZipList` / `zls` | List archive members (`7z l -slt`) | `Get-7ZipList -Path .\payload.7z` |
| `Test-7ZipArchive` / `ztest` | Test archive integrity (`7z t`) | `Test-7ZipArchive -Path .\payload.7z` |
| `New-7ZipArchive` / `znew` | Create an archive (`7z a`) | `New-7ZipArchive -Destination .\dist.7z -Path .\src` |
| `Add-7ZipItem` / `zadd` | Add files to an existing archive | `Add-7ZipItem -Archive .\dist.7z -Path .\notes.txt` |
| `Remove-7ZipItem` / `zrm` | Delete members by inner path (`7z d`) | `Remove-7ZipItem -Archive .\dist.7z -Item 'src\*.tmp'` |
| `Expand-7ZipArchive` / `zx` | Extract with destination, password, filters | `Expand-7ZipArchive -Path .\payload.7z -Destination .\out -Force` |

### Environment

| Command | Description | Example |
| --- | --- | --- |
| `Get-EnvPath` | Deduplicated User / Machine / Session PATH | `Get-EnvPath` |
| `Add-EnvPath` | Permanently add a directory to User PATH | `Add-EnvPath -Directory C:\tools\bin` |
| `Update-AllTheThings` | Update Scoop apps, PowerShell modules, winget | `Update-AllTheThings` |

### Crypto and encoding

| Command | Description | Example |
| --- | --- | --- |
| `New-GuidStr` | Generate a GUID, print it, copy to clipboard | `New-GuidStr` |
| `New-Password` | CSPRNG password (optional `-Copy`) | `New-Password -Length 24 -Copy` |
| `New-SshKeyStr` | ED25519 key, ssh-agent, copy the public key | `New-SshKeyStr` |
| `Verify-Checksum` | Compare a file hash to a published digest | `Verify-Checksum -Path .\app.zip -Hash ABCDEF1234` |
| `ConvertTo-Base64` | Base64-encode a string or file | `'hello' \| ConvertTo-Base64` |
| `ConvertFrom-Base64` | Decode Base64 to text (or `-AsBytes` / `-OutFile`) | `'aGVsbG8=' \| ConvertFrom-Base64` |

### JSON, env files, Neovim

| Command | Description | Example |
| --- | --- | --- |
| `Get-JsonPretty` | Indent and colorize JSON | `'{"a":1}' \| Get-JsonPretty` |
| `Get-DotEnvDiff` | Diff two `.env` files (added / removed / changed) | `Get-DotEnvDiff -Left .env -Right .env.staging` |
| `Show-NvimKeymaps` | Print or `-Edit` the setup-seeded `keymaps.lua` | `Show-NvimKeymaps` |

### Docker

| Command | Description | Example |
| --- | --- | --- |
| `dprune` | Prune dangling containers, images, and volumes (not `-a`) | `dprune` |
| `dco` | `docker compose` (v2) with `docker-compose` v1 fallback | `dco ps` |

### Git

| Command | Description | Example |
| --- | --- | --- |
| `glog` | Pretty commit graph (all branches) | `glog` |
| `gundo` | Soft-reset the previous commit (keeps changes staged) | `gundo` |
| `gclean` | Delete local branches already merged into main/master | `gclean` |
| `gquick` | `git add -A`, commit, push | `gquick 'fix: handle empty body'` |
| `gwip` | Commit all current changes as a WIP checkpoint | `gwip` |
| `gunwip` | Soft-reset the latest `gwip` commit | `gunwip` |
| `gswitch` | Interactive `fzf` branch switcher | `gswitch` |

### Java

| Command | Description | Example |
| --- | --- | --- |
| `Get-JavaProcesses` | Running JVMs with PID, main class, memory | `Get-JavaProcesses` |
| `Get-JavaHome` | List installed JDKs; mark the active `JAVA_HOME` | `Get-JavaHome` |
| `Set-JavaHome` | Switch session JDK (`JAVA_HOME` + `PATH`) | `Set-JavaHome 21` |
| `Switch-Jdk` | Same as `Set-JavaHome` (interactive if no argument) | `Switch-Jdk` |
| `jdk` | Alias for `Switch-Jdk` | `jdk 17` |

`Set-JavaHome` / `Switch-Jdk` look under Scoop and Program Files (Temurin, Corretto, Microsoft, BellSoft). Pass a version substring (`17`, `21`, `corretto`) or a full path. No argument lists JDKs and uses `fzf` when installed.

---

## Aliases

| Alias | Target |
| --- | --- |
| `clear` | `Clear-Host` |
| `ccp` | `Copy-CurrentPath` |
| `jdk` | `Switch-Jdk` |
| `Welcome-Banner` | `Show-WelcomeBanner` |
| `zls` | `Get-7ZipList` |
| `ztest` | `Test-7ZipArchive` |
| `znew` | `New-7ZipArchive` |
| `zadd` | `Add-7ZipItem` |
| `zrm` | `Remove-7ZipItem` |
| `zx` | `Expand-7ZipArchive` |

---

## Keyboard (interactive pwsh)

| Key | Action |
| --- | --- |
| Up / Down | History search |
| Ctrl+R | fzf command history (PSFzf) |
| Ctrl+T | fzf file search (PSFzf) |

---

## New machine checklist

1. Copy this folder onto the PC (or clone it).
2. Run `pwsh -NoProfile -File .\setup.ps1`.
3. Open a new Windows Terminal tab.
4. Run `Show-Commands` to confirm the profile loaded.
5. Delete this installer folder. The machine copies keep working.
