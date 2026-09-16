# Local HTTP server: static web UI + JSON API.
#
# Security model (the process runs elevated and can reconfigure BC):
#  - listens on http://localhost:<port>/ only and rejects non-loopback peers and foreign Host headers
#  - every /api call needs the per-run random token (X-BCSA-Token header, constant-time compare)
#  - state-changing calls must be POST + application/json + same Origin (blocks CSRF / simple forms)
#  - strict CSP, no CORS headers at all, and no caching

$script:BcsaHttp = @{
    Port           = 0
    Token          = $null
    Static         = @{}
    AllowedHosts   = @()
    AllowedOrigins = @()
    Fqdn           = $env:COMPUTERNAME
}

$script:BcsaMimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
}

$script:BcsaReadOnlyKeys = @('ServerInstance', 'ProtectedDatabasePassword')

function Initialize-BcsaStaticFiles {
    param([string] $WebRoot)
    $root = (Resolve-Path -LiteralPath $WebRoot).Path.TrimEnd('\')
    $script:BcsaHttp.Static = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $extension = $file.Extension.ToLowerInvariant()
        if (-not $script:BcsaMimeTypes.ContainsKey($extension)) { continue }
        $relative = '/' + $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $script:BcsaHttp.Static[$relative] = @{ Path = $file.FullName; Type = $script:BcsaMimeTypes[$extension] }
    }
    $script:BcsaHttp.Static['/'] = $script:BcsaHttp.Static['/index.html']
}

function Get-BcsaFqdn {
    if ($script:Bcsa.Demo) { return 'BCSRV01.contoso.local' }
    try {
        $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        if ($properties.DomainName) { return ('{0}.{1}' -f $properties.HostName, $properties.DomainName) }
        return $properties.HostName
    } catch {
        return $env:COMPUTERNAME
    }
}

function Get-BcsaInfo {
    return [ordered]@{
        version       = $script:BcsaVersion
        computerName  = $script:Bcsa.ComputerName
        fqdn          = $script:BcsaHttp.Fqdn
        user          = $script:Bcsa.UserName
        isAdmin       = (Test-BcsaAdministrator)
        demo          = $script:Bcsa.Demo
        psVersion     = $PSVersionTable.PSVersion.ToString()
        psEdition     = [string]$PSVersionTable.PSEdition
        pwshAvailable = [bool](Get-BcsaPowerShellPath -Kind PowerShell7)
        workerHost    = $script:Bcsa.WorkerHost
        backupRoot    = $script:Bcsa.BackupRoot
        readOnlyKeys  = $script:BcsaReadOnlyKeys
    }
}

function Send-BcsaResponse {
    param(
        $Context,
        [int] $Status = 200,
        [string] $ContentType = 'application/json; charset=utf-8',
        $Body,
        [hashtable] $Headers = @{}
    )
    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.AddHeader('X-Content-Type-Options', 'nosniff')
    $response.AddHeader('X-Frame-Options', 'DENY')
    $response.AddHeader('Referrer-Policy', 'no-referrer')
    $response.AddHeader('Cache-Control', 'no-store')
    $response.AddHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    foreach ($name in $Headers.Keys) { $response.AddHeader($name, $Headers[$name]) }

    if ($Body -is [byte[]]) { $bytes = $Body } else { $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Body) }
    $response.ContentLength64 = $bytes.Length
    if ($Context.Request.HttpMethod -ne 'HEAD') { $response.OutputStream.Write($bytes, 0, $bytes.Length) }
}

