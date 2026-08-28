param(
    [ValidateSet("run", "status", "retry", "cancel", "approve")]
    [string]$Command = "run",

    [string]$TaskId
)

$ErrorActionPreference = "Stop"

# ============================================================
# TaskFlow Orchestrator - Stage 24
# Scheduler hardening, recovery, bounded parallelism,
# timeout handling, cancellation, retry and human approval.
# ============================================================

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

# TaskFlow repository root
$root = Split-Path -Parent $PSScriptRoot

# Parent folder containing TaskFlow worktrees
$projectParent = Split-Path -Parent $root

$taskFile     = Join-Path $PSScriptRoot "tasks.json"
$workerFile   = Join-Path $PSScriptRoot "workers.json"
$settingsFile = Join-Path $PSScriptRoot "settings.json"
$stateFile    = Join-Path $PSScriptRoot "state.json"
$logDirectory = Join-Path $PSScriptRoot "logs"
$generatedDirectory = Join-Path $PSScriptRoot "generated"

# Internal orchestrator result codes:
# -1   = failed to launch worker
# -408 = worker timeout
# -499 = manually cancelled
# -999 = exit code unavailable

# ------------------------------------------------------------
# Validate required manifests
# ------------------------------------------------------------

if (-not (Test-Path $taskFile)) {
    throw "Task manifest not found: $taskFile"
}

if (-not (Test-Path $workerFile)) {
    throw "Worker registry not found: $workerFile"
}

# ------------------------------------------------------------
# Create default settings.json if it does not exist
# ------------------------------------------------------------

if (-not (Test-Path $settingsFile)) {
    $defaultSettings = [PSCustomObject]@{
        maxParallelWorkers   = 2
        workerTimeoutMinutes = 20
        maxAttempts           = 3
        pollIntervalSeconds   = 2
    }

    $defaultSettings |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $settingsFile -Encoding UTF8

    Write-Host "Created default scheduler settings: $settingsFile"
}

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------

$data = Get-Content $taskFile -Raw | ConvertFrom-Json
$workerData = Get-Content $workerFile -Raw | ConvertFrom-Json
$settings = Get-Content $settingsFile -Raw | ConvertFrom-Json

if (-not $data.tasks) {
    throw "No tasks found in task manifest."
}

if (-not $workerData.workers) {
    throw "No workers found in worker registry."
}

if ([int]$settings.maxParallelWorkers -lt 1) {
    throw "settings.maxParallelWorkers must be at least 1."
}

if ([double]$settings.workerTimeoutMinutes -le 0) {
    throw "settings.workerTimeoutMinutes must be greater than 0."
}

if ([int]$settings.maxAttempts -lt 1) {
    throw "settings.maxAttempts must be at least 1."
}

if ([int]$settings.pollIntervalSeconds -lt 1) {
    throw "settings.pollIntervalSeconds must be at least 1."
}

if (-not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory | Out-Null
}

if (-not (Test-Path $generatedDirectory)) {
    New-Item -ItemType Directory -Path $generatedDirectory | Out-Null
}

# ------------------------------------------------------------
# Load runtime state
# ------------------------------------------------------------

if (Test-Path $stateFile) {
    $runtimeState = Get-Content $stateFile -Raw | ConvertFrom-Json
}
else {
    $runtimeState = [PSCustomObject]@{
        tasks = [PSCustomObject]@{}
    }
}

if (-not $runtimeState.tasks) {
    $runtimeState | Add-Member `
        -MemberType NoteProperty `
        -Name tasks `
        -Value ([PSCustomObject]@{}) `
        -Force
}

# ------------------------------------------------------------
# Generic helpers
# ------------------------------------------------------------

function Get-TaskById {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        $Tasks
    )

    return $Tasks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Get-WorkerById {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        $Workers
    )

    return $Workers | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Save-RuntimeState {
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $tempPath = "$Path.tmp"

    $State |
        ConvertTo-Json -Depth 30 |
        Set-Content -Path $tempPath -Encoding UTF8

    Move-Item -Path $tempPath -Destination $Path -Force
}

function Get-TaskRuntimeState {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    $property = $RuntimeState.tasks.PSObject.Properties[$TaskId]

    if (-not $property) {
        throw "Runtime state not found for task '$TaskId'."
    }

    return $property.Value
}

