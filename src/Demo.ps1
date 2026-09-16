# Demo mode: fictitious instances backed by real temp CustomSettings.config files, so the whole UI
# (including saving, backups and restores) can be tried without Business Central or admin rights.

$script:BcsaDemo = $null

function Initialize-BcsaDemo {
    param([string] $SourceRoot)

    # Remove folders left behind by demo runs that were killed.
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'bc-server-admin-demo-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '-(\d+)$' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $root = Join-Path ([IO.Path]::GetTempPath()) ('bc-server-admin-demo-{0}' -f $PID)
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $script:Bcsa.BackupRoot = Join-Path $root 'backups'
    $template = Get-Content -LiteralPath (Join-Path $SourceRoot 'demo\CustomSettings.template.config') -Raw

    $bcRoot = 'C:\Program Files\Microsoft Dynamics 365 Business Central'
    $definitions = @(
        @{ name = 'BC190'; version = '19.0.29884.30666'; folder = '190'; state = 'Running'; startMode = 'Auto'; account = 'NT AUTHORITY\NetworkService'; failsToStart = $false
            tokens = @{ DBSERVER = 'SQLDEV01'; DBINSTANCE = 'BCDEMO'; DBNAME = 'Demo Database BC (19-0)'; DBUSER = ''; DBPASSWORD = ''; CREDTYPE = 'Windows'; MULTITENANT = 'false'
                WEBURL = ''; COMPANY = 'CRONUS International Ltd.'; PORT_BASE = 7045; THUMBPRINT = ''; AADSECRET = ''; AICONN = '' } }
        @{ name = 'BC252'; version = '25.2.28751.0'; folder = '252'; state = 'Running'; startMode = 'Auto'; account = 'CONTOSO\svc-bc'; failsToStart = $false
            tokens = @{ DBSERVER = 'SQLPROD01,1433'; DBINSTANCE = ''; DBNAME = 'BC_PROD'; DBUSER = 'bc_service'; DBPASSWORD = 'dGhpcyBpcyBhIGRlbW8gdmFsdWU='; CREDTYPE = 'NavUserPassword'; MULTITENANT = 'false'
                WEBURL = 'https://bc.contoso.local/BC252'; COMPANY = 'CONTOSO SPAIN'; PORT_BASE = 7145; THUMBPRINT = '3A1F09C2D4E5B6A7980112233445566778899AAB'
                AADSECRET = 'demo-secret-value'; AICONN = 'InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/' } }
        @{ name = 'BC252_TEST'; version = '25.2.28751.0'; folder = '252'; state = 'Stopped'; startMode = 'Manual'; account = 'CONTOSO\svc-bc'; failsToStart = $true
            tokens = @{ DBSERVER = 'SQLTEST01'; DBINSTANCE = ''; DBNAME = 'BC_TEST'; DBUSER = 'bc_service'; DBPASSWORD = 'dGhpcyBpcyBhIGRlbW8gdmFsdWU='; CREDTYPE = 'NavUserPassword'; MULTITENANT = 'false'
                WEBURL = 'https://bc-test.contoso.local/BC252_TEST'; COMPANY = 'CONTOSO SPAIN'; PORT_BASE = 7245; THUMBPRINT = '3A1F09C2D4E5B6A7980112233445566778899AAB'; AADSECRET = ''; AICONN = '' } }
        @{ name = 'BC270'; version = '27.0.38460.0'; folder = '270'; state = 'Running'; startMode = 'Auto'; account = 'CONTOSO\svc-bc27'; failsToStart = $false
            tokens = @{ DBSERVER = 'SQLPROD02'; DBINSTANCE = ''; DBNAME = 'BC27_APP'; DBUSER = ''; DBPASSWORD = ''; CREDTYPE = 'NavUserPassword'; MULTITENANT = 'true'
                WEBURL = 'https://bc27.contoso.local/BC270'; COMPANY = ''; PORT_BASE = 7345; THUMBPRINT = '9B8C7D6E5F4A3B2C1D0E9F8A7B6C5D4E3F2A1B0C'; AADSECRET = ''; AICONN = '' } }
    )

    $instances = [ordered]@{}
    $random = New-Object System.Random 42
    foreach ($definition in $definitions) {
        $tokens = $definition.tokens
        $base = [int]$tokens.PORT_BASE
        $tokens.INSTANCE = $definition.name
        $tokens.PORT_MGMT = $base
        $tokens.PORT_CLIENT = $base + 1
        $tokens.PORT_SOAP = $base + 2
        $tokens.PORT_ODATA = $base + 3
        $tokens.PORT_DEV = $base + 4
        $tokens.PORT_SNAP = $base + 38
        $tokens.PORT_MGMTAPI = $base + 41

        $content = $template
        foreach ($token in $tokens.Keys) { $content = $content.Replace("{{$token}}", [Security.SecurityElement]::Escape([string]$tokens[$token])) }
        $dir = Join-Path $root $definition.name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $configPath = Join-Path $dir 'CustomSettings.config'
        [IO.File]::WriteAllText($configPath, $content, (New-Object System.Text.UTF8Encoding($true)))

        $state = $definition.state
        $instances[$definition.name] = @{
            Definition = $definition
            State      = $state
            ProcessId  = $(if ($state -eq 'Running') { $random.Next(2000, 30000) } else { 0 })
            ConfigPath = $configPath
            ServiceDir = Join-Path $bcRoot "$($definition.folder)\Service"
            Queue      = New-Object System.Collections.ArrayList
            Sessions   = New-Object System.Collections.ArrayList
            Events     = New-Object System.Collections.ArrayList
        }
        New-BcsaDemoSessions -Entry $instances[$definition.name] -Random $random
        New-BcsaDemoEvents -Entry $instances[$definition.name]
    }
    $script:BcsaDemo = @{ Root = $root; Instances = $instances; NextSessionId = 500 }
    Write-BcsaLog "Demo mode: fictitious data in $root" -Level Warn
}