function Assert-BcsaApiRequest {
    param($Request)
    if (-not (Test-BcsaTokenEqual -Expected $script:BcsaHttp.Token -Actual ([string]$Request.Headers['X-BCSA-Token']))) {
        Stop-BcsaRequest 401 'unauthorized' 'Missing or invalid session token. Open the URL printed in the console window.'
    }
    if ($Request.HttpMethod -eq 'GET') { return }
    if ($Request.HttpMethod -ne 'POST') { Stop-BcsaRequest 405 'method_not_allowed' 'Method not allowed.' }

    $origin = [string]$Request.Headers['Origin']
    if ($origin -and ($script:BcsaHttp.AllowedOrigins -notcontains $origin.ToLowerInvariant())) {
        Stop-BcsaRequest 403 'forbidden' 'Cross-origin requests are not allowed.'
    }
    $fetchSite = [string]$Request.Headers['Sec-Fetch-Site']
    if ($fetchSite -and $fetchSite -ne 'same-origin') { Stop-BcsaRequest 403 'forbidden' 'Cross-site requests are not allowed.' }
    if (-not ([string]$Request.ContentType).StartsWith('application/json', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-BcsaRequest 415 'unsupported_media_type' 'Content-Type must be application/json.'
    }
}

function Read-BcsaJsonBody {
    param($Request)
    if ($Request.ContentLength64 -gt 1MB) { Stop-BcsaRequest 413 'payload_too_large' 'Request body too large.' }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { return (ConvertFrom-Json -InputObject $text) } catch { Stop-BcsaRequest 400 'invalid_json' 'The request body is not valid JSON.' }
}

function Assert-BcsaInstanceRunning {
    param($Instance)
    if ($Instance.state -ne 'Running') { Stop-BcsaRequest 409 'not_running' "Server instance '$($Instance.name)' is not running." }
}

function Assert-BcsaConfigFile {
    param($Instance)
    if (-not $Instance.configPath) { Stop-BcsaRequest 409 'config_not_found' "CustomSettings.config was not found for '$($Instance.name)'." }
}

function Save-BcsaConfigChanges {
    param($Instance, $Body)
    Assert-BcsaConfigFile $Instance
    $changes = @(@($Body.changes) | Where-Object { $_ -and $_.key })
    if ($changes.Count -eq 0) { Stop-BcsaRequest 400 'no_changes' 'No changes were sent.' }

    $current = Read-BcsaCustomSettings -Path $Instance.configPath
    if ($Body.stamp -and [string]$Body.stamp -ne $current.stamp) {
        Stop-BcsaRequest 409 'stale' 'CustomSettings.config was modified by someone else. Reload the configuration and try again.'
    }
    $known = @{}
    foreach ($setting in $current.settings) { $known[$setting.key] = $true }
    $plain = @()
    foreach ($change in $changes) {
        $key = [string]$change.key
        if (-not $known.ContainsKey($key)) { Stop-BcsaRequest 400 'unknown_key' "Unknown setting '$key'." }
        if ($script:BcsaReadOnlyKeys -contains $key) { Stop-BcsaRequest 400 'read_only' "Setting '$key' cannot be edited here." }
        $plain += @{ key = $key; value = [string]$change.value }
    }

    $mode = 'module'
    if ([string]$Body.mode -eq 'file') { $mode = 'file' }
    if ($mode -eq 'module') { [void](Invoke-BcsaWorker -Instance $Instance -Command 'ping') }

    $backup = New-BcsaBackup -Instance $Instance -Reason 'before-save'
    if ($mode -eq 'file') {
        $results = Set-BcsaCustomSettingsFile -Path $Instance.configPath -Changes $plain
    } else {
        $results = (Invoke-BcsaWorker -Instance $Instance -Command 'setConfig' -Arguments @{
                instance      = $Instance.name
                changes       = $plain
                applyToMemory = [bool]$Body.applyToMemory
            }).items
    }
    $script:BcsaConfigCache.Remove($Instance.configPath)
    $okCount = @($results | Where-Object { $_.ok }).Count
    Write-BcsaLog ("{0}: {1}/{2} setting(s) saved ({3}), backup {4}" -f $Instance.name, $okCount, $plain.Count, $mode, $backup.name) -Level Ok
    return [ordered]@{
        mode    = $mode
        backup  = $backup.name
        results = @($results)
        stamp   = (Get-BcsaFileStamp -Path $Instance.configPath)
    }
}

function Invoke-BcsaInstanceRoute {
    param($Context, $Instance, [string] $Method, [string] $SubPath)
    $request = $Context.Request
    $query = $request.QueryString
    $route = '{0} {1}' -f $Method, $SubPath

    switch -Regex ($route) {
        '^GET $' {
            return (ConvertTo-BcsaInstanceView $Instance)
        }
        '^GET /config$' {
            Assert-BcsaConfigFile $Instance
            $data = Read-BcsaCustomSettings -Path $Instance.configPath
            return [ordered]@{ path = $data.path; stamp = $data.stamp; settings = @($data.settings) }
        }
        '^POST /config$' {
            return (Save-BcsaConfigChanges -Instance $Instance -Body (Read-BcsaJsonBody $request))
        }
        '^POST /credentials$' {
            Assert-BcsaConfigFile $Instance
            $body = Read-BcsaJsonBody $request
            if ([string]::IsNullOrWhiteSpace([string]$body.user)) { Stop-BcsaRequest 400 'invalid_user' 'The user name is required.' }
            [void](Invoke-BcsaWorker -Instance $Instance -Command 'ping')
            $backup = New-BcsaBackup -Instance $Instance -Reason 'before-save'
            [void](Invoke-BcsaWorker -Instance $Instance -Command 'setDatabaseCredentials' -Arguments @{
                    instance = $Instance.name
                    user     = [string]$body.user
                    password = [string]$body.password
                })
            $script:BcsaConfigCache.Remove($Instance.configPath)
            Write-BcsaLog ("{0}: database credentials updated, backup {1}" -f $Instance.name, $backup.name) -Level Ok
            return [ordered]@{ ok = $true; backup = $backup.name }
        }
        '^POST /service$' {
            $body = Read-BcsaJsonBody $request
            $action = [string]$body.action
            if (@('start', 'stop', 'restart') -notcontains $action) { Stop-BcsaRequest 400 'invalid_action' 'Invalid action.' }
            return (Invoke-BcsaServiceAction -Instance $Instance -Action $action)
        }
        '^GET /sessions$' {
            Assert-BcsaInstanceRunning $Instance
            return (Invoke-BcsaWorker -Instance $Instance -Command 'getSessions' -Arguments @{ instance = $Instance.name })
        }
        '^POST /sessions/(\d+)/remove$' {
            Assert-BcsaInstanceRunning $Instance
            $sessionId = [int]$Matches[1]
            $result = Invoke-BcsaWorker -Instance $Instance -Command 'removeSession' -Arguments @{ instance = $Instance.name; sessionId = $sessionId }
            Write-BcsaLog ("{0}: session {1} removed" -f $Instance.name, $sessionId)
            return $result
        }
        '^GET /tenants$' {
            Assert-BcsaInstanceRunning $Instance
            return (Invoke-BcsaWorker -Instance $Instance -Command 'getTenants' -Arguments @{ instance = $Instance.name })
        }
        '^GET /events$' {
            $source = 'Admin'
            if ($query['source'] -eq 'Application') { $source = 'Application' }
            $max = 100
            if ($query['max'] -match '^\d+$') { $max = [Math]::Min(1000, [Math]::Max(1, [int]$query['max'])) }
            $level = 5
            if ($query['level'] -match '^[1-5]$') { $level = [int]$query['level'] }
            return (Get-BcsaEvent -Instance $Instance -Source $source -Max $max -MaxLevel $level)
        }
        '^GET /backups$' {
            return (Get-BcsaBackup -Instance $Instance)
        }
        '^POST /backups$' {
            return (New-BcsaBackup -Instance $Instance -Reason 'manual')
        }
        '^POST /backups/restore$' {
            $body = Read-BcsaJsonBody $request
            $result = Restore-BcsaBackup -Instance $Instance -Name ([string]$body.name)
            Write-BcsaLog ("{0}: restored backup {1}" -f $Instance.name, $result.restored) -Level Ok
            return $result
        }
        '^GET /export$' {
            $format = 'Html'
            if ($query['format'] -match '^(?i)(csv|json)$') { $format = (Get-Culture).TextInfo.ToTitleCase($query['format'].ToLowerInvariant()) }
            $language = 'en'
            if ($query['lang'] -eq 'es') { $language = 'es' }
            $export = Export-BcsaConfiguration -Instance $Instance -Format $format -IncludeSecrets:($query['secrets'] -eq '1') -Language $language
            return @{ __raw = $true; content = $export.content; contentType = $export.contentType; fileName = $export.fileName }
        }
    }
    Stop-BcsaRequest 404 'not_found' 'Unknown API route.'
}

function Invoke-BcsaApiRoute {
    param($Context, [string] $Method, [string] $Path)
    switch ('{0} {1}' -f $Method, $Path) {
        'GET /api/info' { return (Get-BcsaInfo) }
        'GET /api/instances' {
            return @{ items = @(Get-BcsaInstance | ForEach-Object { ConvertTo-BcsaInstanceView $_ }) }
        }
        'POST /api/shutdown' {
            Write-BcsaLog 'Shutdown requested from the web UI.'
            $script:Bcsa.Running = $false
            return @{ ok = $true }
        }
    }
    if ($Path -notmatch '^/api/instances/([^/]+)(/.*)?$') { Stop-BcsaRequest 404 'not_found' 'Unknown API route.' }
    $name = [Uri]::UnescapeDataString($Matches[1])
    $subPath = [string]$Matches[2]
    $instance = Get-BcsaInstanceOrFail -Name $name
    return (Invoke-BcsaInstanceRoute -Context $Context -Instance $instance -Method $Method -SubPath $subPath)
}

function Invoke-BcsaRequest {
    param($Context)
    $request = $Context.Request
    try {
        if (-not [System.Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address)) {
            Stop-BcsaRequest 403 'forbidden' 'Only local connections are accepted.'
        }
        if ($script:BcsaHttp.AllowedHosts -notcontains ([string]$request.Headers['Host']).ToLowerInvariant()) {
            Stop-BcsaRequest 403 'forbidden' 'Invalid Host header.'
        }

        $path = $request.Url.AbsolutePath
        if ($path.StartsWith('/api/', [StringComparison]::OrdinalIgnoreCase)) {
            Assert-BcsaApiRequest $request
            $result = Invoke-BcsaApiRoute -Context $Context -Method $request.HttpMethod -Path $path
            if ($result -is [hashtable] -and $result.ContainsKey('__raw')) {
                $disposition = 'attachment; filename="{0}"' -f $result.fileName
                Send-BcsaResponse -Context $Context -ContentType $result.contentType -Body $result.content -Headers @{ 'Content-Disposition' = $disposition }
            } else {
                Send-BcsaResponse -Context $Context -Body (ConvertTo-BcsaJson $result)
            }
            return
        }

        if ($request.HttpMethod -ne 'GET' -and $request.HttpMethod -ne 'HEAD') { Stop-BcsaRequest 405 'method_not_allowed' 'Method not allowed.' }
        $file = $script:BcsaHttp.Static[$path]
        if (-not $file) { Stop-BcsaRequest 404 'not_found' 'Not found.' }
        Send-BcsaResponse -Context $Context -ContentType $file.Type -Body ([IO.File]::ReadAllBytes($file.Path))
    } catch {
        $err = $_
        $status = 500
        $code = 'internal_error'
        if ($err.Exception.Data.Contains('BcsaStatus')) {
            $status = [int]$err.Exception.Data['BcsaStatus']
            $code = [string]$err.Exception.Data['BcsaCode']
        } else {
            Write-BcsaLog ("{0} {1} failed: {2}" -f $request.HttpMethod, $request.Url.AbsolutePath, $err.Exception.Message) -Level Error
        }
        try {
            Send-BcsaResponse -Context $Context -Status $status -Body (ConvertTo-BcsaJson @{ error = $err.Exception.Message; code = $code })
        } catch { }
    } finally {
        try { $Context.Response.Close() } catch { }
    }
}

function Start-BcsaHttpServer {
    param(
        [int] $Port,
        [string] $WebRoot,
        [switch] $NoBrowser
    )
    Initialize-BcsaStaticFiles -WebRoot $WebRoot
    $script:BcsaHttp.Port = $Port
    $script:BcsaHttp.Token = New-BcsaToken
    $script:BcsaHttp.AllowedHosts = @("localhost:$Port")
    $script:BcsaHttp.AllowedOrigins = @("http://localhost:$Port")
    $script:BcsaHttp.Fqdn = Get-BcsaFqdn

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.IgnoreWriteExceptions = $true
    $listener.Start()

    $url = "http://localhost:$Port/?t=$($script:BcsaHttp.Token)"
    try { $Host.UI.RawUI.WindowTitle = "BC Server Admin - http://localhost:$Port" } catch { }
    Write-Host ''
    Write-Host '  BC Server Admin is running.' -ForegroundColor Cyan
    Write-Host "  Open: $url" -ForegroundColor White
    Write-Host '  Keep this window open. Press Ctrl+C (or use "Close" in the web UI) to stop.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not $NoBrowser) {
        # explorer.exe hands the URL to the user's default browser without elevation.
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$url`"" } catch { Write-BcsaLog "Could not open the browser: $($_.Exception.Message)" -Level Warn }
    }

    try {
        while ($script:Bcsa.Running) {
            $pending = $listener.BeginGetContext($null, $null)
            while (-not $pending.AsyncWaitHandle.WaitOne(300)) {
                Update-BcsaPendingAction
                Update-BcsaWorkers
                if ($script:Bcsa.Demo) { Update-BcsaDemo }
            }
            Invoke-BcsaRequest -Context ($listener.EndGetContext($pending))
        }
    } finally {
        Write-BcsaLog 'Stopping BC Server Admin...'
        try { $listener.Stop(); $listener.Close() } catch { }
        Stop-BcsaAllWorkers
        if ($script:Bcsa.Demo) { Remove-BcsaDemo }
    }
}
