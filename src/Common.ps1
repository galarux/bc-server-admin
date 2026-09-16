# Shared state and helpers for bc-server-admin.
# NOTE: keep every .ps1 file in this project pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$script:BcsaVersion = '1.0.0'
$script:BcsaServicePrefix = 'MicrosoftDynamicsNavServer$'
$script:BcsaSecretPattern = '(?i)(password|secret|connectionstring|instrumentationkey|tokensigningkey)$'

$script:Bcsa = @{
    Demo         = $false
    ComputerName = $env:COMPUTERNAME
    UserName     = '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName
    BackupRoot   = $null
    WorkerHost   = 'Auto'
    WorkerPath   = $null
    Running      = $true
}

function Initialize-BcsaState {
    param(
        [switch] $Demo,
        [string] $BackupRoot,
        [string] $WorkerHost = 'Auto',
        [string] $SourceRoot
    )
    $script:Bcsa.Demo = [bool]$Demo
    $script:Bcsa.BackupRoot = $BackupRoot
    $script:Bcsa.WorkerHost = $WorkerHost
    $script:Bcsa.WorkerPath = Join-Path $SourceRoot 'Worker.ps1'
    $script:Bcsa.Running = $true
    if ($Demo) {
        # Fictitious identity so demo screenshots and exports never show the real machine.
        $script:Bcsa.ComputerName = 'BCSRV01'
        $script:Bcsa.UserName = 'CONTOSO\bc.admin'
        Initialize-BcsaDemo -SourceRoot $SourceRoot
    }
}

function Write-BcsaLog {
    param(
        [string] $Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Ok')]
        [string] $Level = 'Info'
    )
    $colors = @{ Info = 'Gray'; Warn = 'Yellow'; Error = 'Red'; Ok = 'Green' }
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $colors[$Level]
}

function Test-BcsaAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-BcsaSecretKey {
    param([string] $Key)
    return ($Key -match $script:BcsaSecretPattern)
}

function ConvertTo-BcsaJson {
    param($InputObject)
    return (ConvertTo-Json -InputObject $InputObject -Depth 10 -Compress)
}

function Get-BcsaFreePort {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return $probe.LocalEndpoint.Port } finally { $probe.Stop() }
}

function New-BcsaToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-BcsaTokenEqual {
    # Constant-time comparison so the token cannot be guessed byte by byte.
    param([string] $Expected, [string] $Actual)
    if ([string]::IsNullOrEmpty($Actual) -or $Expected.Length -ne $Actual.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $Expected.Length; $i++) { $diff = $diff -bor ([int][char]$Expected[$i] -bxor [int][char]$Actual[$i]) }
    return ($diff -eq 0)
}

function Get-BcsaSafeFileName {
    param([string] $Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    return (-join ($Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } }))
}

function Stop-BcsaRequest {
    # Throws an exception the HTTP layer turns into a JSON error with the given status/code.
    param([int] $Status, [string] $Code, [string] $Message)
    $exception = New-Object System.Exception($Message)
    $exception.Data['BcsaStatus'] = $Status
    $exception.Data['BcsaCode'] = $Code
    throw $exception
}
