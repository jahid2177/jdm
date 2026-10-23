# Removes only this user's selected JDM Native Messaging registration.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Chrome', 'Edge', 'Firefox')]
    [string]$Browser
)
$ErrorActionPreference = 'Stop'
$hostName = 'com.jahidul.jdm'
$prefix = switch ($Browser) {
    'Chrome' { 'Google\Chrome' }
    'Edge' { 'Microsoft\Edge' }
    'Firefox' { 'Mozilla' }
}
$key = "HKCU\Software\$prefix\NativeMessagingHosts\$hostName"
& reg.exe query $key *> $null
if ($LASTEXITCODE -eq 0) {
    & reg.exe delete $key /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the JDM native host key.' }
}
$manifestName = switch ($Browser) {
    'Chrome' { 'chrome-host.json' }
    'Edge' { 'edge-host.json' }
    'Firefox' { 'firefox-host.json' }
}
$manifestFile = Join-Path $env:LOCALAPPDATA "JahidDownloadManager\NativeMessaging\$manifestName"
if (Test-Path -LiteralPath $manifestFile) { Remove-Item -LiteralPath $manifestFile -Force }
Write-Host "Removed the $Browser JDM native host registration." -ForegroundColor Green
