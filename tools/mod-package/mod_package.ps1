param()

# Thin wrapper around tools/mod-package/mod_package.gd. Keeping the wrapper in
# the repo makes the signing workflow the same on a developer machine and in CI:
#
#   .\tools\mod-package\mod_package.ps1 keygen --publisher com.example --out Keys
#   .\tools\mod-package\mod_package.ps1 pack   --dir .\MyMod --out .\MyMod.gcm
#   .\tools\mod-package\mod_package.ps1 sign   --package .\MyMod.gcm --key .\Keys\com.example.private.json --out .\MyMod.signed.gcm
#   .\tools\mod-package\mod_package.ps1 verify --package .\MyMod.signed.gcm
#
# Set -Godot <path> to point at a different editor binary. The script takes no
# declared parameters because Windows PowerShell would otherwise try to bind
# the CLI's double-dash options (--out, --package, ...) as script parameters.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

$Godot = "C:\Godot\Godot.exe"
$forward = @()
$raw = @($args)
$index = 0
while ($index -lt $raw.Count) {
    $token = [string]$raw[$index]
    if ($token -eq "-Godot" -or $token -eq "--Godot") {
        if ($index + 1 -ge $raw.Count) {
            [Console]::Error.WriteLine("-Godot needs a path.")
            exit 2
        }
        $Godot = [string]$raw[$index + 1]
        $index += 2
    } else {
        $forward += $token
        $index += 1
    }
}

if ($forward.Count -lt 1) {
    [Console]::Error.WriteLine("usage: tools/mod-package/mod_package.ps1 <keygen|pack|sign|digest|verify> [options]")
    exit 2
}

$Command = [string]$forward[0]
$cli = @()
if ($forward.Count -gt 1) {
    $cli = $forward[1..($forward.Count - 1)]
}

if (!(Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot. Pass -Godot <path> or install it at C:\Godot\Godot.exe."
}

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $Godot
$start.WorkingDirectory = $root
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true

$allArguments = @("--headless", "--path", ".", "--script", "res://tools/mod-package/mod_package.gd", "--", $Command) + $cli
# Windows PowerShell runs on .NET Framework, which has no ArgumentList. Quote
# every argument so paths with spaces survive the join into Arguments.
$quoted = foreach ($argument in $allArguments) {
    '"' + ([string]$argument).Replace('"', '\"') + '"'
}
$start.Arguments = $quoted -join ' '

$run = [System.Diagnostics.Process]::Start($start)
$stdout = $run.StandardOutput.ReadToEnd()
$stderr = $run.StandardError.ReadToEnd()
$run.WaitForExit()

if (![string]::IsNullOrEmpty($stdout)) {
    Write-Host $stdout.TrimEnd()
}
if (![string]::IsNullOrEmpty($stderr)) {
    [Console]::Error.WriteLine($stderr.TrimEnd())
}
exit $run.ExitCode
