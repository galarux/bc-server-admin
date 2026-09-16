# Windows service control and event log access.
# Service actions never block the HTTP loop: Start()/Stop() return immediately and restarts
# are completed by Update-BcsaPendingAction, which the server calls while it is idle.

$script:BcsaPending = @{}

function Get-BcsaPendingAction {
    param([string] $Name)
    if ($script:BcsaPending.ContainsKey($Name)) { return $script:BcsaPending[$Name].action }
    return $null
}

function Invoke-BcsaServiceAction {
    param($Instance, [ValidateSet('start', 'stop', 'restart')] [string] $Action)

    if ($script:Bcsa.Demo) { return Invoke-BcsaDemoServiceAction -Instance $Instance -Action $Action }

    $service = Get-Service -Name $Instance.serviceName -ErrorAction Stop
    $status = [string]$service.Status
    try {
        switch ($Action) {
            'start' {
                if ($status -ne 'Stopped') { Stop-BcsaRequest 409 'invalid_state' "The service is $status." }
                $service.Start()
            }
            'stop' {
                if ($status -eq 'Stopped' -or $status -eq 'StopPending') { Stop-BcsaRequest 409 'invalid_state' "The service is $status." }
                $service.Stop()
                $script:BcsaPending.Remove($Instance.name)
            }
            'restart' {
                if ($status -eq 'Stopped') {
                    $service.Start()
                } else {
                    if ($status -ne 'StopPending') { $service.Stop() }
                    $script:BcsaPending[$Instance.name] = @{ action = 'restart'; serviceName = $Instance.serviceName; since = Get-Date }
                }
            }
        }
    } catch {
        if ($_.Exception.Data.Contains('BcsaStatus')) { throw }
        # .NET exceptions arrive wrapped (MethodInvocationException -> InvalidOperationException -> Win32Exception).
        $messages = @()
        $exception = $_.Exception
        while ($exception) { $messages += $exception.Message; $exception = $exception.InnerException }
        Stop-BcsaRequest 409 'service_error' (($messages | Select-Object -Unique) -join ' ')
    }
    Write-BcsaLog ("{0}: {1} requested" -f $Instance.name, $Action)
    return [ordered]@{ instance = $Instance.name; action = $Action }
}

function Update-BcsaPendingAction {
    if ($script:BcsaPending.Count -eq 0) { return }
    foreach ($name in @($script:BcsaPending.Keys)) {
        $pending = $script:BcsaPending[$name]
        try {
            $service = Get-Service -Name $pending.serviceName -ErrorAction Stop
            if ($service.Status -eq 'Stopped') {
                $service.Start()
                $script:BcsaPending.Remove($name)
                Write-BcsaLog "${name}: stopped, starting again"
            } elseif (((Get-Date) - $pending.since).TotalMinutes -gt 15) {
                $script:BcsaPending.Remove($name)
                Write-BcsaLog "${name}: restart abandoned, the service did not stop within 15 minutes" -Level Warn
            }
        } catch {
            $script:BcsaPending.Remove($name)
            Write-BcsaLog "${name}: restart failed: $($_.Exception.Message)" -Level Error
        }
    }
}

function Get-BcsaEventMessage {
    param($EventRecord)
    $message = $null
    try { $message = $EventRecord.Message } catch { }
    if ([string]::IsNullOrWhiteSpace($message)) {
        # Some providers have no message resources on this machine; the text is in the properties.
        $message = (@($EventRecord.Properties | ForEach-Object { [string]$_.Value }) | Where-Object { $_ }) -join "`n"
    }
    if ($message.Length -gt 16000) { $message = $message.Substring(0, 16000) + ' ...' }
    return $message.Trim()
}

function Get-BcsaEvent {
    <#
        Source 'Admin'      : Microsoft-DynamicsNAV-Server/Admin (errors/warnings of all instances, filtered by instance)
        Source 'Application': Windows Application log, provider MicrosoftDynamicsNavServer$<instance>
    #>
    param(
        $Instance,
        [ValidateSet('Admin', 'Application')] [string] $Source = 'Admin',
        [ValidateRange(1, 1000)] [int] $Max = 100,
        [ValidateRange(1, 5)] [int] $MaxLevel = 5
    )

    if ($script:Bcsa.Demo) { return Get-BcsaDemoEvent -Instance $Instance -Source $Source -Max $Max -MaxLevel $MaxLevel }

    $levels = @(1, 2, 3, 4, 5, 0) | Where-Object { $_ -le $MaxLevel -and ($_ -ne 0 -or $MaxLevel -ge 4) }
    $records = @()
    if ($Source -eq 'Application') {
        $filter = @{ LogName = 'Application'; ProviderName = $Instance.serviceName; Level = $levels }
        $records = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Max -ErrorAction SilentlyContinue)
    } else {
        # Property 0 of every event in this log is the server instance name.
        $filter = @{ LogName = 'Microsoft-DynamicsNAV-Server/Admin'; Level = $levels }
        $records = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 5000 -ErrorAction SilentlyContinue |
                Where-Object { $_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -eq $Instance.name } |
                Select-Object -First $Max)
    }

    $levelNames = @{ 0 = 'Information'; 1 = 'Critical'; 2 = 'Error'; 3 = 'Warning'; 4 = 'Information'; 5 = 'Verbose' }
    $items = foreach ($record in $records) {
        [ordered]@{
            time    = $record.TimeCreated.ToString('o')
            level   = $levelNames[[int]$record.Level]
            id      = $record.Id
            source  = $record.ProviderName
            message = Get-BcsaEventMessage $record
        }
    }
    return [ordered]@{ source = $Source; items = @($items) }
}