function Add-MissingProperty {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name,

        $Value
    )

    if (-not ($Object.PSObject.Properties.Name -contains $Name)) {
        $Object | Add-Member `
            -MemberType NoteProperty `
            -Name $Name `
            -Value $Value
    }
}

# ------------------------------------------------------------
# Runtime-state initialization and Stage 23 migration
# ------------------------------------------------------------

function Initialize-RuntimeState {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    foreach ($task in $Tasks) {
        $taskId = [string]$task.id
        $existing = $RuntimeState.tasks.PSObject.Properties[$taskId]

        if (-not $existing) {
            # Preserve current Stage 23 values on first migration when present.
            $initialState = if ($task.PSObject.Properties.Name -contains "state") {
                [string]$task.state
            }
            elseif ($task.dependencies -and $task.dependencies.Count -gt 0) {
                "BLOCKED"
            }
            else {
                "READY"
            }

            $approved = $false
            if ($task.PSObject.Properties.Name -contains "approved") {
                $approved = [bool]$task.approved
            }

            $attempts = 0
            $lastExitCode = $null
            $startedAt = $null
            $completedAt = $null
            $processId = $null

            if ($task.PSObject.Properties.Name -contains "execution" -and $task.execution) {
                if ($null -ne $task.execution.attempts)     { $attempts = [int]$task.execution.attempts }
                if ($null -ne $task.execution.lastExitCode) { $lastExitCode = $task.execution.lastExitCode }
                if ($task.execution.startedAt)               { $startedAt = $task.execution.startedAt }
                if ($task.execution.completedAt)             { $completedAt = $task.execution.completedAt }
                if ($task.execution.processId)               { $processId = $task.execution.processId }
            }

            $taskState = [PSCustomObject]@{
                state             = $initialState
                approved          = $approved
                attempts          = $attempts
                lastExitCode      = $lastExitCode
                startedAt         = $startedAt
                completedAt       = $completedAt
                processId         = $processId
                processStartTime  = $null
                lastFailureReason = $null
                stdoutPath        = $null
                stderrPath        = $null
                exitCodePath      = $null
                worktreePath      = $null
            }

            $RuntimeState.tasks | Add-Member `
                -MemberType NoteProperty `
                -Name $taskId `
                -Value $taskState
        }
        else {
            $taskState = $existing.Value

            Add-MissingProperty -Object $taskState -Name state -Value "BACKLOG"
            Add-MissingProperty -Object $taskState -Name approved -Value $false
            Add-MissingProperty -Object $taskState -Name attempts -Value 0
            Add-MissingProperty -Object $taskState -Name lastExitCode -Value $null
            Add-MissingProperty -Object $taskState -Name startedAt -Value $null
            Add-MissingProperty -Object $taskState -Name completedAt -Value $null
            Add-MissingProperty -Object $taskState -Name processId -Value $null
            Add-MissingProperty -Object $taskState -Name processStartTime -Value $null
            Add-MissingProperty -Object $taskState -Name lastFailureReason -Value $null
            Add-MissingProperty -Object $taskState -Name stdoutPath -Value $null
            Add-MissingProperty -Object $taskState -Name stderrPath -Value $null
            Add-MissingProperty -Object $taskState -Name exitCodePath -Value $null
            Add-MissingProperty -Object $taskState -Name worktreePath -Value $null
        }
    }
}

# ------------------------------------------------------------
# Dependency handling
# ------------------------------------------------------------

function Test-DependenciesSatisfied {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    if (-not $Task.dependencies -or $Task.dependencies.Count -eq 0) {
        return $true
    }

    foreach ($dependencyId in $Task.dependencies) {
        $dependency = Get-TaskById -Id $dependencyId -Tasks $Tasks

        if (-not $dependency) {
            throw "Missing dependency '$dependencyId' for task '$($Task.id)'"
        }

        $dependencyState = Get-TaskRuntimeState `
            -TaskId $dependencyId `
            -RuntimeState $RuntimeState

        if ($dependencyState.state -ne "DONE") {
            return $false
        }
    }

    return $true
}