function New-BcsaDemoSessions {
    param($Entry, [System.Random] $Random)
    $Entry.Sessions.Clear()
    if ($Entry.State -ne 'Running') { return }
    $users = @('CONTOSO\ANA.GARCIA', 'CONTOSO\JOHN.SMITH', 'CONTOSO\LUCIA.MARTIN', 'CONTOSO\PEDRO.LOPEZ', 'CONTOSO\EMMA.JONES', 'CONTOSO\svc-integration', 'CONTOSO\svc-bc')
    $types = @('WebClient', 'WebClient', 'WebClient', 'Background', 'ODataV4', 'WebServiceClient', 'ManagementClient', 'ChildSession', 'Api')
    $count = $Random.Next(4, 14)
    $definition = $Entry.Definition
    for ($i = 0; $i -lt $count; $i++) {
        $clientType = $types[$Random.Next(0, $types.Count)]
        $user = $users[$Random.Next(0, $users.Count)]
        if ($clientType -eq 'Background') { $user = $definition.account }
        [void]$Entry.Sessions.Add([ordered]@{
                ServerInstanceName = $definition.name
                SessionID          = 100 + ($i * 7) + $Random.Next(0, 5)
                UserID             = $user
                ClientType         = $clientType
                ClientComputerName = $(if ($clientType -eq 'Background') { '' } else { 'PC-{0:D3}' -f $Random.Next(1, 120) })
                LoginDatetime      = (Get-Date).AddMinutes( - $Random.Next(1, 600)).ToString('o')
                DatabaseName       = $definition.tokens.DBNAME
                ServerComputerName = $script:Bcsa.ComputerName
                TenantId           = $(if ($definition.tokens.MULTITENANT -eq 'true') { @('contoso', 'fabrikam', 'northwind')[$Random.Next(0, 3)] } else { 'default' })
            })
    }
}

function Add-BcsaDemoEvent {
    param($Entry, [datetime] $Time, [string] $Level, [int] $Id, [string] $Message)
    $text = "Server instance: {0}`nTenant: `nEnvironment Name: `nEnvironment Type: `n{1}" -f $Entry.Definition.name, $Message
    [void]$Entry.Events.Insert(0, [ordered]@{ time = $Time.ToString('o'); level = $Level; id = $Id; source = 'Microsoft-DynamicsNAV-Server'; message = $text })
}

function New-BcsaDemoEvents {
    param($Entry)
    $start = (Get-Date).AddHours(-30)
    Add-BcsaDemoEvent -Entry $Entry -Time $start -Level 'Information' -Id 103 -Message "The service is starting."
    Add-BcsaDemoEvent -Entry $Entry -Time $start.AddSeconds(9) -Level 'Warning' -Id 202 -Message "The service could not add service principal names because the service account could not be found in Active Directory.`nAccount: $($Entry.Definition.account)"
    Add-BcsaDemoEvent -Entry $Entry -Time $start.AddSeconds(21) -Level 'Information' -Id 101 -Message "Service started. Listening on the configured ports."
    Add-BcsaDemoEvent -Entry $Entry -Time $start.AddHours(3) -Level 'Warning' -Id 705 -Message "Long running SQL statement (1284 ms) in object Codeunit 80 'Sales-Post'."
    Add-BcsaDemoEvent -Entry $Entry -Time $start.AddHours(6) -Level 'Error' -Id 107 -Message "Session was forcibly closed by the client.`nUser: CONTOSO\JOHN.SMITH`nClient type: WebClient"
    Add-BcsaDemoEvent -Entry $Entry -Time $start.AddHours(11) -Level 'Warning' -Id 705 -Message "Long running SQL statement (2210 ms) in object Report 1306 'Standard Sales - Invoice'."
    Add-BcsaDemoEvent -Entry $Entry -Time $start.AddHours(19) -Level 'Error' -Id 107 -Message "Job queue entry 'Adjust Cost - Item Entries' failed: The Item Ledger Entry does not exist."
    if ($Entry.Definition.failsToStart) {
        Add-BcsaDemoEvent -Entry $Entry -Time $start.AddHours(26) -Level 'Error' -Id 107 -Message "The service $($Entry.Definition.name) failed to start.`nCannot connect to SQL Server 'SQLTEST01'. A network-related or instance-specific error occurred while establishing a connection to SQL Server."
    }
}

