#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit and integration tests. They never touch a real Business Central installation:
    configuration tests use temp copies of the demo template and the HTTP tests run the server in -Demo mode.

        Invoke-Pester -Path .\tests
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SourceRoot = Join-Path $RepoRoot 'src'
    . (Join-Path $SourceRoot 'Common.ps1')
    . (Join-Path $SourceRoot 'Discovery.ps1')
    . (Join-Path $SourceRoot 'Config.ps1')
    . (Join-Path $SourceRoot 'Services.ps1')
    . (Join-Path $SourceRoot 'WorkerClient.ps1')
    . (Join-Path $SourceRoot 'Demo.ps1')
    . (Join-Path $SourceRoot 'HttpServer.ps1')

    function New-TestConfig {
        param([string] $Folder)
        $template = Get-Content -LiteralPath (Join-Path $SourceRoot 'demo\CustomSettings.template.config') -Raw
        $content = [regex]::Replace($template, '\{\{(\w+)\}\}', {
                param($m)
                $value = switch ($m.Groups[1].Value) {
                    'DBPASSWORD' { 'secret&<value>' }
                    'INSTANCE' { 'TESTBC' }
                    default { '1' }
                }
                [Security.SecurityElement]::Escape($value)
            })
        New-Item -ItemType Directory -Force -Path $Folder | Out-Null
        $path = Join-Path $Folder 'CustomSettings.config'
        [IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))
        return $path
    }
}

Describe 'Repository hygiene' {
    It 'keeps every PowerShell file pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $files = Get-ChildItem -Path $RepoRoot -Recurse -Include *.ps1, *.psm1, *.psd1, *.cmd |
            Where-Object { $_.FullName -notmatch '[\\/](_original|\.git)[\\/]' }
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $file.Name
        }
    }

    It 'parses every PowerShell file without errors' {
        foreach ($file in (Get-ChildItem -Path $RepoRoot -Recurse -Include *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]_original[\\/]' })) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0 -Because $file.Name
        }
    }

    It 'has valid settings metadata with an "other" category' {
        $meta = Get-BcsaSettingsMeta
        $meta.categories.id | Should -Contain 'other'
        foreach ($category in $meta.categories) {
            foreach ($pattern in $category.patterns) { { [regex]::new($pattern) } | Should -Not -Throw }
        }
    }
}

