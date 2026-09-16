# Discovers Business Central server instances from the Windows services on this machine.

function Split-BcsaServiceCommandLine {
    # PathName looks like: "C:\...\Microsoft.Dynamics.Nav.Server.exe" $BC190 /config "C:\...\Microsoft.Dynamics.Nav.Server.exe.config"
    param([string] $PathName)
    $exePath = $null
    $configPath = $null
    if ($PathName -match '^\s*"([^"]+)"') { $exePath = $Matches[1] }
    elseif ($PathName -match '^\s*(\S+)') { $exePath = $Matches[1] }
    if ($PathName -match '/config\s+"([^"]+)"') { $configPath = $Matches[1] }
    elseif ($PathName -match '/config\s+(\S+)') { $configPath = $Matches[1] }
    return @{ ExePath = $exePath; ConfigPath = $configPath }
}

function Resolve-BcsaCustomSettingsPath {
    param(
        [string] $ServiceDir,
        [string] $InstanceName,
        [string] $ServerConfigPath
    )
    $candidates = @()
    if ($ServerConfigPath -and (Test-Path -LiteralPath $ServerConfigPath)) {
        $fileName = 'CustomSettings.config'
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.Load($ServerConfigPath)
            $node = $doc.SelectSingleNode('/configuration/appSettings')
            if ($node -and $node.GetAttribute('file')) { $fileName = $node.GetAttribute('file') }
        } catch { }
        $candidates += [IO.Path]::Combine((Split-Path -Parent $ServerConfigPath), $fileName)
    }
    if ($ServiceDir) {
        $candidates += Join-Path $ServiceDir ("Instances\{0}\CustomSettings.config" -f $InstanceName)
        $candidates += Join-Path $ServiceDir 'CustomSettings.config'
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Get-BcsaInstance {
    <#
        Returns one object per BC server instance (Windows service MicrosoftDynamicsNavServer$<name>).
        -Name filters to a single instance (case-insensitive) and returns $null when it does not exist.
    #>
    param([string] $Name)

    if ($script:Bcsa.Demo) { return Get-BcsaDemoInstance -Name $Name }

    # WQL LIKE treats '_' and '[' as wildcards, so filter again with -like.
    $services = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MicrosoftDynamicsNavServer%'" -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith($script:BcsaServicePrefix, [StringComparison]::OrdinalIgnoreCase) })

    $result = @()
    foreach ($service in ($services | Sort-Object Name)) {
        $instanceName = $service.Name.Substring($script:BcsaServicePrefix.Length)
        if ($Name -and $instanceName -ne $Name) { continue }

        $paths = Split-BcsaServiceCommandLine $service.PathName
        $serviceDir = $null
        $version = $null
        if ($paths.ExePath) {
            $serviceDir = Split-Path -Parent $paths.ExePath
            if (Test-Path -LiteralPath $paths.ExePath) {
                $version = (Get-Item -LiteralPath $paths.ExePath).VersionInfo.FileVersion
            }
        }
        $major = 0
        if ($version -and $version -match '^(\d+)') { $major = [int]$Matches[1] }

        $result += [pscustomobject]@{
            name        = $instanceName
            serviceName = $service.Name
            displayName = $service.DisplayName
            state       = ([string]$service.State) -replace '\s', ''
            startMode   = [string]$service.StartMode
            account     = [string]$service.StartName
            processId   = [int]$service.ProcessId
            exePath     = $paths.ExePath
            serviceDir  = $serviceDir
            version     = $version
            major       = $major
            configPath  = (Resolve-BcsaCustomSettingsPath -ServiceDir $serviceDir -InstanceName $instanceName -ServerConfigPath $paths.ConfigPath)
        }
    }
    if ($Name) { return ($result | Select-Object -First 1) }
    return $result
}

function Get-BcsaInstanceOrFail {
    param([string] $Name)
    $instance = Get-BcsaInstance -Name $Name
    if (-not $instance) { Stop-BcsaRequest 404 'instance_not_found' "Server instance '$Name' was not found." }
    return $instance
}

function Get-BcsaInstanceSummary {
    # Adds the most relevant settings (database, ports, auth) to an instance for the overview.
    param($Instance)
    $values = @{}
    if ($Instance.configPath) {
        try {
            foreach ($setting in (Read-BcsaCustomSettings -Path $Instance.configPath).settings) { $values[$setting.key] = $setting.value }
        } catch { }
    }
    $pick = {
        param([string] $Key)
        if ($values.ContainsKey($Key)) { return $values[$Key] }
        return $null
    }
    return [ordered]@{
        databaseServer           = & $pick 'DatabaseServer'
        databaseInstance         = & $pick 'DatabaseInstance'
        databaseName             = & $pick 'DatabaseName'
        credentialType           = & $pick 'ClientServicesCredentialType'
        multitenant              = & $pick 'Multitenant'
        publicWebBaseUrl         = & $pick 'PublicWebBaseUrl'
        publicSoapBaseUrl        = & $pick 'PublicSOAPBaseUrl'
        publicODataBaseUrl       = & $pick 'PublicODataBaseUrl'
        clientServicesPort       = & $pick 'ClientServicesPort'
        clientServicesEnabled    = & $pick 'ClientServicesEnabled'
        soapPort                 = & $pick 'SOAPServicesPort'
        soapEnabled              = & $pick 'SOAPServicesEnabled'
        soapSsl                  = & $pick 'SOAPServicesSSLEnabled'
        odataPort                = & $pick 'ODataServicesPort'
        odataEnabled             = & $pick 'ODataServicesEnabled'
        odataSsl                 = & $pick 'ODataServicesSSLEnabled'
        apiEnabled               = & $pick 'ApiServicesEnabled'
        developerPort            = & $pick 'DeveloperServicesPort'
        developerEnabled         = & $pick 'DeveloperServicesEnabled'
        developerSsl             = & $pick 'DeveloperServicesSSLEnabled'
        managementPort           = & $pick 'ManagementServicesPort'
        managementEnabled        = & $pick 'ManagementServicesEnabled'
        managementApiPort        = & $pick 'ManagementApiServicesPort'
        managementApiEnabled     = & $pick 'ManagementApiServicesEnabled'
        snapshotDebuggerPort     = & $pick 'SnapshotDebuggerServicesPort'
        snapshotDebuggerEnabled  = & $pick 'SnapshotDebuggerEnabled'
    }
}

function ConvertTo-BcsaInstanceView {
    param($Instance)
    $view = [ordered]@{}
    foreach ($property in $Instance.PSObject.Properties) { $view[$property.Name] = $property.Value }
    $view['pendingAction'] = Get-BcsaPendingAction -Name $Instance.name
    $view['summary'] = Get-BcsaInstanceSummary -Instance $Instance
    $view['worker'] = Get-BcsaWorkerStatus -ServiceDir $Instance.serviceDir
    return $view
}