function Resolve-DependencyStates {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    $changed = $false

    foreach ($task in $Tasks) {
        $taskState = Get-TaskRuntimeState `
            -TaskId $task.id `
            -RuntimeState $RuntimeState

        if ($taskState.state -eq "BLOCKED") {
            if (Test-DependenciesSatisfied `
                -Task $task `
                -Tasks $Tasks `
                -RuntimeState $RuntimeState) {

                Write-Host "$($task.id): BLOCKED -> READY"
                $taskState.state = "READY"
                $changed = $true
            }
        }
    }

    return $changed
}

# ------------------------------------------------------------
# Process / recovery helpers
# ------------------------------------------------------------

function Get-ProcessByIdSafe {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    return Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
}

function Test-ProcessIdentityMatches {
    param(
        [Parameter(Mandatory)]
        $Process,

        $ExpectedStartTime
    )

    if (-not $ExpectedStartTime) {
        return $true
    }

    try {
        $expected = [DateTime]::Parse($ExpectedStartTime).ToUniversalTime()
        $actual = $Process.StartTime.ToUniversalTime()
        return [Math]::Abs(($actual - $expected).TotalSeconds) -lt 2
    }
    catch {
        return $false
    }
}

function Get-WorkerExitCodeFromFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        $raw = (Get-Content $Path -Raw).Trim()

        if ($raw -match '^-?\d+$') {
            return [int]$raw
        }
    }
    catch {
        return $null
    }

    return $null
}

function Stop-WorkerProcessTree {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    # taskkill /T terminates the wrapper PowerShell process and its children.
    $null = & cmd.exe /d /s /c "taskkill /PID $ProcessId /T /F >nul 2>&1"
}

function Complete-RecoveredTask {
    param(
        [Parameter(Mandatory)]
        $TaskState,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [string]$TaskId
    )

    $TaskState.lastExitCode = $ExitCode
    $TaskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")
    $TaskState.processId = $null
    $TaskState.processStartTime = $null

    if ($ExitCode -eq 0) {
        $TaskState.state = "REVIEW"
        $TaskState.lastFailureReason = $null
        Write-Host "${TaskId}: recovered completed worker -> REVIEW"
    }
    else {
        $TaskState.state = "FAILED"
        $TaskState.lastFailureReason = "Recovered worker exited with code $ExitCode."
        Write-Host "${TaskId}: recovered completed worker -> FAILED (exit code $ExitCode)"
    }
}

function Repair-StaleRunningTasks {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState,

        [Parameter(Mandatory)]
        $Settings
    )

    $changed = $false

    foreach ($task in $Tasks) {
        $taskState = Get-TaskRuntimeState `
            -TaskId $task.id `
            -RuntimeState $RuntimeState

        if ($taskState.state -ne "RUNNING") {
            continue
        }

        $exitCodePath = $taskState.exitCodePath
        if (-not $exitCodePath) {
            $exitCodePath = Join-Path $logDirectory "$($task.id)-exitcode.txt"
            $taskState.exitCodePath = $exitCodePath
        }

        # If there is no PID, recover from exit artifact when possible.
        if (-not $taskState.processId) {
            $recoveredExitCode = Get-WorkerExitCodeFromFile -Path $exitCodePath

            if ($null -ne $recoveredExitCode) {
                Complete-RecoveredTask `
                    -TaskState $taskState `
                    -ExitCode $recoveredExitCode `
                    -TaskId $task.id
            }
            else {
                $taskState.state = "FAILED"
                $taskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")
                $taskState.lastFailureReason = "Stale RUNNING state with no process ID and no valid exit-code artifact."
                Write-Host "$($task.id): RUNNING without PID -> FAILED"
            }

            $changed = $true
            continue
        }

        $process = Get-ProcessByIdSafe -ProcessId ([int]$taskState.processId)
        $identityMatches = $false

        if ($process) {
            $identityMatches = Test-ProcessIdentityMatches `
                -Process $process `
                -ExpectedStartTime $taskState.processStartTime
        }

        # Process still exists and appears to be the expected worker.
        if ($process -and $identityMatches) {
            # Also enforce timeout during reconciliation.
            if ($taskState.startedAt) {
                try {
                    $started = [DateTime]::Parse($taskState.startedAt).ToUniversalTime()
                    $elapsed = (Get-Date).ToUniversalTime() - $started

                    if ($elapsed.TotalMinutes -ge [double]$Settings.workerTimeoutMinutes) {
                        Write-Host "$($task.id): recovered RUNNING worker exceeded timeout; cancelling PID $($taskState.processId)."

                        Stop-WorkerProcessTree -ProcessId ([int]$taskState.processId)

                        $taskState.state = "FAILED"
                        $taskState.lastExitCode = -408
                        $taskState.lastFailureReason = "Worker exceeded timeout of $($Settings.workerTimeoutMinutes) minutes."
                        $taskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")
                        $taskState.processId = $null
                        $taskState.processStartTime = $null
                        $changed = $true
                    }
                }
                catch {
                    Write-Host "$($task.id): could not evaluate recovered worker timeout; leaving task RUNNING."
                }
            }

            continue
        }

        # Missing process or PID was reused. Prefer the durable exit-code artifact.
        $recoveredExitCode = Get-WorkerExitCodeFromFile -Path $exitCodePath

        if ($null -ne $recoveredExitCode) {
            Complete-RecoveredTask `
                -TaskState $taskState `
                -ExitCode $recoveredExitCode `
                -TaskId $task.id
        }
        else {
            $taskState.state = "FAILED"
            $taskState.processId = $null
            $taskState.processStartTime = $null
            $taskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")

            if ($process -and -not $identityMatches) {
                $taskState.lastFailureReason = "Stored PID was reused by another process and no exit-code artifact exists."
            }
            else {
                $taskState.lastFailureReason = "Worker process disappeared and no valid exit-code artifact exists."
            }

            Write-Host "$($task.id): stale RUNNING worker -> FAILED"
        }

        $changed = $true
    }

    return $changed
}

function Test-TaskCanRetry {
    param(
        [Parameter(Mandatory)]
        $TaskState,

        [Parameter(Mandatory)]
        [int]$MaxAttempts
    )

    return (
        $TaskState.state -eq "FAILED" -and
        [int]$TaskState.attempts -lt $MaxAttempts
    )
}

# ------------------------------------------------------------
# Git worktree helper
# ------------------------------------------------------------

function Ensure-Worktree {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string]$ProjectParent,

        [Parameter(Mandatory)]
        [string]$Root
    )

    if (-not $Task.branch -or -not $Task.worktreeName) {
        throw "$($Task.id): branch/worktree configuration missing."
    }

    [string]$worktreePath = Join-Path $ProjectParent $Task.worktreeName

    $registeredWorktree = $null
    $currentWorktree = $null
    $worktreeList = & git -C $Root worktree list --porcelain

    foreach ($line in $worktreeList) {
        if ($line -match '^worktree (.+)$') {
            $currentWorktree = $Matches[1]
            continue
        }

        if ($line -eq "branch refs/heads/$($Task.branch)") {
            $registeredWorktree = $currentWorktree
            break
        }
    }

    if ($registeredWorktree) {
        Write-Host "$($Task.id): existing Git worktree found."
        Write-Host "$($Task.id): reusing $registeredWorktree"
        return [string]$registeredWorktree
    }

    if (Test-Path $worktreePath) {
        Write-Host "$($Task.id): worktree directory already exists."
        Write-Host "$($Task.id): reusing $worktreePath"
        return [string]$worktreePath
    }

    Push-Location $Root

    try {
        & git show-ref --verify --quiet "refs/heads/$($Task.branch)"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "$($Task.id): existing branch found."
            $gitCommand = 'git worktree add "{0}" "{1}" 2>&1' -f $worktreePath, $Task.branch
        }
        else {
            Write-Host "$($Task.id): creating branch and worktree."
            $gitCommand = 'git worktree add "{0}" -b "{1}" 2>&1' -f $worktreePath, $Task.branch
        }

        $gitOutput = & cmd.exe /d /s /c $gitCommand
        $gitExitCode = $LASTEXITCODE

        foreach ($line in $gitOutput) {
            Write-Host $line
        }

        if ($gitExitCode -ne 0) {
            throw "Failed to create worktree for $($Task.id). Git exit code: $gitExitCode"
        }
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $worktreePath)) {
        throw "$($Task.id): worktree path was not created: $worktreePath"
    }

    return [string]$worktreePath
}

# ------------------------------------------------------------
# Prompt generation
# ------------------------------------------------------------

function New-WorkerPrompt {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        $Worker
    )

    $verificationText = $Task.verification -join "`n- "
    $allowedScope = $Worker.allowedScope -join "`n- "
    $forbiddenScope = $Worker.forbiddenScope -join "`n- "

    return @"
You are $($Worker.role) for TaskFlow.

You are running in an isolated Git worktree.

Read first:

- AGENTS.md
- docs/requirements.md
- docs/acceptance-criteria.md
- docs/api-contract.md
- docs/architecture.md
- $($Task.taskFile)

Assigned task:

$($Task.id) — $($Task.name)

Allowed modification scope:

- $allowedScope

Do not modify:

- $forbiddenScope

Before editing:

1. Inspect the current implementation.
2. Confirm the relevant architecture and contract requirements.
3. Identify the files you expect to modify.
4. Report blockers or contract conflicts.
5. Do not silently expand scope.

Then implement the assigned task.

Do not modify shared contracts or architecture.

Verification:

- $verificationText

If verification fails because of your changes:
- investigate the cause
- fix only issues caused by or directly required by the assigned task
- rerun verification

Do not weaken correct tests merely to make them pass.

Completion report:

- files changed
- implementation summary
- packages changed
- verification commands executed
- verification results
- assumptions
- blockers
- unresolved issues
- confirmation that scope was respected

Do not merge into main.
Do not delete branches or worktrees.
"@
}

function Save-WorkerPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $promptPath = Join-Path $generatedDirectory "$TaskId-prompt.txt"

    Set-Content -Path $promptPath -Value $Prompt -Encoding UTF8
    return [string]$promptPath
}

# ------------------------------------------------------------
# Scheduling helpers
# ------------------------------------------------------------

function Get-ReadyTasks {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState,

        [Parameter(Mandatory)]
        [int]$MaxAttempts
    )

    return @(
        $Tasks | Where-Object {
            $taskState = Get-TaskRuntimeState `
                -TaskId $_.id `
                -RuntimeState $RuntimeState

            $taskState.state -eq "READY" -and
            [int]$taskState.attempts -lt $MaxAttempts
        }
    )
}

