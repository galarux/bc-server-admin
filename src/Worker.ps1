<#
    bc-server-admin worker process.

    Loads the Business Central management module that belongs to ONE Service folder and
    executes commands received on stdin. Running one worker per Service folder lets
    side-by-side BC versions coexist (their assemblies cannot share a process).

    Protocol (one line per message, ASCII only):
      request  : base64(UTF-8 JSON {id, cmd, args})
      response : "@@BCSA@@" + base64(UTF-8 JSON {id, ok, result | error})
    Anything else written to stdout (module banners, Write-Host...) is ignored by the host.
    The first response (id 0) reports whether the module could be loaded.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ServiceDir', Justification = 'Used by the functions below (script scope).')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ServiceDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$MessagePrefix = '@@BCSA@@'

function Send-Message {
    param([hashtable] $Message)
    $json = ConvertTo-Json -InputObject $Message -Depth 10 -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    [Console]::Out.WriteLine($MessagePrefix + $payload)
    [Console]::Out.Flush()
}

function ConvertTo-PlainValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [enum] -or $Value -is [guid] -or $Value -is [timespan] -or $Value -is [version]) { return $Value.ToString() }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value) | ForEach-Object { [string]$_ }) -join ', ' }
    return [string]$Value
}

function ConvertTo-PlainObject {
    param($InputObject)
    $result = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.MemberType -notin @('Property', 'NoteProperty', 'AliasProperty')) { continue }
        try { $result[$property.Name] = ConvertTo-PlainValue $property.Value } catch { $result[$property.Name] = $null }
    }
    return $result
}

function Import-BcManagementModule {
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $adminPsd1 = Join-Path $ServiceDir 'Admin\Microsoft.BusinessCentral.Management.psd1'
    $rootPsm1 = Join-Path $ServiceDir 'Microsoft.Dynamics.Nav.Management.psm1'
    $compatDll = Join-Path $ServiceDir 'Management\Microsoft.Dynamics.Nav.Management.dll'
    $rootDll = Join-Path $ServiceDir 'Microsoft.Dynamics.Nav.Management.dll'

    # From BC 29 the Admin module is pure PowerShell and loads in both editions.
    $adminIsUniversal = $false
    if (Test-Path -LiteralPath $adminPsd1) {
        try {
            $manifest = Import-PowerShellDataFile -LiteralPath $adminPsd1
            $adminIsUniversal = ([version]$manifest.ModuleVersion).Major -ge 29
        } catch { }
    }

    $candidates = @()
    if ($isCore) {
        $candidates = @($adminPsd1, $rootPsm1)
    } else {
        if ($adminIsUniversal) { $candidates += $adminPsd1 }
        $candidates += @($rootPsm1, $compatDll, $rootDll)
    }

    $errors = @()
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            Import-Module -Name $candidate -DisableNameChecking -Global -Force -ErrorAction Stop -WarningAction SilentlyContinue *> $null
            if (Get-Command -Name 'Set-NAVServerConfiguration' -ErrorAction SilentlyContinue) {
                return @{ ok = $true; module = $candidate; error = $null }
            }
            $errors += "${candidate}: module loaded but Set-NAVServerConfiguration is not available"
        } catch {
            $errors += "${candidate}: $($_.Exception.Message)"
        }
    }
    if ($errors.Count -eq 0) { $errors += "No Business Central management module found in $ServiceDir" }
    return @{ ok = $false; module = $null; error = ($errors -join ' | ') }
}

function Test-CommandParameter {
    param([string] $Command, [string] $Parameter)
    $cmd = Get-Command -Name $Command -ErrorAction SilentlyContinue
    return ($null -ne $cmd -and $cmd.Parameters.ContainsKey($Parameter))
}

function Invoke-GetSessions {
    param($Arguments)
    $params = @{ ServerInstance = [string]$Arguments.instance }
    if ($Arguments.tenant) { $params.Tenant = [string]$Arguments.tenant }
    $sessions = @(Get-NAVServerSession @params)
    return @{ items = @($sessions | ForEach-Object { ConvertTo-PlainObject $_ }) }
}

