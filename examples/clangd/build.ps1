param(
    [ValidateSet('clang', 'clang-cl', 'msvc')]
    [string]$Toolchain = 'clang'
)

# This is a normal manual build: no CMake, plugin, or build-system integration.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$compilerName = switch ($Toolchain) {
    'clang' { 'clang++.exe' }
    'clang-cl' { 'clang-cl.exe' }
    'msvc' { 'cl.exe' }
}
$compiler = Get-Command $compilerName -ErrorAction SilentlyContinue
if (!$compiler) {
    throw "Cannot find $compilerName. Put it on PATH; for MSVC use a Developer PowerShell."
}
$source = Join-Path $PSScriptRoot 'main.cpp'
$buildDirectory = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$object = Join-Path $buildDirectory 'main.obj'
$program = Join-Path $buildDirectory 'example.exe'

if ($Toolchain -eq 'clang') {
    $compileArguments = @('-std=c++20', '-Wall', '-Wextra', '-g', '-DDEMO_BUILD=1', '-c', $source, '-o', $object)
    $linkArguments = @($object, '-o', $program)
} else {
    $compileArguments = @('/nologo', '/std:c++20', '/W4', '/EHsc', '/Zi', '/DDEMO_BUILD=1', '/c', $source, "/Fo$object", "/Fd$(Join-Path $buildDirectory 'example.pdb')")
    $linkArguments = @('/nologo', $object, "/Fe$program")
}

# Record exactly the command used by this build, with an arguments array so spaces
# in compiler/source paths work without constructing or re-parsing shell strings.
$database = @(@{
    directory = $PSScriptRoot
    file = $source
    arguments = @($compiler.Source) + $compileArguments
})
$databaseJson = ConvertTo-Json -InputObject $database -Depth 8
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'compile_commands.json'), $databaseJson + "`n", [System.Text.UTF8Encoding]::new($false))

Push-Location $PSScriptRoot
try {
    & $compiler.Source @compileArguments
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed with status $LASTEXITCODE." }
    & $compiler.Source @linkArguments
    if ($LASTEXITCODE -ne 0) { throw "Linking failed with status $LASTEXITCODE." }
    Write-Host "Built $program; clangd can use compile_commands.json immediately."
} finally {
    Pop-Location
}
