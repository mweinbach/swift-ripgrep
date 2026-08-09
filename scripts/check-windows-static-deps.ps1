[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Launcher,
    [Parameter(Mandatory = $true)]
    [string]$Backend
)

$ErrorActionPreference = "Stop"
$readObject = Get-Command llvm-readobj.exe -ErrorAction Stop
$forbidden = '(?i)(swift[^\\/]*\.dll|foundation[^\\/]*\.dll|dispatch\.dll|blocksruntime\.dll)'

foreach ($path in @($Launcher, $Backend)) {
    $resolved = Resolve-Path -LiteralPath $path -ErrorAction Stop
    $imports = & $readObject.Source --coff-imports $resolved
    if ($LASTEXITCODE -ne 0) {
        throw "llvm-readobj failed for $resolved"
    }
    $matches = $imports | Select-String -Pattern $forbidden
    if ($matches) {
        throw "Static Windows artifact imports a Swift runtime DLL: $resolved`n$matches"
    }
    Write-Host "No Swift runtime DLL imports: $resolved"
}
