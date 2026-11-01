[CmdletBinding()]
param(
    [string]$Nvim,
    [switch]$SkipBootstrap,
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configDir = Join-Path $env:LOCALAPPDATA 'nvim'

function Add-UserPath([string]$Directory) {
    $Directory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $processEntries = @($env:PATH -split ';' | Where-Object { $_ })
    if (-not ($processEntries | Where-Object { $_.TrimEnd('\') -ieq $Directory })) {
        $env:PATH = $env:PATH.TrimEnd(';') + ';' + $Directory
    }
    $saved = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userEntries = @($saved -split ';' | Where-Object { $_ })
    if (-not ($userEntries | Where-Object { $_.TrimEnd('\') -ieq $Directory })) {
        $updated = ($userEntries + $Directory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-Host "Added to user PATH: $Directory"
    }
}

function Find-App([string]$Name) {
    $app = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app) { return $app.Source }
    return $null
}

function Require-App([string]$Name, [string]$Hint) {
    $found = Find-App $Name
    if (-not $found) { throw "Missing $Name. $Hint" }
    return $found
}

function Test-FdVersion([string]$Executable) {
    if (-not $Executable) { return $false }
    $fdVersion = (& $Executable --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $fdVersion -notmatch '^fd\s+(\d+\.\d+(?:\.\d+)?)') { return $false }
    return [version]$Matches[1] -ge [version]'8.4'
}

if (-not $Nvim) { $Nvim = Find-App 'nvim' }
if (-not $Nvim) {
    $candidate = Join-Path $env:ProgramFiles 'Neovim\bin\nvim.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $Nvim = $candidate }
}
if (-not $Nvim -or -not (Test-Path -LiteralPath $Nvim -PathType Leaf)) {
    throw 'Install Neovim 0.12.6 from https://github.com/neovim/neovim/releases/tag/v0.12.6, then pass -Nvim <path-to-nvim.exe>.'
}
$Nvim = (Resolve-Path -LiteralPath $Nvim).Path
$versionLine = @(& $Nvim --version)[0]
if ($LASTEXITCODE -ne 0 -or $versionLine -ne 'NVIM v0.12.6') {
    throw "Expected Neovim 0.12.6, found: $versionLine"
}
Add-UserPath (Split-Path -Parent $Nvim)
$localBin = Join-Path $env:LOCALAPPDATA 'my-nvim\bin'
if (Test-Path -LiteralPath $localBin -PathType Container) { Add-UserPath $localBin }
$cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if (Test-Path -LiteralPath $cargoBin -PathType Container) { Add-UserPath $cargoBin }

# Resolve local.lua before dependency checks, including private tool paths and proxies.
# A UTF-8 file avoids native-output encoding differences in Windows PowerShell 5.1.
$environmentFile = [IO.Path]::GetTempFileName()
try {
    & $Nvim --clean -l (Join-Path $PSScriptRoot 'environment.lua') json $environmentFile
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read local.lua installer environment.' }
    $machineEnvironment = Get-Content -LiteralPath $environmentFile -Raw -Encoding UTF8 | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $environmentFile -Force -ErrorAction SilentlyContinue
}
foreach ($entry in $machineEnvironment.environment.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, 'Process')
}

$null = Require-App 'git' 'Install Git for Windows.'
$null = Require-App 'rg' 'Install ripgrep and add its directory to PATH.'
$fd = Find-App 'fd'
if (-not (Test-FdVersion $fd)) {
    $fdHint = 'fd >=8.4 is required by Explorer. Run: winget install --id sharkdp.fd --exact --source winget --scope user'
    if ($SkipDependencyInstall) { throw $fdHint }
    $winget = Require-App 'winget' $fdHint
    & $winget install --id sharkdp.fd --exact --source winget --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "Cannot install fd through WinGet. $fdHint" }
    # Preserve local.lua PATH precedence while importing new user-level command aliases.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    foreach ($entry in @($userPath -split ';' | Where-Object { $_ })) {
        $directory = [Environment]::ExpandEnvironmentVariables($entry.Trim())
        if (-not (@($env:PATH -split ';') | Where-Object { $_.TrimEnd('\') -ieq $directory.TrimEnd('\') })) {
            $env:PATH = $env:PATH.TrimEnd(';') + ';' + $directory
        }
    }
    $fd = Find-App 'fd'
    if (-not (Test-FdVersion $fd)) { throw "fd is installed but PATH still selects a missing or old executable. $fdHint" }
}
$null = Require-App 'curl' 'Windows 10/11 includes curl.exe.'
$null = Require-App 'tar' 'Windows 10/11 includes tar.exe.'
$dotnet = Require-App $machineEnvironment.tools.dotnet 'Install the .NET 10 SDK or set dotnet in local.lua.'
$sdkList = @(& $dotnet --list-sdks)
if ($LASTEXITCODE -ne 0 -or -not ($sdkList | Where-Object { $_ -match '^10\.' })) {
    throw '.NET SDK 10 is required. Install it before running this script.'
}
$compiler = @('cl', 'clang', 'clang-cl', 'gcc', 'cc') | Where-Object { Find-App $_ } | Select-Object -First 1
if (-not $compiler) { throw 'A C compiler is required for Tree-sitter. Use an MSVC Developer PowerShell, or put clang/gcc on PATH.' }
$null = Require-App $machineEnvironment.tools.clangd 'Install clangd or set clangd in local.lua.'
$rustup = Require-App 'rustup' 'Install Rust through https://rustup.rs/.'
$components = @(& $rustup component list --installed)
if ($LASTEXITCODE -ne 0) { throw 'Cannot query the active rustup toolchain.' }
foreach ($component in @('rust-analyzer', 'rust-src')) {
    if (-not ($components | Where-Object { $_ -match ('^' + [regex]::Escape($component) + '(-|$)') })) {
        if ($SkipDependencyInstall) { throw "Missing rustup component $component. Run: rustup component add rust-analyzer rust-src" }
        & $rustup component add $component
        if ($LASTEXITCODE -ne 0) { throw "Failed to install rustup component $component." }
    }
}
$null = Require-App $machineEnvironment.tools.rust_analyzer 'Run: rustup component add rust-analyzer, or set rust_analyzer in local.lua.'

$treeSitter = Find-App 'tree-sitter'
$treeSitterOK = $false
if ($treeSitter) {
    $treeSitterVersion = (& $treeSitter --version | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $treeSitterVersion -match 'tree-sitter\s+(\d+\.\d+\.\d+)') {
        $treeSitterOK = [version]$Matches[1] -ge [version]'0.26.1'
    }
}
if (-not $treeSitterOK) {
    if ($SkipDependencyInstall) { throw 'tree-sitter CLI >=0.26.1 is required. Run: cargo install --locked --version 0.26.1 tree-sitter-cli' }
    $cargo = Require-App 'cargo' 'Install Rust through https://rustup.rs/.'
    & $cargo install --locked --version 0.26.1 tree-sitter-cli --force
    if ($LASTEXITCODE -ne 0) { throw 'Failed to install tree-sitter CLI 0.26.1.' }
    $null = Require-App 'tree-sitter' 'Add the cargo bin directory to PATH.'
}

$existing = Get-Item -LiteralPath $configDir -Force -ErrorAction SilentlyContinue
if ($existing) {
    if (-not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to replace existing configuration: $configDir. Move it to a backup location yourself, then rerun."
    }
    $target = @($existing.Target)[0]
    if (-not $target) { throw "Cannot resolve the existing configuration link: $configDir" }
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $configDir) $target }
    if ([IO.Path]::GetFullPath($target).TrimEnd('\') -ine $repo.TrimEnd('\')) {
        throw "Configuration link already points elsewhere: $configDir -> $target. Repoint it explicitly before rerunning."
    }
    Write-Host "Configuration link already active: $configDir -> $repo"
} else {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $configDir) -Force
    $null = New-Item -ItemType Junction -Path $configDir -Target $repo
    Write-Host "Created junction: $configDir -> $repo"
}

if (-not $SkipBootstrap) {
    & $Nvim --headless --cmd "let g:my_nvim_sync_plugins = 1" -c "lua dofile(vim.fn.stdpath('config') .. '/scripts/bootstrap.lua')"
    if ($LASTEXITCODE -ne 0) { throw 'Neovim bootstrap failed. Fix the reported dependency/network error and rerun; the script is safe to repeat.' }
}
Write-Host 'Neovim configuration installed. Open a new terminal and run nvim.'
