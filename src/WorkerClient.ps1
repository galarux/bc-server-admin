# Host side of the worker protocol (see Worker.ps1). One worker process per BC Service folder.

$script:BcsaWorkers = @{}
$script:BcsaWorkerSeq = 0
$script:BcsaWorkerPrefix = '@@BCSA@@'

function Get-BcsaPowerShellPath {
    param([ValidateSet('WindowsPowerShell', 'PowerShell7')] [string] $Kind)
    if ($Kind -eq 'PowerShell7') {
        $pwsh = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwsh) { return $pwsh.Source }
        $default = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $default) { return $default }
        return $null
    }
    # A 32-bit host must still start the 64-bit Windows PowerShell (BC is 64-bit only).
    $system = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $system = 'Sysnative' }
    return (Join-Path $env:SystemRoot "$system\WindowsPowerShell\v1.0\powershell.exe")
}

function Get-BcsaWorkerHostOrder {
    # BC <= 23: Windows PowerShell only. BC 24-28: PowerShell 7 preferred (Windows PowerShell uses a
    # compatibility module). BC 29+: both work, Windows PowerShell is always present.
    param([int] $Major)
    switch ($script:Bcsa.WorkerHost) {
        'WindowsPowerShell' { return @('WindowsPowerShell') }
        'PowerShell7' { return @('PowerShell7') }
    }
    if ($Major -ge 24 -and $Major -le 28) { return @('PowerShell7', 'WindowsPowerShell') }
    return @('WindowsPowerShell')
}

function Start-BcsaWorkerProcess {
    param([string] $ServiceDir, [string] $HostPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostPath
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ServiceDir "{1}"' -f $script:Bcsa.WorkerPath, $ServiceDir.TrimEnd('\')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path -Parent $script:Bcsa.WorkerPath
    return [System.Diagnostics.Process]::Start($psi)
}

function Read-BcsaWorkerMessage {
    param($Worker, [int] $TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if (-not $Worker.PendingRead) { $Worker.PendingRead = $Worker.Process.StandardOutput.ReadLineAsync() }
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0 -or -not $Worker.PendingRead.Wait($remaining)) {
            Stop-BcsaWorker -Worker $Worker
            throw "The PowerShell worker did not answer within $TimeoutSeconds seconds."
        }
        $line = $Worker.PendingRead.Result
        $Worker.PendingRead = $null
        if ($null -eq $line) {
            Stop-BcsaWorker -Worker $Worker
            throw 'The PowerShell worker exited unexpectedly.'
        }
        $message = ConvertFrom-BcsaWorkerLine $line
        if ($message) { return $message }
        # Anything else is host noise from the BC module; ignore it.
    }
}

function ConvertFrom-BcsaWorkerLine {
    # Returns the decoded message, or $null when the line is not a protocol line.
    param([string] $Line)
    $index = $Line.IndexOf($script:BcsaWorkerPrefix, [StringComparison]::Ordinal)
    if ($index -lt 0) { return $null }
    $payload = $Line.Substring($index + $script:BcsaWorkerPrefix.Length).Trim()
    return (ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))))
}

function Stop-BcsaWorker {
    param($Worker)
    $Worker.Alive = $false
    try {
        if (-not $Worker.Process.HasExited) {
            try { $Worker.Process.StandardInput.Close() } catch { }
            if (-not $Worker.Process.WaitForExit(2000)) { $Worker.Process.Kill() }
        }
    } catch { }
    try { $Worker.Process.Dispose() } catch { }
}

function Start-BcsaWorker {
    <# Starts (without waiting) the worker for a Service folder, so the module loads in the background. #>
    param([string] $ServiceDir, [int] $Major, [int] $Attempt = 0)
    $key = $ServiceDir.ToLowerInvariant()
    $existing = $script:BcsaWorkers[$key]
    if ($existing -and $existing.Alive -and $Attempt -eq 0) { return $existing }

    $order = @(Get-BcsaWorkerHostOrder -Major $Major)
    $kind = $null
    $hostPath = $null
    for ($i = $Attempt; $i -lt $order.Count; $i++) {
        $hostPath = Get-BcsaPowerShellPath -Kind $order[$i]
        if ($hostPath) { $kind = $order[$i]; $Attempt = $i; break }
    }
    if (-not $hostPath) { throw "No suitable PowerShell host found (tried: $($order -join ', '))." }

    $worker = @{
        Key         = $key
        ServiceDir  = $ServiceDir
        Major       = $Major
        Attempt     = $Attempt
        HostKind    = $kind
        HostPath    = $hostPath
        Process     = (Start-BcsaWorkerProcess -ServiceDir $ServiceDir -HostPath $hostPath)
        PendingRead = $null
        Ready       = $null
        Announced   = $false
        Alive       = $true
        LastError   = $null
    }
    $script:BcsaWorkers[$key] = $worker
    return $worker
}