function Get-RunningTasks {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    return @(
        $Tasks | Where-Object {
            $taskState = Get-TaskRuntimeState `
                -TaskId $_.id `
                -RuntimeState $RuntimeState

            $taskState.state -eq "RUNNING"
        }
    )
}

function Test-TaskScopeConflict {
    param(
        [Parameter(Mandatory)]
        $TaskA,

        [Parameter(Mandatory)]
        $TaskB
    )

    foreach ($scopeA in $TaskA.scope) {
        foreach ($scopeB in $TaskB.scope) {
            $normalizedA = ($scopeA -replace '/\*\*$', '' -replace '\\\*\*$', '').TrimEnd('/', '\\')
            $normalizedB = ($scopeB -replace '/\*\*$', '' -replace '\\\*\*$', '').TrimEnd('/', '\\')

            if (
                $normalizedA.StartsWith($normalizedB, [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedB.StartsWith($normalizedA, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                return $true
            }
        }
    }

    return $false
}

function Get-ParallelExecutionWave {
    param(
        [Parameter(Mandatory)]
        $ReadyTasks,

        [Parameter(Mandatory)]
        [int]$MaxParallelWorkers,

        [Parameter(Mandatory)]
        $AlreadyRunningTasks
    )

    $wave = @()

    foreach ($candidate in $ReadyTasks) {
        if ($wave.Count -ge $MaxParallelWorkers) {
            break
        }

        $hasConflict = $false

        foreach ($running in $AlreadyRunningTasks) {
            if (Test-TaskScopeConflict -TaskA $candidate -TaskB $running) {
                Write-Host "$($candidate.id): deferred because scope overlaps with RUNNING task $($running.id)."
                $hasConflict = $true
                break
            }
        }

        if ($hasConflict) {
            continue
        }

        foreach ($selected in $wave) {
            if (Test-TaskScopeConflict -TaskA $candidate -TaskB $selected) {
                Write-Host "$($candidate.id): deferred because scope overlaps with wave task $($selected.id)."
                $hasConflict = $true
                break
            }
        }

        if (-not $hasConflict) {
            $wave += $candidate
        }
    }

    return $wave
}

# ------------------------------------------------------------
# Async Codex worker
# ------------------------------------------------------------

function Start-CodexWorkerProcess {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [Parameter(Mandatory)]
        [string]$PromptPath
    )

    $stdoutPath = Join-Path $logDirectory "$($Task.id)-stdout.txt"
    $stderrPath = Join-Path $logDirectory "$($Task.id)-stderr.txt"
    $promptTempPath = Join-Path $logDirectory "$($Task.id)-stdin.txt"
    $exitCodePath = Join-Path $logDirectory "$($Task.id)-exitcode.txt"

    Remove-Item $stdoutPath -ErrorAction SilentlyContinue
    Remove-Item $stderrPath -ErrorAction SilentlyContinue
    Remove-Item $exitCodePath -ErrorAction SilentlyContinue

    $prompt = Get-Content $PromptPath -Raw
    Set-Content -Path $promptTempPath -Value $prompt -Encoding UTF8

    $escapedPromptPath = $promptTempPath.Replace("'", "''")
    $escapedExitCodePath = $exitCodePath.Replace("'", "''")

    $childCommand = @"
`$ErrorActionPreference = "Continue"

Get-Content '$escapedPromptPath' -Raw |
    & cmd.exe /d /s /c "codex exec - 2>&1"

`$codexExitCode = `$LASTEXITCODE

Set-Content `
    -Path '$escapedExitCodePath' `
    -Value `$codexExitCode `
    -Encoding ASCII

exit `$codexExitCode
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childCommand)
    )

    Write-Host ""
    Write-Host "$($Task.id): starting Codex process..."

    $process = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile", "-EncodedCommand", $encodedCommand `
        -WorkingDirectory $WorktreePath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    # Access StartTime while the process is known to exist.
    $processStartTime = $process.StartTime.ToUniversalTime().ToString("o")

    return @{
        TaskId           = $Task.id
        Process          = $process
        ProcessStartTime = $processStartTime
        StdOutPath       = $stdoutPath
        StdErrPath       = $stderrPath
        ExitCodePath     = $exitCodePath
        PromptPath       = $PromptPath
        Worktree         = $WorktreePath
    }
}

