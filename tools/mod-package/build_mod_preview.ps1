[CmdletBinding()]
param(
    [ValidateSet("Windows", "Linux", "All")]
    [string]$Platform = "Windows",

    [string]$Godot = "C:\Godot\Godot.exe",

    [string]$OutputRoot = "Builds/Preview"
)

# Test-gated local export for the Developer Preview. The normal release workflow
# intentionally does NOT use these presets: a stable tag must not silently ship
# preview-only behavior.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

if (!(Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot"
}

if (!(Test-Path -LiteralPath "export_presets.cfg")) {
    throw "export_presets.cfg is missing; run from the project root."
}

Write-Host "Running the headless gate before exporting..."
$stdout = Join-Path $env:TEMP "griddy-preview-tests.log"
$stderr = Join-Path $env:TEMP "griddy-preview-tests.err"
$test = Start-Process -FilePath $Godot `
    -ArgumentList '--headless', '--path', '.', '--script', 'res://tests/test_runner.gd' `
    -Wait -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr

if ($test.ExitCode -ne 0) {
    Get-Content -LiteralPath $stdout -Tail 60
    Get-Content -LiteralPath $stderr -Tail 20
    throw "Headless suite failed with exit code $($test.ExitCode); refusing to export."
}

Get-Content -LiteralPath $stdout -Tail 3

$targets = @()
if ($Platform -eq "Windows" -or $Platform -eq "All") {
    $targets += @{
        Preset = "Windows Developer Preview"
        Path = Join-Path $OutputRoot "Windows/Qorix-Preview.exe"
    }
}
if ($Platform -eq "Linux" -or $Platform -eq "All") {
    $targets += @{
        Preset = "Linux/X11 Developer Preview"
        Path = Join-Path $OutputRoot "Linux/Qorix-Preview.x86_64"
    }
}

$hashes = @()
foreach ($target in $targets) {
    $declared = Select-String -LiteralPath "export_presets.cfg" `
        -Pattern ('name="' + $target.Preset + '"') -SimpleMatch
    if ($null -eq $declared) {
        throw "Export preset not found: $($target.Preset)"
    }

    $parent = Split-Path -Parent $target.Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    # Never accept a stale artifact from an earlier run.
    if (Test-Path -LiteralPath $target.Path) {
        Remove-Item -LiteralPath $target.Path -Force
    }

    Write-Host "Exporting $($target.Preset) -> $($target.Path)"
    $stdout = Join-Path $env:TEMP ("griddy-preview-export-" + [guid]::NewGuid().ToString("N") + ".log")
    $stderr = Join-Path $env:TEMP ("griddy-preview-export-" + [guid]::NewGuid().ToString("N") + ".err")
    # Start-Process is required on Windows: the GUI-subsystem Godot executable is
    # not awaited by `&`, and an ArgumentList array would split the preset name at
    # its space. The quoted single string keeps the preset and path intact.
    $arguments = '--headless --path . --export-release "' + $target.Preset + '" "' + $target.Path + '"'
    $export = Start-Process -FilePath $Godot -ArgumentList $arguments `
        -Wait -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $artifact = Test-Path -LiteralPath $target.Path
    $completed = $null -ne (
        Select-String -LiteralPath $stdout -Pattern '[ DONE ]' -SimpleMatch
    )
    if ($export.ExitCode -ne 0) {
        # Godot 4.7.2 on Windows can raise an access violation while tearing down
        # the editor after savepack. The artifact is already complete when the
        # completion marker and a non-empty file are both present; accept that
        # known shutdown crash, but never a crash before the pack was written.
        if (!($completed -and $artifact)) {
            Get-Content -LiteralPath $stdout -Tail 60
            Get-Content -LiteralPath $stderr -Tail 20
            throw "Export failed for $($target.Preset) with exit code $($export.ExitCode)."
        }
        Write-Warning "Godot exited with 0x$('{0:X8}' -f $export.ExitCode) after savepack; the artifact is complete (known 4.7.2 Windows shutdown crash)."
    }
    if (!$artifact) {
        Get-Content -LiteralPath $stdout -Tail 40
        throw "Export reported success but the artifact is missing: $($target.Path)"
    }
    if ((Get-Item -LiteralPath $target.Path).Length -le 0) {
        throw "Export produced an empty artifact: $($target.Path)"
    }

    $hash = (Get-FileHash -LiteralPath $target.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashes += [PSCustomObject]@{
        Preset = $target.Preset
        Artifact = $target.Path
        SHA256 = $hash
    }
}

Write-Host ""
Write-Host "Preview artifacts (integrity only; not publisher signatures):"
$hashes | Format-Table -AutoSize
$hashes | ForEach-Object {
    Write-Host ("{0}  {1}" -f $_.SHA256, $_.Artifact)
}
Write-Host ""
Write-Host "Label the download as a Developer Preview and link docs/mods/known-issues.md."