function Get-BcsaDemoInstance {
    param([string] $Name)
    $result = foreach ($entry in $script:BcsaDemo.Instances.Values) {
        $definition = $entry.Definition
        if ($Name -and $definition.name -ne $Name) { continue }
        [pscustomobject]@{
            name        = $definition.name
            serviceName = "MicrosoftDynamicsNavServer`$$($definition.name)"
            displayName = "Microsoft Dynamics 365 Business Central Server [$($definition.name)]"
            state       = $entry.State
            startMode   = $definition.startMode
            account     = $definition.account
            processId   = $entry.ProcessId
            exePath     = Join-Path $entry.ServiceDir 'Microsoft.Dynamics.Nav.Server.exe'
            serviceDir  = $entry.ServiceDir
            version     = $definition.version
            major       = [int]($definition.version.Split('.')[0])
            configPath  = $entry.ConfigPath
        }
    }
    if ($Name) { return ($result | Select-Object -First 1) }
    return @($result)
}

function Invoke-BcsaDemoServiceAction {
    param($Instance, [string] $Action)
    $entry = $script:BcsaDemo.Instances[$Instance.name]
    $queue = $entry.Queue
    $now = Get-Date
    switch ($Action) {
        'start' {
            if ($entry.State -ne 'Stopped') { Stop-BcsaRequest 409 'invalid_state' "The service is $($entry.State)." }
            $queue.Clear()
            $entry.State = 'StartPending'
            [void]$queue.Add(@{ at = $now.AddSeconds(3); state = 'Running' })
        }
        'stop' {
            if ($entry.State -eq 'Stopped' -or $entry.State -eq 'StopPending') { Stop-BcsaRequest 409 'invalid_state' "The service is $($entry.State)." }
            $queue.Clear()
            $script:BcsaPending.Remove($Instance.name)
            $entry.State = 'StopPending'
            [void]$queue.Add(@{ at = $now.AddSeconds(2); state = 'Stopped' })
        }
        'restart' {
            $queue.Clear()
            if ($entry.State -eq 'Stopped') {
                $entry.State = 'StartPending'
                [void]$queue.Add(@{ at = $now.AddSeconds(3); state = 'Running' })
            } else {
                $script:BcsaPending[$Instance.name] = @{ action = 'restart'; serviceName = $Instance.serviceName; since = $now }
                $entry.State = 'StopPending'
                [void]$queue.Add(@{ at = $now.AddSeconds(2); state = 'Stopped' })
                [void]$queue.Add(@{ at = $now.AddSeconds(2.5); state = 'StartPending' })
                [void]$queue.Add(@{ at = $now.AddSeconds(5.5); state = 'Running' })
            }
        }
    }
    Write-BcsaLog ("[demo] {0}: {1} requested" -f $Instance.name, $Action)
    return [ordered]@{ instance = $Instance.name; action = $Action }
}

function Update-BcsaDemo {
    $now = Get-Date
    foreach ($entry in $script:BcsaDemo.Instances.Values) {
        while ($entry.Queue.Count -gt 0 -and $entry.Queue[0].at -le $now) {
            $step = $entry.Queue[0]
            $entry.Queue.RemoveAt(0)
            $state = $step.state
            $name = $entry.Definition.name
            if ($state -eq 'StartPending') { $script:BcsaPending.Remove($name) }
            if ($state -eq 'Running' -and $entry.Definition.failsToStart) {
                $state = 'Stopped'
                Add-BcsaDemoEvent -Entry $entry -Time $now -Level 'Error' -Id 107 -Message "The service $name failed to start.`nCannot connect to SQL Server '$($entry.Definition.tokens.DBSERVER)'. A network-related or instance-specific error occurred while establishing a connection to SQL Server."
            }
            $entry.State = $state
            switch ($state) {
                'Running' {
                    $entry.ProcessId = Get-Random -Minimum 2000 -Maximum 30000
                    Add-BcsaDemoEvent -Entry $entry -Time $now -Level 'Information' -Id 101 -Message 'Service started. Listening on the configured ports.'
                    New-BcsaDemoSessions -Entry $entry -Random (New-Object System.Random)
                }
                'Stopped' {
                    $entry.ProcessId = 0
                    $entry.Sessions.Clear()
                    if (-not $entry.Definition.failsToStart) { Add-BcsaDemoEvent -Entry $entry -Time $now -Level 'Information' -Id 102 -Message 'Service stopped.' }
                }
            }
        }
    }
}