# ------------------------------------------------------------
# Status display
# ------------------------------------------------------------

function Show-OrchestratorStatus {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState,

        [Parameter(Mandatory)]
        $Settings
    )

    Write-Host ""
    Write-Host "=== TaskFlow Runtime Status ==="
    Write-Host ""
    Write-Host "Max parallel workers : $($Settings.maxParallelWorkers)"
    Write-Host "Worker timeout       : $($Settings.workerTimeoutMinutes) minute(s)"
    Write-Host "Max attempts         : $($Settings.maxAttempts)"
    Write-Host "Poll interval        : $($Settings.pollIntervalSeconds) second(s)"
    Write-Host ""

    foreach ($task in $Tasks) {
        $taskState = Get-TaskRuntimeState `
            -TaskId $task.id `
            -RuntimeState $RuntimeState

        Write-Host "$($task.id) - $($task.name)"
        Write-Host "  Owner       : $($task.owner)"
        Write-Host "  State       : $($taskState.state)"
        Write-Host "  Approved    : $($taskState.approved)"
        Write-Host "  Attempts    : $($taskState.attempts)"
        Write-Host "  Exit Code   : $($taskState.lastExitCode)"
        Write-Host "  PID         : $($taskState.processId)"

        if ($taskState.lastFailureReason) {
            Write-Host "  Last Failure: $($taskState.lastFailureReason)"
        }

        Write-Host ""
    }
}

# ============================================================
# STARTUP INITIALIZATION / RECOVERY
# ============================================================

Write-Host ""
Write-Host "=== TaskFlow Orchestrator - Stage 24 ==="
Write-Host ""

Initialize-RuntimeState `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState

$recoveryChanged = Repair-StaleRunningTasks `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState `
    -Settings $settings

$dependencyChanged = Resolve-DependencyStates `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState

if ($recoveryChanged -or $dependencyChanged -or -not (Test-Path $stateFile)) {
    Save-RuntimeState -State $runtimeState -Path $stateFile
}
else {
    # Persist any newly initialized/migrated properties as well.
    Save-RuntimeState -State $runtimeState -Path $stateFile
}

# ============================================================
# COMMANDS
# ============================================================