Describe 'Split-BcsaServiceCommandLine' {
    It 'parses a quoted service command line' {
        $r = Split-BcsaServiceCommandLine '"C:\Program Files\BC\190\Service\Microsoft.Dynamics.Nav.Server.exe" $BC190 /config "C:\Program Files\BC\190\Service\Microsoft.Dynamics.Nav.Server.exe.config"'
        $r.ExePath | Should -Be 'C:\Program Files\BC\190\Service\Microsoft.Dynamics.Nav.Server.exe'
        $r.ConfigPath | Should -Be 'C:\Program Files\BC\190\Service\Microsoft.Dynamics.Nav.Server.exe.config'
    }

    It 'parses an unquoted command line without /config' {
        $r = Split-BcsaServiceCommandLine 'C:\BC\Service\Microsoft.Dynamics.Nav.Server.exe $NAV'
        $r.ExePath | Should -Be 'C:\BC\Service\Microsoft.Dynamics.Nav.Server.exe'
        $r.ConfigPath | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-BcsaCustomSettingsPath' {
    BeforeAll {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("bcsa-resolve-" + [guid]::NewGuid())
        $script:ServiceDir = Join-Path $Root 'Service'
        New-Item -ItemType Directory -Force -Path (Join-Path $ServiceDir 'Instances\EXTRA') | Out-Null
        Set-Content -LiteralPath (Join-Path $ServiceDir 'CustomSettings.config') -Value '<appSettings />'
        Set-Content -LiteralPath (Join-Path $ServiceDir 'Instances\EXTRA\CustomSettings.config') -Value '<appSettings />'
        Set-Content -LiteralPath (Join-Path $ServiceDir 'Instances\EXTRA\Other.config') -Value '<appSettings />'
        Set-Content -LiteralPath (Join-Path $ServiceDir 'Instances\EXTRA\Microsoft.Dynamics.Nav.Server.exe.config') -Value '<configuration><appSettings file="Other.config" /></configuration>'
    }
    AfterAll { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'follows the appSettings file attribute of the /config file' {
        $path = Resolve-BcsaCustomSettingsPath -ServiceDir $ServiceDir -InstanceName 'EXTRA' -ServerConfigPath (Join-Path $ServiceDir 'Instances\EXTRA\Microsoft.Dynamics.Nav.Server.exe.config')
        $path | Should -Be (Join-Path $ServiceDir 'Instances\EXTRA\Other.config')
    }

    It 'falls back to Instances\EXTRA\CustomSettings.config' {
        Resolve-BcsaCustomSettingsPath -ServiceDir $ServiceDir -InstanceName 'EXTRA' -ServerConfigPath $null |
            Should -Be (Join-Path $ServiceDir 'Instances\EXTRA\CustomSettings.config')
    }

    It 'falls back to the Service folder for the default instance' {
        Resolve-BcsaCustomSettingsPath -ServiceDir $ServiceDir -InstanceName 'BC' -ServerConfigPath $null |
            Should -Be (Join-Path $ServiceDir 'CustomSettings.config')
    }
}

Describe 'CustomSettings.config handling' {
    BeforeAll {
        $script:Folder = Join-Path ([IO.Path]::GetTempPath()) ("bcsa-config-" + [guid]::NewGuid())
        $script:Bcsa.BackupRoot = Join-Path $Folder 'backups'
    }
    BeforeEach { $script:ConfigPath = New-TestConfig -Folder $Folder }
    AfterAll { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads keys, values, descriptions and secret flags' {
        $data = Read-BcsaCustomSettings -Path $ConfigPath
        $data.settings.Count | Should -BeGreaterThan 100
        $network = $data.settings | Where-Object key -eq 'NetworkProtocol'
        $network.value | Should -Be 'Default'
        $network.description | Should -Be "Database connection protocol.`nValid options: Default, NamedPipes, Sockets"
        ($data.settings | Where-Object key -eq 'ProtectedDatabasePassword').secret | Should -BeTrue
        ($data.settings | Where-Object key -eq 'ProtectedDatabasePassword').value | Should -Be 'secret&<value>'
        ($data.settings | Where-Object key -eq 'DatabaseServer').secret | Should -BeFalse
    }

    It 'does not attach a standalone comment to the next key' {
        $data = Read-BcsaCustomSettings -Path $ConfigPath
        ($data.settings | Where-Object key -eq 'NetworkProtocol').description | Should -Not -Match 'Demo configuration'
    }

    It 'writes values in place and keeps comments, BOM and other settings' {
        $before = Read-BcsaCustomSettings -Path $ConfigPath
        $results = Set-BcsaCustomSettingsFile -Path $ConfigPath -Changes @(
            @{ key = 'TraceLevel'; value = 'Verbose' },
            @{ key = 'PublicWebBaseUrl'; value = 'https://bc/x?a=1&b="2"' },
            @{ key = 'DoesNotExist'; value = 'x' })
        ($results | Where-Object key -eq 'TraceLevel').ok | Should -BeTrue
        ($results | Where-Object key -eq 'DoesNotExist').ok | Should -BeFalse

        $bytes = [IO.File]::ReadAllBytes($ConfigPath)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $after = Read-BcsaCustomSettings -Path $ConfigPath
        ($after.settings | Where-Object key -eq 'TraceLevel').value | Should -Be 'Verbose'
        ($after.settings | Where-Object key -eq 'PublicWebBaseUrl').value | Should -Be 'https://bc/x?a=1&b="2"'
        ($after.settings | Where-Object key -eq 'TraceLevel').description | Should -Not -BeNullOrEmpty
        $after.settings.Count | Should -Be $before.settings.Count
        $after.stamp | Should -Not -Be $before.stamp
    }

    It 'creates, lists and restores backups' {
        $instance = [pscustomobject]@{ name = 'TESTBC'; configPath = $ConfigPath }
        $backup = New-BcsaBackup -Instance $instance -Reason 'manual'
        $backup.name | Should -Match '^CustomSettings_\d{8}_\d{6}_\d{3}_manual\.config$'
        [void](Set-BcsaCustomSettingsFile -Path $ConfigPath -Changes @(@{ key = 'TraceLevel'; value = 'Off' }))

        (Get-BcsaBackup -Instance $instance).items.name | Should -Contain $backup.name
        $result = Restore-BcsaBackup -Instance $instance -Name $backup.name
        $result.backup | Should -Match 'before-restore'
        ((Read-BcsaCustomSettings -Path $ConfigPath).settings | Where-Object key -eq 'TraceLevel').value | Should -Be 'Normal'
    }

    It 'rejects backup names that could escape the backup folder' {
        $instance = [pscustomobject]@{ name = 'TESTBC'; configPath = $ConfigPath }
        { Restore-BcsaBackup -Instance $instance -Name '..\..\evil.config' } | Should -Throw
    }

    It 'exports with secrets redacted unless requested' {
        $instance = [pscustomobject]@{ name = 'TESTBC'; configPath = $ConfigPath; version = '25.0.0.0' }
        $csv = Export-BcsaConfiguration -Instance $instance -Format Csv
        $csv.content | Should -Not -Match 'secret&<value>'
        $csv.content | Should -Match '\*{8}'
        $html = Export-BcsaConfiguration -Instance $instance -Format Html -IncludeSecrets -Language es
        $html.content | Should -Match 'secret&amp;&lt;value&gt;'
        $html.fileName | Should -Match '^TESTBC-config-\d{8}-\d{6}\.html$'
        $json = (Export-BcsaConfiguration -Instance $instance -Format Json).content | ConvertFrom-Json
        $json.instance | Should -Be 'TESTBC'
        ($json.settings | Where-Object key -eq 'DatabaseServer').category | Should -Be 'database'
    }
}

Describe 'Setting categories' {
    It 'maps <Key> to <Category>' -ForEach @(
        @{ Key = 'DatabaseServer'; Category = 'database' }
        @{ Key = 'SqlLongRunningThreshold'; Category = 'telemetry' }
        @{ Key = 'EnableSqlInformationDebugger'; Category = 'development' }
        @{ Key = 'ClientServicesTokenSigningKey'; Category = 'entra' }
        @{ Key = 'ODataServicesPort'; Category = 'odata' }
        @{ Key = 'ApiSubscriptionsEnabled'; Category = 'api' }
        @{ Key = 'NASServicesEnableDebugging'; Category = 'nas' }
        @{ Key = 'SomethingNew'; Category = 'other' }
    ) {
        (Get-BcsaSettingCategory -Key $Key).id | Should -Be $Category
    }
}

Describe 'Helpers' {
    It 'compares tokens in constant time semantics' {
        Test-BcsaTokenEqual -Expected 'abc' -Actual 'abc' | Should -BeTrue
        Test-BcsaTokenEqual -Expected 'abc' -Actual 'abd' | Should -BeFalse
        Test-BcsaTokenEqual -Expected 'abc' -Actual '' | Should -BeFalse
        Test-BcsaTokenEqual -Expected 'abc' -Actual 'abcd' | Should -BeFalse
    }

    It 'generates 64-character hex tokens' {
        New-BcsaToken | Should -Match '^[0-9a-f]{64}$'
    }

    It 'detects secret keys' {
        Test-BcsaSecretKey 'ProtectedDatabasePassword' | Should -BeTrue
        Test-BcsaSecretKey 'AzureActiveDirectoryClientSecret' | Should -BeTrue
        Test-BcsaSecretKey 'ApplicationInsightsConnectionString' | Should -BeTrue
        Test-BcsaSecretKey 'DatabaseUserName' | Should -BeFalse
        Test-BcsaSecretKey 'AzureKeyVaultAppSecretsPublisherValidationEnabled' | Should -BeFalse
    }

    It 'dedents XML comments' {
        Format-BcsaComment "`n    First line`n      indented`n" | Should -Be "First line`n  indented"
    }
}

Describe 'Worker protocol' {
    BeforeAll {
        $script:Bcsa.WorkerPath = Join-Path $SourceRoot 'Worker.ps1'
        $script:Bcsa.WorkerHost = 'WindowsPowerShell'
        $script:Bcsa.Demo = $false
        $script:MissingDir = Join-Path ([IO.Path]::GetTempPath()) ("bcsa-no-bc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $MissingDir | Out-Null
    }
    AfterAll {
        Stop-BcsaAllWorkers
        Remove-Item -LiteralPath $MissingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports a clear error when no BC management module exists' {
        $instance = [pscustomobject]@{ name = 'NONE'; serviceDir = $MissingDir; major = 20 }
        $err = $null
        try { Invoke-BcsaWorker -Instance $instance -Command 'ping' } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.Data['BcsaCode'] | Should -Be 'worker_unavailable'
        $err.Message | Should -Match 'No Business Central management module found'
        (Get-BcsaWorkerStatus -ServiceDir $MissingDir).state | Should -Be 'failed'
    }

    It 'answers a request that arrives with a UTF-8 BOM in front (Windows PowerShell stdin on code page 65001)' {
        $worker = Get-BcsaReadyWorker -ServiceDir $MissingDir -Major 20
        $json = '{"id":77,"cmd":"ping","args":{}}'
        $worker.Process.StandardInput.WriteLine([string][char]0xFEFF + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
        $worker.Process.StandardInput.Flush()
        $response = Read-BcsaWorkerMessage -Worker $worker -TimeoutSeconds 30
        $response.id | Should -Be 77
        $response.ok | Should -BeFalse
    }
}

Describe 'HTTP server (demo mode)' -Tag 'Integration' {
    BeforeAll {
        $script:Port = Get-BcsaFreePort
        $shell = (Get-Process -Id $PID).Path
        $script:LogFile = Join-Path ([IO.Path]::GetTempPath()) ("bcsa-server-" + [guid]::NewGuid() + '.log')
        $script:Server = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -RedirectStandardOutput $LogFile -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $RepoRoot 'Start-BCServerAdmin.ps1')`"", '-Demo', '-NoBrowser', '-Port', $Port)
        $script:Token = $null
        for ($i = 0; $i -lt 60 -and -not $Token; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Path $LogFile) {
                $match = [regex]::Match([string](Get-Content -LiteralPath $LogFile -Raw), 't=([0-9a-f]{64})')
                if ($match.Success) { $script:Token = $match.Groups[1].Value }
            }
        }
        $script:Base = "http://localhost:$Port"
        $script:Headers = @{ 'X-BCSA-Token' = $Token }

        function Invoke-Api {
            param([string] $Method = 'GET', [string] $Path, $Body, [hashtable] $ExtraHeaders = @{})
            $request = [System.Net.HttpWebRequest]::Create("$Base$Path")
            $request.Method = $Method
            foreach ($k in ($Headers + $ExtraHeaders).GetEnumerator()) {
                if ($k.Key -eq 'Content-Type') { $request.ContentType = $k.Value } else { $request.Headers[$k.Key] = $k.Value }
            }
            if ($null -ne $Body) {
                if (-not $request.ContentType) { $request.ContentType = 'application/json' }
                $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress))
                $stream = $request.GetRequestStream(); $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
            }
            try { $response = $request.GetResponse() } catch [System.Net.WebException] { $response = $_.Exception.Response }
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $text = $reader.ReadToEnd(); $reader.Close()
            $json = $null
            try { $json = $text | ConvertFrom-Json } catch { }
            [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $json; Text = $text }
        }
    }

    AfterAll {
        if ($Token) { try { Invoke-Api -Method POST -Path '/api/shutdown' -Body @{} | Out-Null } catch { } }
        if ($Server -and -not $Server.WaitForExit(10000)) { $Server | Stop-Process -Force }
        Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
    }

    It 'starts and prints the session URL' {
        $Token | Should -Match '^[0-9a-f]{64}$'
    }

    It 'requires the token' {
        $script:Headers = @{}
        (Invoke-Api -Path '/api/info').Status | Should -Be 401
        $script:Headers = @{ 'X-BCSA-Token' = $Token }
    }

    It 'rejects cross-origin writes' {
        (Invoke-Api -Method POST -Path '/api/instances/BC252/service' -Body @{ action = 'stop' } -ExtraHeaders @{ Origin = 'http://evil.example' }).Status | Should -Be 403
    }

    It 'rejects non-JSON writes' {
        (Invoke-Api -Method POST -Path '/api/instances/BC252/service' -Body @{ action = 'stop' } -ExtraHeaders @{ 'Content-Type' = 'text/plain' }).Status | Should -Be 415
    }

    It 'lists the demo instances' {
        $r = Invoke-Api -Path '/api/instances'
        $r.Status | Should -Be 200
        $r.Json.items.name | Should -Be @('BC190', 'BC252', 'BC252_TEST', 'BC270')
    }

    It 'saves configuration with a backup and optimistic concurrency' {
        $config = (Invoke-Api -Path '/api/instances/BC252/config').Json
        (Invoke-Api -Method POST -Path '/api/instances/BC252/config' -Body @{ changes = @(@{ key = 'TraceLevel'; value = 'Error' }); stamp = 'old' }).Status | Should -Be 409
        $r = Invoke-Api -Method POST -Path '/api/instances/BC252/config' -Body @{ changes = @(@{ key = 'TraceLevel'; value = 'Error' }); stamp = $config.stamp; applyToMemory = $true }
        $r.Status | Should -Be 200
        $r.Json.backup | Should -Match 'before-save'
        $r.Json.results[0].ok | Should -BeTrue
        $r.Json.results[0].memory.ok | Should -BeTrue
    }

    It 'refuses read-only settings' {
        (Invoke-Api -Method POST -Path '/api/instances/BC252/config' -Body @{ changes = @(@{ key = 'ServerInstance'; value = 'X' }) }).Json.code | Should -Be 'read_only'
    }

    It 'serves the web UI with a strict CSP' {
        $response = [System.Net.WebRequest]::Create("$Base/").GetResponse()
        try { $response.Headers['Content-Security-Policy'] | Should -Match "default-src 'self'" } finally { $response.Close() }
    }
}
