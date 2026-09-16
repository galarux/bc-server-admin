<#
.SYNOPSIS
    BC Server Admin - a web-based replacement for the Business Central Server Administration tool (MMC).

.DESCRIPTION
    Discovers every Business Central / Dynamics NAV server instance installed on this machine and opens a
    local web UI to:
      - start, stop and restart instances
      - view and edit CustomSettings.config (grouped like the old MMC tabs), with automatic backups
      - change the SQL credentials
      - list and end sessions, list tenants
      - read the instance event log
      - compare the configuration of two instances and export it (HTML, CSV, JSON)

    The web server only listens on http://localhost and requires a random per-run token.
    Administrator rights are required (the script elevates itself) except in -Demo mode and for -ExportPath.

.PARAMETER Port
    TCP port for the local web server. Default: a free random port.

.PARAMETER NoBrowser
    Do not open the browser automatically; the URL is printed in the console.

.PARAMETER Demo
    Runs with fictitious instances (no Business Central or admin rights needed).

.PARAMETER WorkerHost
    PowerShell used to load the BC management module:
      Auto              - Windows PowerShell for BC <= 23 and 29+, PowerShell 7 (if installed) for BC 24-28
      WindowsPowerShell - always powershell.exe
      PowerShell7       - always pwsh.exe

.PARAMETER BackupPath
    Folder for CustomSettings.config backups. Default: %ProgramData%\BCServerAdmin\backups

.PARAMETER ExportPath
    Export mode: writes the configuration of the instances to this folder and exits (no web server).

.PARAMETER Instance
    Export mode: instance name(s) to export. Default: all.

.PARAMETER Format
    Export mode: Html (default), Csv or Json.

.PARAMETER IncludeSecrets
    Export mode: include passwords/secrets instead of masking them.

.PARAMETER Language
    Export mode: language of the HTML report (en, es). Default: the Windows UI language.

.EXAMPLE
    .\Start-BCServerAdmin.ps1

.EXAMPLE
    .\Start-BCServerAdmin.ps1 -Demo

.EXAMPLE
    .\Start-BCServerAdmin.ps1 -ExportPath C:\Temp\bc -Instance BC252 -Format Html
#>
[CmdletBinding(DefaultParameterSetName = 'Server')]
param(
    [Parameter(ParameterSetName = 'Server')]
    [ValidateRange(0, 65535)]
    [int] $Port = 0,

    [Parameter(ParameterSetName = 'Server')]
    [switch] $NoBrowser,

    [switch] $Demo,

    [ValidateSet('Auto', 'WindowsPowerShell', 'PowerShell7')]
    [string] $WorkerHost = 'Auto',

    [string] $BackupPath = (Join-Path $env:ProgramData 'BCServerAdmin\backups'),

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [string] $ExportPath,

    [Parameter(ParameterSetName = 'Export')]
    [string[]] $Instance,

    [Parameter(ParameterSetName = 'Export')]
    [ValidateSet('Html', 'Csv', 'Json')]
    [string] $Format = 'Html',

    [Parameter(ParameterSetName = 'Export')]
    [switch] $IncludeSecrets,

    [Parameter(ParameterSetName = 'Export')]
    [ValidateSet('en', 'es')]
    [string] $Language
)

$ErrorActionPreference = 'Stop'

$sourceRoot = Join-Path $PSScriptRoot 'src'
. (Join-Path $sourceRoot 'Common.ps1')
. (Join-Path $sourceRoot 'Discovery.ps1')
. (Join-Path $sourceRoot 'Config.ps1')
. (Join-Path $sourceRoot 'Services.ps1')
. (Join-Path $sourceRoot 'WorkerClient.ps1')
. (Join-Path $sourceRoot 'Demo.ps1')
. (Join-Path $sourceRoot 'HttpServer.ps1')

$isExport = $PSCmdlet.ParameterSetName -eq 'Export'

if (-not $Demo -and -not $isExport -and -not (Test-BcsaAdministrator)) {
    # Relaunch elevated with the same PowerShell and parameters.
    Write-Host 'Administrator rights are required. Requesting elevation...' -ForegroundColor Yellow
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { $arguments += "-$($entry.Key)" }
        } else {
            $arguments += "-$($entry.Key)"
            $arguments += "`"$($entry.Value)`""
        }
    }
    $hostPath = (Get-Process -Id $PID).Path
    try {
        Start-Process -FilePath $hostPath -ArgumentList $arguments -Verb RunAs | Out-Null
    } catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit 0
}

Initialize-BcsaState -Demo:$Demo -BackupRoot $BackupPath -WorkerHost $WorkerHost -SourceRoot $sourceRoot

if ($isExport) {
    try {
        if (-not $Language) {
            $Language = 'en'
            if ((Get-UICulture).TwoLetterISOLanguageName -eq 'es') { $Language = 'es' }
        }
        # "-Instance A,B" arrives as a single string when the script is started with -File.
        $names = @($Instance | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $targets = @(Get-BcsaInstance | Where-Object { $names.Count -eq 0 -or $names -contains $_.name })
        foreach ($name in $names) {
            if (-not ($targets | Where-Object { $_.name -eq $name })) { Write-BcsaLog "Instance '$name' not found." -Level Warn }
        }
        if ($targets.Count -eq 0) { Write-BcsaLog 'No Business Central server instances to export.' -Level Warn; exit 1 }

        New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
        foreach ($target in $targets) {
            if (-not $target.configPath) { Write-BcsaLog "$($target.name): CustomSettings.config not found, skipped." -Level Warn; continue }
            $export = Export-BcsaConfiguration -Instance $target -Format $Format -IncludeSecrets:$IncludeSecrets -Language $Language
            $file = Join-Path $ExportPath $export.fileName
            [IO.File]::WriteAllText($file, $export.content, (New-Object System.Text.UTF8Encoding($true)))
            Write-BcsaLog "$($target.name): $file" -Level Ok
        }
    } finally {
        if ($Demo) { Remove-BcsaDemo }
    }
    exit 0
}

if ($Port -eq 0) { $Port = Get-BcsaFreePort }

if (-not $Demo) {
    # Load the BC management modules in the background so the first save/session query is fast.
    foreach ($group in @(Get-BcsaInstance | Where-Object { $_.serviceDir } | Group-Object serviceDir)) {
        try { [void](Start-BcsaWorker -ServiceDir $group.Name -Major $group.Group[0].major) } catch { Write-BcsaLog $_.Exception.Message -Level Warn }
    }
}

try {
    Start-BcsaHttpServer -Port $Port -WebRoot (Join-Path $PSScriptRoot 'web') -NoBrowser:$NoBrowser
} catch {
    Write-BcsaLog $_.Exception.Message -Level Error
    if ($_.Exception -is [System.Net.HttpListenerException]) {
        Write-BcsaLog "Could not listen on http://localhost:$Port/. Try another port with -Port." -Level Error
    }
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