if ($Command -eq "status") {
    Show-OrchestratorStatus `
        -Tasks $data.tasks `
        -RuntimeState $runtimeState `
        -Settings $settings
    return
}

if ($Command -in @("retry", "cancel", "approve") -and -not $TaskId) {
    throw "TaskId is required for command '$Command'."
}

if ($TaskId) {
    $requestedTask = Get-TaskById -Id $TaskId -Tasks $data.tasks

    if (-not $requestedTask) {
        throw "Task '$TaskId' does not exist in tasks.json."
    }

    $requestedTaskState = Get-TaskRuntimeState `
        -TaskId $TaskId `
        -RuntimeState $runtimeState
}

if ($Command -eq "retry") {
    if ($requestedTaskState.state -ne "FAILED") {
        throw "$TaskId is not FAILED. Current state: $($requestedTaskState.state)"
    }

    if (-not (Test-TaskCanRetry `
        -TaskState $requestedTaskState `
        -MaxAttempts ([int]$settings.maxAttempts))) {
        throw "$TaskId reached maximum retry attempts ($($settings.maxAttempts))."
    }

    $requestedTaskState.state = "READY"
    $requestedTaskState.approved = $false
    $requestedTaskState.lastExitCode = $null
    $requestedTaskState.completedAt = $null
    $requestedTaskState.processId = $null
    $requestedTaskState.processStartTime = $null
    $requestedTaskState.lastFailureReason = $null

    Save-RuntimeState -State $runtimeState -Path $stateFile

    Write-Host "${TaskId}: FAILED -> READY"
    Write-Host "Retry is now eligible for the next run command."
    return
}

if ($Command -eq "cancel") {
    if ($requestedTaskState.state -ne "RUNNING") {
        throw "$TaskId is not RUNNING. Current state: $($requestedTaskState.state)"
    }

    if ($requestedTaskState.processId) {
        $process = Get-ProcessByIdSafe -ProcessId ([int]$requestedTaskState.processId)

        if ($process -and (Test-ProcessIdentityMatches `
            -Process $process `
            -ExpectedStartTime $requestedTaskState.processStartTime)) {

            Stop-WorkerProcessTree -ProcessId ([int]$requestedTaskState.processId)
        }
    }

    $requestedTaskState.state = "FAILED"
    $requestedTaskState.lastExitCode = -499
    $requestedTaskState.lastFailureReason = "Worker cancelled by human."
    $requestedTaskState.processId = $null
    $requestedTaskState.processStartTime = $null
    $requestedTaskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")

    Save-RuntimeState -State $runtimeState -Path $stateFile

    Write-Host "$TaskId cancelled."
    return
}

if ($Command -eq "approve") {
    if ($requestedTaskState.state -ne "REVIEW") {
        throw "$TaskId is not in REVIEW. Current state: $($requestedTaskState.state)"
    }

    $requestedTaskState.state = "DONE"
    $requestedTaskState.approved = $true
    $requestedTaskState.lastFailureReason = $null

    # Approval may unlock dependent tasks immediately.
    $null = Resolve-DependencyStates `
        -Tasks $data.tasks `
        -RuntimeState $runtimeState

    Save-RuntimeState -State $runtimeState -Path $stateFile

    Write-Host "${TaskId}: REVIEW -> DONE"
    Write-Host "Human approval recorded."
    return
}

# ============================================================
# RUN COMMAND - BOUNDED PARALLEL EXECUTION WAVE
# ============================================================

$runningTasks = @(
    Get-RunningTasks `
        -Tasks $data.tasks `
        -RuntimeState $runtimeState
)

$activeRunningCount = $runningTasks.Count
$availableSlots = [int]$settings.maxParallelWorkers - $activeRunningCount

if ($availableSlots -le 0) {
    Write-Host ""
    Write-Host "All worker slots are currently occupied."
    Write-Host "Active RUNNING tasks: $activeRunningCount"
    Write-Host "Max parallel workers : $($settings.maxParallelWorkers)"
    Write-Host ""
    Write-Host "Use -Command status to inspect active work."
    return
}

$readyTasks = Get-ReadyTasks `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState `
    -MaxAttempts ([int]$settings.maxAttempts)

if ($readyTasks.Count -eq 0) {
    Write-Host ""
    Write-Host "No READY tasks available."

    if ($runningTasks.Count -gt 0) {
        Write-Host "$($runningTasks.Count) task(s) are already RUNNING and will not be relaunched."
    }

    Write-Host ""
    return
}

$wave = Get-ParallelExecutionWave `
    -ReadyTasks $readyTasks `
    -MaxParallelWorkers $availableSlots `
    -AlreadyRunningTasks $runningTasks

if ($wave.Count -eq 0) {
    Write-Host ""
    Write-Host "READY tasks exist, but none can be safely scheduled in the current wave."
    Write-Host "This may be caused by scope overlap with RUNNING workers."
    Write-Host ""
    return
}

Write-Host ""
Write-Host "=== Parallel Execution Wave ==="
Write-Host ""
Write-Host "Available slots: $availableSlots"
Write-Host ""

foreach ($task in $wave) {
    Write-Host "  $($task.id) - $($task.name)"
}

Write-Host ""
$response = Read-Host "Launch these $($wave.Count) Codex worker(s) in parallel? (y/n)"

if ($response -notin @("y", "Y")) {
    Write-Host "Parallel execution cancelled."
    return
}

# ------------------------------------------------------------
# Prepare all workers before starting any worker
# ------------------------------------------------------------

$preparedWorkers = @()

Write-Host ""
Write-Host "=== Preparing Workers ==="
Write-Host ""

foreach ($task in $wave) {
    $worker = Get-WorkerById -Id $task.owner -Workers $workerData.workers

    if (-not $worker) {
        throw "Worker '$($task.owner)' not found for task '$($task.id)'"
    }

    $worktreePath = Ensure-Worktree `
        -Task $task `
        -ProjectParent $projectParent `
        -Root $root

    $prompt = New-WorkerPrompt -Task $task -Worker $worker
    $promptPath = Save-WorkerPrompt -TaskId $task.id -Prompt $prompt

    Write-Host "Preparing $($task.id)..."
    Write-Host "  Worker   : $($worker.id)"
    Write-Host "  Worktree : $worktreePath"
    Write-Host "  Prompt   : $promptPath"
    Write-Host ""

    $preparedWorkers += @{
        Task         = $task
        Worker       = $worker
        WorktreePath = [string]$worktreePath
        PromptPath   = [string]$promptPath
    }
}

# ------------------------------------------------------------
# Mark the wave RUNNING before launch
# ------------------------------------------------------------

foreach ($item in $preparedWorkers) {
    $task = $item.Task
    $taskState = Get-TaskRuntimeState `
        -TaskId $task.id `
        -RuntimeState $runtimeState

    Write-Host "$($task.id): READY -> RUNNING"

    $taskState.state = "RUNNING"
    $taskState.approved = $false
    $taskState.attempts = [int]$taskState.attempts + 1
    $taskState.startedAt = (Get-Date).ToUniversalTime().ToString("o")
    $taskState.completedAt = $null
    $taskState.lastExitCode = $null
    $taskState.processId = $null
    $taskState.processStartTime = $null
    $taskState.lastFailureReason = $null
    $taskState.worktreePath = $item.WorktreePath
}

Save-RuntimeState -State $runtimeState -Path $stateFile

# ------------------------------------------------------------
# Launch workers
# ------------------------------------------------------------

$runningWorkers = @()

foreach ($item in $preparedWorkers) {
    $task = $item.Task
    $taskState = Get-TaskRuntimeState `
        -TaskId $task.id `
        -RuntimeState $runtimeState

    try {
        $runtime = Start-CodexWorkerProcess `
            -Task $task `
            -WorktreePath $item.WorktreePath `
            -PromptPath $item.PromptPath

        $taskState.processId = [int]$runtime.Process.Id
        $taskState.processStartTime = $runtime.ProcessStartTime
        $taskState.stdoutPath = $runtime.StdOutPath
        $taskState.stderrPath = $runtime.StdErrPath
        $taskState.exitCodePath = $runtime.ExitCodePath
        $taskState.worktreePath = $runtime.Worktree

        $runningWorkers += @{
            Task    = $task
            Runtime = $runtime
        }

        Write-Host "$($task.id): Codex PID $($runtime.Process.Id)"
    }
    catch {
        $taskState.state = "FAILED"
        $taskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        $taskState.lastExitCode = -1
        $taskState.processId = $null
        $taskState.processStartTime = $null
        $taskState.lastFailureReason = "Failed to launch Codex worker: $($_.Exception.Message)"

        Write-Host "$($task.id): failed to launch Codex."
        Write-Host $_.Exception.Message
    }

    # Persist each launch result independently.
    Save-RuntimeState -State $runtimeState -Path $stateFile
}

