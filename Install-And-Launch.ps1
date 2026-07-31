#requires -version 5.1
[CmdletBinding()]
param(
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    if ($NoLaunch) { $argList += '-NoLaunch' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

$packageRoot = Split-Path -Parent $PSCommandPath
$base = 'C:\Sandbox'
$read = Join-Path $base 'Read'
$write = Join-Path $base 'Write'
$wsb = Join-Path $base 'ProjFS-Sandbox.wsb'

New-Item -ItemType Directory -Path $read, $write -Force | Out-Null

Write-Host '[1/5] Ensuring Windows Projected File System is enabled on the host...'
$feature = Get-WindowsOptionalFeature -Online -FeatureName 'Client-ProjFS'
if ($feature.State -ne 'Enabled') {
    $result = Enable-WindowsOptionalFeature -Online -FeatureName 'Client-ProjFS' -All -NoRestart
    if ($result.RestartNeeded) {
        Write-Warning 'ProjFS was enabled, but Windows requires a restart. Restart the host, then run this script again.'
        exit 3010
    }
}

$driver = Join-Path $env:SystemRoot 'System32\drivers\prjflt.sys'
$dll = Join-Path $env:SystemRoot 'System32\ProjectedFSLib.dll'
if (-not (Test-Path $driver)) { throw "ProjFS driver was not found at $driver" }
if (-not (Test-Path $dll)) { throw "ProjFS DLL was not found at $dll" }

Write-Host '[2/5] Copying ProjFS driver, DLL, and sandbox payload to C:\Sandbox\Read...'
Copy-Item -LiteralPath $driver -Destination $read -Force
Copy-Item -LiteralPath $dll -Destination $read -Force
Copy-Item -LiteralPath (Join-Path $packageRoot 'Sandbox-Bootstrap.ps1') -Destination $read -Force
Copy-Item -LiteralPath (Join-Path $packageRoot 'BasicProjFSProvider.ps1') -Destination $read -Force

Write-Host '[3/5] Exporting the host-matched PrjFlt minifilter service registration...'
$serviceKey = 'HKLM\SYSTEM\CurrentControlSet\Services\PrjFlt'
$regFile = Join-Path $read 'PrjFlt-service.reg'
& reg.exe query $serviceKey *> $null
if ($LASTEXITCODE -ne 0) {
    throw "The $serviceKey registry key does not exist. Enable ProjFS and restart Windows before retrying."
}
& reg.exe export $serviceKey $regFile /y | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to export the PrjFlt service registry key.' }

Write-Host '[4/5] Creating the Windows Sandbox configuration...'
$wsbXml = @'
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Enable</ClipboardRedirection>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>C:\Sandbox\Read</HostFolder>
      <SandboxFolder>C:\Sandbox\Read</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>C:\Sandbox\Write</HostFolder>
      <SandboxFolder>C:\Sandbox\Write</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Sandbox\Read\Sandbox-Bootstrap.ps1</Command>
  </LogonCommand>
</Configuration>
'@
Set-Content -LiteralPath $wsb -Value $wsbXml -Encoding UTF8

Write-Host '[5/5] Host preparation complete.' -ForegroundColor Green
Write-Host "Read-only payload: $read"
Write-Host "Sandbox output:    $write"
Write-Host "Sandbox config:    $wsb"

if (-not $NoLaunch) {
    Write-Host 'Launching Windows Sandbox...'
    Start-Process -FilePath $wsb
}