function Get-BcsaDemoEvent {
    param($Instance, [string] $Source, [int] $Max, [int] $MaxLevel)
    $rank = @{ Critical = 1; Error = 2; Warning = 3; Information = 4; Verbose = 5 }
    $entry = $script:BcsaDemo.Instances[$Instance.name]
    $items = @($entry.Events | Where-Object { $rank[$_.level] -le $MaxLevel } | Select-Object -First $Max)
    if ($Source -eq 'Application') {
        $items = @($items | ForEach-Object {
                $copy = [ordered]@{}
                foreach ($k in $_.Keys) { $copy[$k] = $_[$k] }
                $copy.source = $Instance.serviceName
                $copy
            })
    }
    return [ordered]@{ source = $Source; items = $items }
}

function Invoke-BcsaDemoWorker {
    param($Instance, [string] $Command, [hashtable] $Arguments)
    $entry = $script:BcsaDemo.Instances[$Instance.name]
    switch ($Command) {
        'ping' { return @{ module = 'demo' } }
        'getSessions' { return @{ items = @($entry.Sessions) } }
        'removeSession' {
            $target = $entry.Sessions | Where-Object { $_.SessionID -eq $Arguments.sessionId } | Select-Object -First 1
            if (-not $target) { Stop-BcsaRequest 422 'bc_error' "Session $($Arguments.sessionId) does not exist." }
            $entry.Sessions.Remove($target)
            return @{ removed = $Arguments.sessionId }
        }
        'getTenants' {
            if ($entry.Definition.tokens.MULTITENANT -ne 'true') {
                return @{ items = @([ordered]@{ Id = 'default'; State = 'Operational'; DatabaseName = $entry.Definition.tokens.DBNAME; DatabaseServer = $entry.Definition.tokens.DBSERVER; AllowAppDatabaseWrite = $false }) }
            }
            $items = foreach ($tenant in @('contoso', 'fabrikam', 'northwind')) {
                [ordered]@{ Id = $tenant; State = $(if ($tenant -eq 'northwind') { 'OperationalDataUpgradePending' } else { 'Operational' }); DatabaseName = "BC27_$($tenant.ToUpperInvariant())"; DatabaseServer = $entry.Definition.tokens.DBSERVER; AllowAppDatabaseWrite = $false; DefaultCompany = '' }
            }
            return @{ items = @($items) }
        }
        'setConfig' {
            # A handful of settings behave as "dynamic" in the demo so -ApplyTo Memory results can be seen.
            $dynamic = @('TraceLevel', 'SqlLongRunningThreshold', 'ODataServicesMaxPageSize', 'TaskSchedulerMaximumConcurrentRunningTasks', 'ClientServicesMaxUploadSize', 'SearchTimeout')
            $results = Set-BcsaCustomSettingsFile -Path $Instance.configPath -Changes $Arguments.changes
            foreach ($result in $results) {
                if ($result.ok -and $Arguments.applyToMemory) {
                    if ($dynamic -contains $result.key) { $result.memory = @{ ok = $true; error = $null } }
                    else { $result.memory = @{ ok = $false; error = "The setting '$($result.key)' cannot be updated dynamically. Restart the server instance to apply it." } }
                }
            }
            return @{ items = @($results) }
        }
        'setDatabaseCredentials' {
            $fake = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('demo:' + [guid]::NewGuid()))
            [void](Set-BcsaCustomSettingsFile -Path $Instance.configPath -Changes @(@{ key = 'DatabaseUserName'; value = $Arguments.user }, @{ key = 'ProtectedDatabasePassword'; value = $fake }))
            return @{ ok = $true }
        }
    }
    Stop-BcsaRequest 400 'unknown_command' "Unknown command '$Command'."
}

function Remove-BcsaDemo {
    if ($script:BcsaDemo -and (Test-Path -LiteralPath $script:BcsaDemo.Root)) {
        Remove-Item -LiteralPath $script:BcsaDemo.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