if ($runningWorkers.Count -eq 0) {
    Write-Host ""
    Write-Host "No Codex workers were launched successfully."
    return
}

# ------------------------------------------------------------
# Monitor workers and enforce timeout
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Monitoring Worker Wave ==="
Write-Host ""

while ($runningWorkers.Count -gt 0) {
    foreach ($item in @($runningWorkers)) {
        $task = $item.Task
        $runtime = $item.Runtime
        $process = $runtime.Process

        $taskState = Get-TaskRuntimeState `
            -TaskId $task.id `
            -RuntimeState $runtimeState

        if ($process.HasExited) {
            $process.WaitForExit()
            $process.Refresh()

            $exitCode = Get-WorkerExitCodeFromFile -Path $runtime.ExitCodePath

            if ($null -eq $exitCode) {
                try {
                    $exitCode = [int]$process.ExitCode
                }
                catch {
                    $exitCode = -999
                }
            }

            $taskState.lastExitCode = $exitCode
            $taskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")
            $taskState.processId = $null
            $taskState.processStartTime = $null

            if ($exitCode -eq 0) {
                $taskState.state = "REVIEW"
                $taskState.lastFailureReason = $null
                Write-Host "$($task.id): RUNNING -> REVIEW"
            }
            else {
                $taskState.state = "FAILED"
                $taskState.lastFailureReason = "Codex worker exited with code $exitCode."
                Write-Host "$($task.id): RUNNING -> FAILED (exit code $exitCode)"
            }

            Write-Host "  stdout  : $($runtime.StdOutPath)"
            Write-Host "  stderr  : $($runtime.StdErrPath)"
            Write-Host "  exitcode: $($runtime.ExitCodePath)"
            Write-Host "  worktree: $($runtime.Worktree)"
            Write-Host ""

            Save-RuntimeState -State $runtimeState -Path $stateFile

            $runningWorkers = @(
                $runningWorkers |
                    Where-Object { $_.Task.id -ne $task.id }
            )

            continue
        }

        # Timeout check while worker is still running.
        if ($taskState.startedAt) {
            $startedAt = [DateTime]::Parse($taskState.startedAt).ToUniversalTime()
            $elapsed = (Get-Date).ToUniversalTime() - $startedAt

            if ($elapsed.TotalMinutes -ge [double]$settings.workerTimeoutMinutes) {
                Write-Host "$($task.id): TIMEOUT after $([Math]::Round($elapsed.TotalMinutes, 1)) minute(s)."

                Stop-WorkerProcessTree -ProcessId ([int]$process.Id)

                $taskState.state = "FAILED"
                $taskState.lastExitCode = -408
                $taskState.lastFailureReason = "Worker exceeded timeout of $($settings.workerTimeoutMinutes) minutes."
                $taskState.completedAt = (Get-Date).ToUniversalTime().ToString("o")
                $taskState.processId = $null
                $taskState.processStartTime = $null

                Save-RuntimeState -State $runtimeState -Path $stateFile

                $runningWorkers = @(
                    $runningWorkers |
                        Where-Object { $_.Task.id -ne $task.id }
                )
            }
        }
    }

    if ($runningWorkers.Count -gt 0) {
        Start-Sleep -Seconds ([int]$settings.pollIntervalSeconds)
    }
}