function Invoke-RemoveSession {
    param($Arguments)
    $params = @{ ServerInstance = [string]$Arguments.instance; SessionId = [int]$Arguments.sessionId }
    if ($Arguments.tenant) { $params.Tenant = [string]$Arguments.tenant }
    if (Test-CommandParameter 'Remove-NAVServerSession' 'Force') { $params.Force = $true }
    Remove-NAVServerSession @params -Confirm:$false
    return @{ removed = [int]$Arguments.sessionId }
}

function Invoke-GetTenants {
    param($Arguments)
    $tenants = @(Get-NAVTenant -ServerInstance ([string]$Arguments.instance))
    return @{ items = @($tenants | ForEach-Object { ConvertTo-PlainObject $_ }) }
}

function Invoke-SetConfig {
    param($Arguments)
    $instance = [string]$Arguments.instance
    $supportsApplyTo = Test-CommandParameter 'Set-NAVServerConfiguration' 'ApplyTo'
    $results = @()
    foreach ($change in @($Arguments.changes)) {
        $item = [ordered]@{ key = [string]$change.key; ok = $false; error = $null; memory = $null }
        $params = @{ ServerInstance = $instance; KeyName = [string]$change.key; KeyValue = [string]$change.value }
        try {
            if ($supportsApplyTo) { $params.ApplyTo = 'ConfigFile' }
            Set-NAVServerConfiguration @params -WarningAction SilentlyContinue -Confirm:$false *> $null
            $item.ok = $true
        } catch {
            $item.error = $_.Exception.Message
        }
        if ($item.ok -and $Arguments.applyToMemory) {
            if (-not $supportsApplyTo) {
                $item.memory = @{ ok = $false; error = 'ApplyTo is not supported by this version' }
            } else {
                try {
                    $params.ApplyTo = 'Memory'
                    Set-NAVServerConfiguration @params -WarningAction SilentlyContinue -Confirm:$false *> $null
                    $item.memory = @{ ok = $true; error = $null }
                } catch {
                    $item.memory = @{ ok = $false; error = $_.Exception.Message }
                }
            }
        }
        $results += $item
    }
    return @{ items = @($results) }
}

function Invoke-SetDatabaseCredentials {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password arrives from the local web UI and is only turned into a PSCredential for Set-NAVServerConfiguration.')]
    param($Arguments)
    $password = ConvertTo-SecureString -String ([string]$Arguments.password) -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ([string]$Arguments.user, $password)
    Set-NAVServerConfiguration -ServerInstance ([string]$Arguments.instance) -DatabaseCredentials $credential -WarningAction SilentlyContinue -Confirm:$false *> $null
    return @{ ok = $true }
}

$module = Import-BcManagementModule
Send-Message @{
    id     = 0
    ok     = $true
    result = @{
        moduleLoaded = $module.ok
        module       = $module.module
        error        = $module.error
        psVersion    = $PSVersionTable.PSVersion.ToString()
        psEdition    = [string]$PSVersionTable.PSEdition
        pid          = $PID
    }
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }

    $id = $null
    try {
        # Windows PowerShell's Process.StandardInput writes a UTF-8 BOM when the console code page is 65001;
        # keep only base64 characters so the first request is not corrupted.
        $payload = $line -replace '[^A-Za-z0-9+/=]', ''
        if (-not $payload) { continue }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $request = ConvertFrom-Json -InputObject $json
        $id = $request.id

        if ($request.cmd -eq 'exit') {
            Send-Message @{ id = $id; ok = $true; result = @{} }
            break
        }
        if (-not $module.ok) { throw "Business Central management module is not loaded: $($module.error)" }

        $result = switch ([string]$request.cmd) {
            'ping'                   { @{ module = $module.module } }
            'getSessions'            { Invoke-GetSessions $request.args }
            'removeSession'          { Invoke-RemoveSession $request.args }
            'getTenants'             { Invoke-GetTenants $request.args }
            'setConfig'              { Invoke-SetConfig $request.args }
            'setDatabaseCredentials' { Invoke-SetDatabaseCredentials $request.args }
            default                  { throw "Unknown command '$($request.cmd)'" }
        }
        Send-Message @{ id = $id; ok = $true; result = $result }
    } catch {
        Send-Message @{ id = $id; ok = $false; error = $_.Exception.Message }
    }
}
