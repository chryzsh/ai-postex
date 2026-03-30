<#
.SYNOPSIS
    Build script for ai-postex DLLs.

.DESCRIPTION
    Sets up the build environment by symlinking the Arsenal Kit's postex base
    directory, builds the Rust static libraries, and invokes MSBuild to compile
    the credentialFinder and semanticSearch postex DLLs.

.PARAMETER ArsenalKitPath
    Path to the Arsenal Kit root (containing kits\postex\base\).

.PARAMETER Configuration
    Build configuration: Debug or Release. Default: Release.

.PARAMETER Platform
    Target platform: x64 or x86. Default: x64.

.PARAMETER RustOnly
    Only build the Rust static libraries, skip MSBuild.

.PARAMETER SkipRust
    Skip building Rust libraries (use if already built).

.EXAMPLE
    .\build.ps1 -ArsenalKitPath "C:\tools\arsenal-kit"
    .\build.ps1 -ArsenalKitPath "C:\tools\arsenal-kit" -Configuration Debug -Platform x64
    .\build.ps1 -ArsenalKitPath "C:\tools\arsenal-kit" -RustOnly
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ArsenalKitPath,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [ValidateSet("x64", "x86")]
    [string]$Platform = "x64",

    [switch]$RustOnly,
    [switch]$SkipRust
)

$ErrorActionPreference = "Stop"

# Resolve paths
$BuildDir = $PSScriptRoot
$RepoRoot = Split-Path $BuildDir -Parent
$BaseSource = Join-Path $ArsenalKitPath "kits\postex\base"
$BaseLink = Join-Path $BuildDir "base"

# Map platform to Rust target
$RustTargetMap = @{
    "x64" = "x86_64-pc-windows-msvc"
    "x86" = "i686-pc-windows-msvc"
}
$RustTarget = $RustTargetMap[$Platform]

# Map configuration to Rust profile
$RustProfile = if ($Configuration -eq "Debug") { "debug" } else { "release" }
$RustBuildFlag = if ($Configuration -eq "Release") { "--release" } else { "" }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ai-postex Build Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Arsenal Kit : $ArsenalKitPath"
Write-Host "  Config      : $Configuration"
Write-Host "  Platform    : $Platform ($RustTarget)"
Write-Host "  Repo root   : $RepoRoot"
Write-Host ""

# --- Step 1: Validate Arsenal Kit ---
Write-Host "[1/4] Validating Arsenal Kit..." -ForegroundColor Yellow

if (-not (Test-Path $BaseSource)) {
    Write-Error "Arsenal Kit postex base not found at: $BaseSource`nExpected: <ArsenalKitPath>\kits\postex\base\"
    exit 1
}

$RequiredHeaders = @("beacon.h", "debug.h", "dllmain.h", "macros.h", "mock.h", "pipes.h", "utils.h")
foreach ($h in $RequiredHeaders) {
    if (-not (Test-Path (Join-Path $BaseSource $h))) {
        Write-Error "Missing required header: $h in $BaseSource"
        exit 1
    }
}

Write-Host "  Arsenal Kit validated." -ForegroundColor Green

# --- Step 2: Create symlink for base/ ---
Write-Host "[2/4] Setting up base/ symlink..." -ForegroundColor Yellow

if (Test-Path $BaseLink) {
    $item = Get-Item $BaseLink -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-Host "  Symlink already exists, verifying target..."
        $target = (Get-Item $BaseLink).Target
        if ($target -ne $BaseSource) {
            Write-Warning "  Symlink points to '$target', expected '$BaseSource'. Recreating..."
            Remove-Item $BaseLink -Force
            New-Item -ItemType Junction -Path $BaseLink -Target $BaseSource | Out-Null
        }
    } else {
        Write-Error "  '$BaseLink' exists but is not a symlink. Remove it manually."
        exit 1
    }
} else {
    Write-Host "  Creating junction: base/ -> $BaseSource"
    New-Item -ItemType Junction -Path $BaseLink -Target $BaseSource | Out-Null
}

Write-Host "  Base symlink ready." -ForegroundColor Green

# --- Step 3: Build Rust static libraries ---
if (-not $SkipRust) {
    Write-Host "[3/4] Building Rust static libraries..." -ForegroundColor Yellow

    $RustCrates = @(
        (Join-Path $RepoRoot "credentialFinder\postex\rust-addons"),
        (Join-Path $RepoRoot "semanticSearch\rust_addons")
    )

    foreach ($crate in $RustCrates) {
        $crateName = Split-Path $crate -Leaf
        Write-Host "  Building $crateName for $RustTarget..."

        $buildArgs = @("build", "--target", $RustTarget)
        if ($Configuration -eq "Release") { $buildArgs += "--release" }

        Push-Location $crate
        try {
            & cargo @buildArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Rust build failed for $crateName"
                exit 1
            }
        } finally {
            Pop-Location
        }

        # Verify the .lib was produced
        $libPath = Join-Path $crate "target\$RustTarget\$RustProfile\rust_addons.lib"
        if (-not (Test-Path $libPath)) {
            Write-Error "Expected Rust library not found: $libPath"
            exit 1
        }
        Write-Host "  $crateName built: $libPath" -ForegroundColor Green
    }
} else {
    Write-Host "[3/4] Skipping Rust build (--SkipRust)" -ForegroundColor DarkGray
}

if ($RustOnly) {
    Write-Host "`nRust libraries built. Exiting (--RustOnly)." -ForegroundColor Green
    exit 0
}

# --- Step 4: MSBuild ---
Write-Host "[4/4] Building C++ projects with MSBuild..." -ForegroundColor Yellow

# Find MSBuild
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found. Is Visual Studio installed?"
    exit 1
}

$vsPath = & $vswhere -latest -requires Microsoft.Component.MSBuild -property installationPath
$msbuild = Join-Path $vsPath "MSBuild\Current\Bin\amd64\MSBuild.exe"
if (-not (Test-Path $msbuild)) {
    $msbuild = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
}
if (-not (Test-Path $msbuild)) {
    Write-Error "MSBuild.exe not found in Visual Studio installation."
    exit 1
}

Write-Host "  Using MSBuild: $msbuild"

# Map platform for MSBuild
$MSBuildPlatform = if ($Platform -eq "x86") { "Win32" } else { "x64" }

$slnPath = Join-Path $BuildDir "ai-postex.sln"

# Check for model COFF object (needed for semanticSearch)
$modelObj = Join-Path $RepoRoot "semanticSearch\models\model_onnx_smol.o"
if (-not (Test-Path $modelObj)) {
    Write-Warning "Model COFF object not found at: $modelObj"
    Write-Warning "semanticSearch will fail to link. See README for model preparation steps."
    Write-Warning "Building credentialFinder only..."

    & $msbuild $slnPath "/p:Configuration=$Configuration" "/p:Platform=$MSBuildPlatform" "/t:credentialFinder" "/m" "/v:minimal"
} else {
    & $msbuild $slnPath "/p:Configuration=$Configuration" "/p:Platform=$MSBuildPlatform" "/m" "/v:minimal"
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "MSBuild failed with exit code $LASTEXITCODE"
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Build complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green

# Show output locations
$outDir = Join-Path $BuildDir "$Configuration"
if (Test-Path $outDir) {
    Write-Host "  Output directory: $outDir"
    Get-ChildItem $outDir -Filter "*.dll" | ForEach-Object {
        Write-Host "    $($_.Name) ($([math]::Round($_.Length / 1MB, 2)) MB)" -ForegroundColor Cyan
    }
}