# ------------------------------------------------------------
# Resolve dependencies after the wave
# REVIEW does not satisfy dependencies; only DONE does.
# ------------------------------------------------------------

$null = Resolve-DependencyStates `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState

Save-RuntimeState -State $runtimeState -Path $stateFile

# ------------------------------------------------------------
# Wave summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================"
Write-Host "=== Parallel Execution Wave Finished ==="
Write-Host "============================================"
Write-Host ""

foreach ($task in $wave) {
    $taskState = Get-TaskRuntimeState `
        -TaskId $task.id `
        -RuntimeState $runtimeState

    Write-Host "$($task.id) - $($task.name)"
    Write-Host "  State       : $($taskState.state)"
    Write-Host "  Attempts    : $($taskState.attempts)"
    Write-Host "  Exit Code   : $($taskState.lastExitCode)"
    Write-Host "  Started     : $($taskState.startedAt)"
    Write-Host "  Completed   : $($taskState.completedAt)"

    if ($taskState.lastFailureReason) {
        Write-Host "  Failure     : $($taskState.lastFailureReason)"
    }

    if ($taskState.state -eq "FAILED") {
        if (Test-TaskCanRetry `
            -TaskState $taskState `
            -MaxAttempts ([int]$settings.maxAttempts)) {

            Write-Host "  Retry       : available"
        }
        else {
            Write-Host "  Retry       : limit reached"
        }
    }

    Write-Host ""
}

# ------------------------------------------------------------
# Human review instructions
# ------------------------------------------------------------

$reviewTasks = @(
    $wave | Where-Object {
        (Get-TaskRuntimeState -TaskId $_.id -RuntimeState $runtimeState).state -eq "REVIEW"
    }
)

if ($reviewTasks.Count -gt 0) {
    Write-Host "=== Human Review Required ==="
    Write-Host ""

    foreach ($task in $reviewTasks) {
        $taskState = Get-TaskRuntimeState `
            -TaskId $task.id `
            -RuntimeState $runtimeState

        $worktreePath = $taskState.worktreePath
        if (-not $worktreePath) {
            $worktreePath = Join-Path $projectParent $task.worktreeName
        }

        Write-Host "$($task.id) - $($task.name)"
        Write-Host ""
        Write-Host "  cd `"$worktreePath`""
        Write-Host "  git status"
        Write-Host "  git diff --stat"
        Write-Host "  git diff"
        Write-Host ""
        Write-Host "After human review, approve with:"
        Write-Host "  .\orchestration\orchestrator.ps1 -Command approve -TaskId $($task.id)"
        Write-Host ""
    }
}

# ------------------------------------------------------------
# Failed task instructions
# ------------------------------------------------------------

$failedTasks = @(
    $wave | Where-Object {
        (Get-TaskRuntimeState -TaskId $_.id -RuntimeState $runtimeState).state -eq "FAILED"
    }
)

if ($failedTasks.Count -gt 0) {
    Write-Host "=== Failed Workers ==="
    Write-Host ""

    foreach ($task in $failedTasks) {
        $taskState = Get-TaskRuntimeState `
            -TaskId $task.id `
            -RuntimeState $runtimeState

        Write-Host "$($task.id) - $($task.name)"
        Write-Host "  Reason: $($taskState.lastFailureReason)"
        Write-Host "  stdout: $($taskState.stdoutPath)"
        Write-Host "  stderr: $($taskState.stderrPath)"

        if (Test-TaskCanRetry `
            -TaskState $taskState `
            -MaxAttempts ([int]$settings.maxAttempts)) {

            Write-Host "  Retry command:"
            Write-Host "    .\orchestration\orchestrator.ps1 -Command retry -TaskId $($task.id)"
        }
        else {
            Write-Host "  Retry limit reached."
        }

        Write-Host ""
    }
}
