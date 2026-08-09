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

$env:SDKROOT = $experimentalSDK
swift build --scratch-path $ScratchPath -c $Configuration -Xswiftc -static-stdlib
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$binary = Join-Path $ScratchPath "x86_64-unknown-windows-msvc/$Configuration/ripgrep.exe"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "The static ripgrep executable was not produced at $binary"
}

$item = Get-Item -LiteralPath $binary
Write-Host "Static Windows executable: $($item.FullName) ($($item.Length) bytes)"
