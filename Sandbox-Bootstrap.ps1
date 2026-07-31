#requires -version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$read = 'C:\Sandbox\Read'
$write = 'C:\Sandbox\Write'
$log = Join-Path $write 'sandbox-bootstrap.log'
New-Item -ItemType Directory -Path $write -Force | Out-Null
Start-Transcript -Path $log -Force | Out-Null

try {
    Write-Host 'Installing the host-matched ProjFS binaries inside Windows Sandbox...'
    Copy-Item -LiteralPath (Join-Path $read 'prjflt.sys') -Destination "$env:SystemRoot\System32\drivers\prjflt.sys" -Force
    Copy-Item -LiteralPath (Join-Path $read 'ProjectedFSLib.dll') -Destination "$env:SystemRoot\System32\ProjectedFSLib.dll" -Force

    Write-Host 'Importing the PrjFlt minifilter service registration...'
    & reg.exe import (Join-Path $read 'PrjFlt-service.reg') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'reg.exe failed to import PrjFlt-service.reg.' }

    Write-Host 'Loading the ProjFS minifilter manually...'
    $filterList = (& fltmc.exe filters 2>&1 | Out-String)
    if ($filterList -notmatch '(?im)PrjFlt|ProjFS') {
        & fltmc.exe load PrjFlt 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            & sc.exe start PrjFlt 2>&1 | Out-Host
        }
    }

    $filterList = (& fltmc.exe filters 2>&1 | Out-String)
    $filterList | Set-Content -LiteralPath (Join-Path $write 'fltmc-filters.txt')
    if ($filterList -notmatch '(?im)PrjFlt|ProjFS') {
        throw 'The ProjFS minifilter did not appear in fltmc filters. See sandbox-bootstrap.log.'
    }

    $root = 'C:\ProjFSRoot'
    if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    Write-Host 'Starting the basic ProjFS provider...'
    $providerScript = Join-Path $read 'BasicProjFSProvider.ps1'
    $providerLog = Join-Path $write 'provider-console.log'
    $providerErr = Join-Path $write 'provider-error.log'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $providerScript),
        '-Root', ('"{0}"' -f $root),
        '-LogPath', ('"{0}"' -f (Join-Path $write 'provider.log'))
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Minimized -PassThru -RedirectStandardOutput $providerLog -RedirectStandardError $providerErr
    $process.Id | Set-Content -LiteralPath (Join-Path $write 'provider.pid')

    $hello = Join-Path $root 'hello.txt'
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $hello)) {
        if ($process.HasExited) { throw "Provider exited early with code $($process.ExitCode). See $providerErr" }
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Path $hello)) { throw 'Timed out waiting for the projected hello.txt placeholder.' }

    Write-Host 'Hydrating projected file...'
    $content = Get-Content -LiteralPath $hello -Raw
    $content | Set-Content -LiteralPath (Join-Path $write 'hydrated-hello.txt')

    Write-Host ''
    Write-Host 'ProjFS provider is running.' -ForegroundColor Green
    Write-Host "Virtualization root: $root"
    Write-Host "Projected file:      $hello"
    Write-Host "Hydrated content:    $content"
    Start-Process explorer.exe -ArgumentList $root
}
catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $write 'FAILED.txt')
    Write-Error $_
    Start-Process notepad.exe -ArgumentList (Join-Path $write 'FAILED.txt')
}
finally {
    Stop-Transcript | Out-Null
}
