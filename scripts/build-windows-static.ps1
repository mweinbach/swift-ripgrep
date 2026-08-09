[CmdletBinding()]
param(
    [ValidateSet("release", "debug")]
    [string]$Configuration = "release",
    [string]$ScratchPath = ".build/windows-static"
)

$ErrorActionPreference = "Stop"

if ($env:SDKROOT -and $env:SDKROOT.EndsWith("WindowsExperimental.sdk")) {
    $experimentalSDK = $env:SDKROOT
} else {
    $experimentalSDK = $null
    if ($env:SDKROOT) {
        $sdkDirectory = Split-Path -Parent $env:SDKROOT
        $siblingSDK = Join-Path $sdkDirectory "WindowsExperimental.sdk"
        if (Test-Path -LiteralPath $siblingSDK -PathType Container) {
            $experimentalSDK = $siblingSDK
        }
    }

    if (-not $experimentalSDK) {
        $swiftPath = (Get-Command swift -ErrorAction Stop).Source
        $swiftInstallRoot = Split-Path -Parent (
            Split-Path -Parent (
                Split-Path -Parent (
                    Split-Path -Parent $swiftPath
                )
            )
        )
        $platformRoots = @(
            (Join-Path $env:LOCALAPPDATA "Programs/Swift/Platforms"),
            (Join-Path $swiftInstallRoot "Platforms"),
            (Join-Path $env:SystemDrive "Library/Developer/Platforms")
        ) | Select-Object -Unique
        foreach ($platformsRoot in $platformRoots) {
            if (-not (Test-Path -LiteralPath $platformsRoot -PathType Container)) {
                continue
            }
            $experimentalSDK = Get-ChildItem -LiteralPath $platformsRoot -Directory -Recurse -Filter "WindowsExperimental.sdk" |
                Sort-Object FullName -Descending |
                Select-Object -First 1 -ExpandProperty FullName
            if ($experimentalSDK) {
                break
            }
        }
    }
}

if (-not $experimentalSDK -or -not (Test-Path -LiteralPath $experimentalSDK -PathType Container)) {
    throw "WindowsExperimental.sdk was not found. Install a Swift toolchain that includes the static Windows SDK."
}

$staticLibraryPath = Join-Path $experimentalSDK "usr/lib/swift_static/windows/x86_64"
if (-not (Test-Path -LiteralPath $staticLibraryPath -PathType Container)) {
    throw "The experimental SDK does not contain x86-64 static Swift libraries: $staticLibraryPath"
}

$compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $compiler) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw "cl.exe is not on PATH and vswhere.exe was not found"
    }
    $visualStudio = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $developerCommand = Join-Path $visualStudio "Common7/Tools/VsDevCmd.bat"
    if (-not $visualStudio -or -not (Test-Path -LiteralPath $developerCommand -PathType Leaf)) {
        throw "A Visual Studio installation with the x64 C++ tools was not found"
    }
    $developerEnvironment = cmd.exe /d /c "`"$developerCommand`" -arch=x64 >nul && set"
    foreach ($line in $developerEnvironment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    $compiler = Get-Command cl.exe -ErrorAction Stop
}

$env:SDKROOT = $experimentalSDK
$binary = Join-Path $ScratchPath "x86_64-unknown-windows-msvc/$Configuration/ripgrep.exe"
$backend = Join-Path $ScratchPath "x86_64-unknown-windows-msvc/$Configuration/ripgrep-swift.exe"
if ((Test-Path -LiteralPath $backend -PathType Leaf) -and
    (Test-Path -LiteralPath (Split-Path -Parent $binary) -PathType Container)) {
    # Restore the Swift link product before an incremental build. The script
    # replaces ripgrep.exe with the native front end after SwiftPM finishes.
    Copy-Item -LiteralPath $backend -Destination $binary -Force
}
swift build --scratch-path $ScratchPath -c $Configuration -Xswiftc -static-stdlib
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "The static ripgrep executable was not produced at $binary"
}

$source = Join-Path $PSScriptRoot "../Sources/CWindowsLauncher/main.c"
$avx2Source = Join-Path $PSScriptRoot "../Sources/CWindowsLauncher/scan_avx2.c"
$binaryDirectory = Split-Path -Parent $binary
$object = Join-Path $binaryDirectory "windows-launcher.obj"
$avx2Object = Join-Path $binaryDirectory "windows-launcher-avx2.obj"
Copy-Item -LiteralPath $binary -Destination $backend -Force
& $compiler.Source /nologo /c /O2 /GL /arch:AVX2 /MT /W4 "/Fo$avx2Object" $avx2Source
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& $compiler.Source /nologo /O2 /GL /MT /W4 /DUNICODE /D_UNICODE "/Fo$object" $source $avx2Object "/Fe$binary" /link /LTCG /OPT:REF /OPT:ICF
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or
    -not (Test-Path -LiteralPath $backend -PathType Leaf)) {
    throw "The native launcher or Swift backend was not produced"
}

$item = Get-Item -LiteralPath $binary
$backendItem = Get-Item -LiteralPath $backend
Write-Host "Static Windows launcher: $($item.FullName) ($($item.Length) bytes)"
Write-Host "Static Swift backend: $($backendItem.FullName) ($($backendItem.Length) bytes)"
