# Windows per-user Native Messaging registration (does not need Administrator).
# Run from the EXTRACTED JDM Windows release folder. See README.md.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Chrome', 'Edge', 'Firefox')]
    [string]$Browser,
    [string]$ExtensionId = '',
    [string]$NativeHostExe = (Join-Path $PSScriptRoot '..\jdm_native_host.exe')
)

$ErrorActionPreference = 'Stop'
$resolvedHost = (Resolve-Path -LiteralPath $NativeHostExe).Path
if ([System.IO.Path]::GetExtension($resolvedHost).ToLowerInvariant() -ne '.exe') {
    throw 'NativeHostExe must point to the compiled jdm_native_host.exe.'
}

$hostName = 'com.jahidul.jdm'
$manifestDirectory = Join-Path $env:LOCALAPPDATA 'JahidDownloadManager\NativeMessaging'
[System.IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null

switch ($Browser) {
    'Chrome' {
        if ($ExtensionId -cnotmatch '^[a-p]{32}$') {
            throw 'Supply the real 32-letter Chrome extension ID (chrome://extensions).'
        }
        $manifestFile = Join-Path $manifestDirectory 'chrome-host.json'
        $registryKey = "HKCU\Software\Google\Chrome\NativeMessagingHosts\$hostName"
        $manifest = @{
            name = $hostName
            description = 'Jahid Download Manager browser bridge'
            path = $resolvedHost
            type = 'stdio'
            allowed_origins = @("chrome-extension://$ExtensionId/")
        }
    }
    'Edge' {
        if ($ExtensionId -cnotmatch '^[a-p]{32}$') {
            throw 'Supply the real 32-letter Edge extension ID (edge://extensions).'
        }
        $manifestFile = Join-Path $manifestDirectory 'edge-host.json'
        $registryKey = "HKCU\Software\Microsoft\Edge\NativeMessagingHosts\$hostName"
        $manifest = @{
            name = $hostName
            description = 'Jahid Download Manager browser bridge'
            path = $resolvedHost
            type = 'stdio'
            allowed_origins = @("chrome-extension://$ExtensionId/")
        }
    }
    'Firefox' {
        $manifestFile = Join-Path $manifestDirectory 'firefox-host.json'
        $registryKey = "HKCU\Software\Mozilla\NativeMessagingHosts\$hostName"
        $manifest = @{
            name = $hostName
            description = 'Jahid Download Manager browser bridge'
            path = $resolvedHost
            type = 'stdio'
            allowed_extensions = @('jdm-bridge@jahidul.app')
        }
    }
}

$json = $manifest | ConvertTo-Json -Depth 5
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestFile, $json, $utf8NoBom)

& reg.exe add $registryKey /ve /t REG_SZ /d $manifestFile /f | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Windows registry registration failed: $LASTEXITCODE" }

Write-Host "Registered $Browser native host for current user." -ForegroundColor Green
Write-Host "Executable: $resolvedHost"
Write-Host "Manifest:   $manifestFile"
Write-Host 'Keep the extracted JDM release folder in this location and restart the browser.'