function Complete-BcsaWorkerHello {
    <# Handles a received hello. Returns the same worker, or a new one started with the next PowerShell host when the module failed to load. #>
    param($Worker)
    if ($Worker.Announced) { return $Worker }
    $Worker.Announced = $true
    if ($Worker.Ready.moduleLoaded) {
        Write-BcsaLog ("BC module ready for {0} ({1} {2})" -f $Worker.ServiceDir, $Worker.HostKind, $Worker.Ready.psVersion) -Level Ok
        return $Worker
    }
    $Worker.LastError = $Worker.Ready.error
    Write-BcsaLog ("Could not load the BC module for {0} with {1}: {2}" -f $Worker.ServiceDir, $Worker.HostKind, $Worker.Ready.error) -Level Warn
    $nextAttempt = $Worker.Attempt + 1
    if ($nextAttempt -ge @(Get-BcsaWorkerHostOrder -Major $Worker.Major).Count) { return $Worker }
    Stop-BcsaWorker -Worker $Worker
    return (Start-BcsaWorker -ServiceDir $Worker.ServiceDir -Major $Worker.Major -Attempt $nextAttempt)
}

function Get-BcsaReadyWorker {
    param([string] $ServiceDir, [int] $Major)
    $worker = Start-BcsaWorker -ServiceDir $ServiceDir -Major $Major
    while ($true) {
        if (-not $worker.Ready) {
            try {
                $worker.Ready = (Read-BcsaWorkerMessage -Worker $worker -TimeoutSeconds 240).result
            } catch {
                $worker.LastError = $_.Exception.Message
                throw
            }
        }
        $next = Complete-BcsaWorkerHello -Worker $worker
        if ([object]::ReferenceEquals($next, $worker)) { return $worker }
        $worker = $next
    }
}

function Update-BcsaWorkers {
    # Non-blocking: picks up hello messages that already arrived so the UI can show the module state.
    foreach ($worker in @($script:BcsaWorkers.Values)) {
        if (-not $worker.Alive -or $worker.Ready) { continue }
        try {
            while (-not $worker.Ready) {
                if (-not $worker.PendingRead) { $worker.PendingRead = $worker.Process.StandardOutput.ReadLineAsync() }
                if (-not $worker.PendingRead.IsCompleted) { break }
                $line = $worker.PendingRead.Result
                $worker.PendingRead = $null
                if ($null -eq $line) {
                    $worker.LastError = 'The PowerShell worker exited unexpectedly.'
                    Stop-BcsaWorker -Worker $worker
                    break
                }
                $message = ConvertFrom-BcsaWorkerLine $line
                if ($message) {
                    $worker.Ready = $message.result
                    [void](Complete-BcsaWorkerHello -Worker $worker)
                }
            }
        } catch {
            $worker.LastError = $_.Exception.Message
        }
    }
}

function Invoke-BcsaWorker {
    <# Runs a worker command and returns its result; throws a 503 'worker_unavailable' error when the module cannot be used. #>
    param(
        $Instance,
        [string] $Command,
        [hashtable] $Arguments = @{},
        [int] $TimeoutSeconds = 300
    )
    if ($script:Bcsa.Demo) { return Invoke-BcsaDemoWorker -Instance $Instance -Command $Command -Arguments $Arguments }
    if (-not $Instance.serviceDir) { Stop-BcsaRequest 503 'worker_unavailable' 'The Service folder of this instance is unknown.' }

    try {
        $worker = Get-BcsaReadyWorker -ServiceDir $Instance.serviceDir -Major $Instance.major
    } catch {
        Stop-BcsaRequest 503 'worker_unavailable' $_.Exception.Message
    }
    if (-not $worker.Ready.moduleLoaded) {
        Stop-BcsaRequest 503 'worker_unavailable' "The Business Central management module could not be loaded: $($worker.Ready.error)"
    }

    $script:BcsaWorkerSeq++
    $id = $script:BcsaWorkerSeq
    $request = ConvertTo-BcsaJson @{ id = $id; cmd = $Command; args = $Arguments }
    try {
        $worker.Process.StandardInput.WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request)))
        $worker.Process.StandardInput.Flush()
        # A null id means the worker could not even parse the request; it answers the current call.
        do { $response = Read-BcsaWorkerMessage -Worker $worker -TimeoutSeconds $TimeoutSeconds } while ($null -ne $response.id -and $response.id -ne $id)
    } catch {
        Stop-BcsaWorker -Worker $worker
        Stop-BcsaRequest 503 'worker_unavailable' $_.Exception.Message
    }
    if (-not $response.ok) { Stop-BcsaRequest 422 'bc_error' $response.error }
    return $response.result
}

function Get-BcsaWorkerStatus {
    param([string] $ServiceDir)
    if ($script:Bcsa.Demo) { return [ordered]@{ state = 'ready'; host = 'Demo'; psVersion = $PSVersionTable.PSVersion.ToString(); module = 'demo'; error = $null } }
    if (-not $ServiceDir) { return $null }
    $worker = $script:BcsaWorkers[$ServiceDir.ToLowerInvariant()]
    if (-not $worker) { return [ordered]@{ state = 'notStarted'; host = $null; psVersion = $null; module = $null; error = $null } }
    $state = 'loading'
    if (-not $worker.Alive) { $state = 'stopped' }
    elseif ($worker.Ready -and $worker.Ready.moduleLoaded) { $state = 'ready' }
    elseif ($worker.Ready) { $state = 'failed' }
    $psVersion = $null
    $module = $null
    if ($worker.Ready) { $psVersion = $worker.Ready.psVersion; $module = $worker.Ready.module }
    return [ordered]@{ state = $state; host = $worker.HostKind; psVersion = $psVersion; module = $module; error = $worker.LastError }
}

function Stop-BcsaAllWorkers {
    foreach ($worker in @($script:BcsaWorkers.Values)) { Stop-BcsaWorker -Worker $worker }
    $script:BcsaWorkers.Clear()
}
