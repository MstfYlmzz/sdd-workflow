#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $InstallDir = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'sdd-workflow/bin' } else { Join-Path $HOME '.local/bin' }),
    [switch] $NoPath,
    [switch] $Uninstall
)
$ErrorActionPreference='Stop'
$repoRoot=$PSScriptRoot
$launcher=Join-Path $repoRoot 'bin/sdd.ps1'
$cmdPath=Join-Path $InstallDir 'sdd.cmd'
$psPath=Join-Path $InstallDir 'sdd.ps1'

if($Uninstall){
    Remove-Item -LiteralPath $cmdPath,$psPath -Force -ErrorAction SilentlyContinue
    if(-not$NoPath){
        $userPath=[Environment]::GetEnvironmentVariable('Path','User')
        $parts=@($userPath-split';'|Where-Object{$_-and$_.TrimEnd('\')-ne$InstallDir.TrimEnd('\')})
        [Environment]::SetEnvironmentVariable('Path',($parts-join';'),'User')
    }
    Write-Host "SDD komut bağlantısı kaldırıldı: $InstallDir" -ForegroundColor Yellow
    return
}
if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){throw "SDD launcher bulunamadı: $launcher"}
if(-not(Get-Command pwsh -ErrorAction SilentlyContinue)){throw 'PowerShell 7 (pwsh) PATH üzerinde bulunamadı.'}
New-Item -ItemType Directory -Path $InstallDir -Force|Out-Null
$escaped=$launcher.Replace("'","''")
@"
#requires -Version 7.0
& '$escaped' @args
exit `$LASTEXITCODE
"@|Set-Content -LiteralPath $psPath -Encoding utf8
@"
@echo off
pwsh -NoProfile -File "$psPath" %*
exit /b %ERRORLEVEL%
"@|Set-Content -LiteralPath $cmdPath -Encoding utf8

if(-not$NoPath){
    $userPath=[Environment]::GetEnvironmentVariable('Path','User')
    $parts=@($userPath-split';'|Where-Object{$_})
    if($InstallDir-notin$parts){
        [Environment]::SetEnvironmentVariable('Path',((@($parts)+@($InstallDir))-join';'),'User')
    }
    if($InstallDir-notin($env:Path-split';')){$env:Path="$InstallDir;$env:Path"}
}
Write-Host 'SDD global komutu kuruldu.' -ForegroundColor Green
Write-Host "  launcher : $launcher"
Write-Host "  command  : $cmdPath"
if(-not$NoPath){Write-Host "`nYeni terminal açıp 'sdd status' çalıştırabilirsiniz."}
