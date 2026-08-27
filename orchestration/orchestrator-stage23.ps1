# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

$settingsFile = Join-Path $PSScriptRoot "settings.json"

if (-not (Test-Path $settingsFile)) {
    throw "Scheduler settings not found: $settingsFile"
}

$settings = Get-Content $settingsFile -Raw | ConvertFrom-Json


# ------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------
$stateFile = Join-Path $PSScriptRoot "state.json"

if (Test-Path $stateFile) {
    $runtimeState = Get-Content $stateFile -Raw | ConvertFrom-Json
}
else {
    $runtimeState = [PSCustomObject]@{
        tasks = [PSCustomObject]@{}
    }
}


$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

# TaskFlow repository root
$root = Split-Path -Parent $PSScriptRoot

# Parent folder containing TaskFlow
# Example:
# D:\Projects\AI_AGENTIC_DEV_PROJECT
$projectParent = Split-Path -Parent $root

$taskFile = Join-Path $PSScriptRoot "tasks.json"
$workerFile = Join-Path $PSScriptRoot "workers.json"

if (-not (Test-Path $taskFile)) {
    throw "Task manifest not found: $taskFile"
}

if (-not (Test-Path $workerFile)) {
    throw "Worker registry not found: $workerFile"
}

# ------------------------------------------------------------
# Load manifests
# ------------------------------------------------------------

$data = Get-Content $taskFile -Raw | ConvertFrom-Json
$workerData = Get-Content $workerFile -Raw | ConvertFrom-Json

if (-not $data.tasks) {
    throw "No tasks found in task manifest."
}

if (-not $workerData.workers) {
    throw "No workers found in worker registry."
}

Write-Host ""
Write-Host "=== TaskFlow Orchestrator ==="
Write-Host ""

# ------------------------------------------------------------
# Helper: Find Task
# ------------------------------------------------------------

function Get-TaskById {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        $Tasks
    )

    return $Tasks | Where-Object { $_.id -eq $Id }
}

# ------------------------------------------------------------
# Helper: Find Worker
# ------------------------------------------------------------

function Get-WorkerById {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        $Workers
    )

    return $Workers | Where-Object { $_.id -eq $Id }
}

# ------------------------------------------------------------
# Helper: Save Task Manifest
# ------------------------------------------------------------

function Save-TaskManifest {
    param(
        [Parameter(Mandatory)]
        $Data,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $json = $Data | ConvertTo-Json -Depth 20

    Set-Content `
        -Path $Path `
        -Value $json `
        -Encoding UTF8
}

# ------------------------------------------------------------
# Helper: Ensure execution metadata exists
# ------------------------------------------------------------

function Initialize-TaskExecutionMetadata {
    param(
        [Parameter(Mandatory)]
        $Task
    )

    if (-not $Task.execution) {

        $execution = [PSCustomObject]@{
            attempts      = 0
            lastExitCode  = $null
            startedAt     = $null
            completedAt   = $null
            processId     = $null
        }

        $Task | Add-Member `
            -MemberType NoteProperty `
            -Name execution `
            -Value $execution
    }

    if ($null -eq $Task.execution.attempts) {
        $Task.execution.attempts = 0
    }

    if (-not ($Task.execution.PSObject.Properties.Name -contains "lastExitCode")) {
        $Task.execution | Add-Member -MemberType NoteProperty -Name lastExitCode -Value $null
    }

    if (-not ($Task.execution.PSObject.Properties.Name -contains "startedAt")) {
        $Task.execution | Add-Member -MemberType NoteProperty -Name startedAt -Value $null
    }

    if (-not ($Task.execution.PSObject.Properties.Name -contains "completedAt")) {
        $Task.execution | Add-Member -MemberType NoteProperty -Name completedAt -Value $null
    }

    if (-not ($Task.execution.PSObject.Properties.Name -contains "processId")) {
        $Task.execution | Add-Member -MemberType NoteProperty -Name processId -Value $null
    }
}

# ------------------------------------------------------------
# Helper: Check Dependencies
# ------------------------------------------------------------

function Test-DependenciesSatisfied {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        $Tasks
    )

    if (-not $Task.dependencies -or $Task.dependencies.Count -eq 0) {
        return $true
    }

    foreach ($dependencyId in $Task.dependencies) {

        $dependency = Get-TaskById `
            -Id $dependencyId `
            -Tasks $Tasks

        if (-not $dependency) {
            throw "Missing dependency '$dependencyId' for task '$($Task.id)'"
        }

        if ($dependency.state -ne "DONE") {
            return $false
        }
    }

    return $true
}

# ------------------------------------------------------------
# Helper: Ensure Git Worktree Exists
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

    # --------------------------------------------------------
    # Check whether this branch is already attached
    # to an existing Git worktree.
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # If the expected directory already exists but Git does
    # not have it registered, do not blindly recreate it.
    # --------------------------------------------------------

    if (Test-Path $worktreePath) {

        Write-Host "$($Task.id): worktree directory already exists."
        Write-Host "$($Task.id): reusing $worktreePath"

        return [string]$worktreePath
    }

    # --------------------------------------------------------
    # Worktree does not exist yet, so create it.
    # --------------------------------------------------------

    Push-Location $Root

    try {

        & git show-ref --verify --quiet "refs/heads/$($Task.branch)"

        if ($LASTEXITCODE -eq 0) {

            Write-Host "$($Task.id): existing branch found."
            Write-Host "$($Task.id): creating worktree from existing branch."

            $gitCommand = 'git worktree add "{0}" "{1}" 2>&1' -f `
                $worktreePath, `
                $Task.branch
        }
        else {

            Write-Host "$($Task.id): creating branch and worktree."

            $gitCommand = 'git worktree add "{0}" -b "{1}" 2>&1' -f `
                $worktreePath, `
                $Task.branch
        }

        # cmd.exe merges stderr into stdout before PowerShell sees it.
        # This avoids NativeCommandError when
        # $ErrorActionPreference = "Stop".
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

    # --------------------------------------------------------
    # Final validation
    # --------------------------------------------------------

    if (-not (Test-Path $worktreePath)) {
        throw "$($Task.id): worktree path was not created: $worktreePath"
    }

    return [string]$worktreePath
}

# ------------------------------------------------------------
# Update Dependency States
# ------------------------------------------------------------

$changed = $false

foreach ($task in $data.tasks) {

    Initialize-TaskExecutionMetadata -Task $task

    if ($task.state -eq "BLOCKED") {

        $dependenciesSatisfied = Test-DependenciesSatisfied `
            -Task $task `
            -Tasks $data.tasks

        if ($dependenciesSatisfied) {

            Write-Host "$($task.id): BLOCKED -> READY"

            $task.state = "READY"
            $changed = $true
        }
    }
}

if ($changed) {
    Save-TaskManifest -Data $data -Path $taskFile
    Write-Host ""
    Write-Host "Task manifest updated."
}

# ------------------------------------------------------------
# Display Current Orchestration State
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Current Task States ==="
Write-Host ""

foreach ($task in $data.tasks) {

    Write-Host "$($task.id) - $($task.name)"
    Write-Host "  Owner : $($task.owner)"
    Write-Host "  State : $($task.state)"

    if ($task.dependencies -and $task.dependencies.Count -gt 0) {
        Write-Host "  Depends On : $($task.dependencies -join ', ')"
    }
    else {
        Write-Host "  Depends On : none"
    }

    Write-Host ""
}

# ------------------------------------------------------------
# Prompt Generator
# ------------------------------------------------------------

function New-WorkerPrompt {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        $Worker,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $verificationText = $Task.verification -join "`n- "
    $allowedScope = $Worker.allowedScope -join "`n- "
    $forbiddenScope = $Worker.forbiddenScope -join "`n- "

    $prompt = @"
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

    return $prompt
}

# ------------------------------------------------------------
# Save generated prompt to file
# ------------------------------------------------------------

function Save-WorkerPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $generatedDirectory = Join-Path $PSScriptRoot "generated"

    if (-not (Test-Path $generatedDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $generatedDirectory | Out-Null
    }

    $promptPath = Join-Path `
        $generatedDirectory `
        "$TaskId-prompt.txt"

    Set-Content `
        -Path $promptPath `
        -Value $Prompt `
        -Encoding UTF8

    return [string]$promptPath
}

# ------------------------------------------------------------
# Find all READY tasks
# ------------------------------------------------------------

function Get-ReadyTasks {
    param(
        [Parameter(Mandatory)]
        $Tasks
    )

    return @(
        $Tasks |
            Where-Object { $_.state -eq "READY" }
    )
}

# ------------------------------------------------------------
# Stage 22 synchronous launcher (retained for reference)
# Stage 23 uses Start-CodexWorkerProcess.
# ------------------------------------------------------------

function Invoke-CodexWorker {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [Parameter(Mandatory)]
        [string]$PromptPath
    )

    $logDirectory = Join-Path $PSScriptRoot "logs"

    if (-not (Test-Path $logDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $logDirectory | Out-Null
    }

    $outputPath = Join-Path `
        $logDirectory `
        "$($Task.id)-output.txt"

    Write-Host ""
    Write-Host "=== Launching Codex Worker ==="
    Write-Host "Task      : $($Task.id)"
    Write-Host "Workspace : $WorktreePath"
    Write-Host "Log       : $outputPath"
    Write-Host ""

    Push-Location $WorktreePath

    try {
        $prompt = Get-Content $PromptPath -Raw

        $prompt |
            & cmd.exe /d /s /c "codex exec - 2>&1" |
            Tee-Object -FilePath $outputPath

        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return @{
        ExitCode   = $exitCode
        OutputPath = $outputPath
    }
}

# ------------------------------------------------------------
# Check whether two tasks have overlapping scopes
# ------------------------------------------------------------

function Test-TaskScopeConflict {
    param(
        [Parameter(Mandatory)]
        $TaskA,

        [Parameter(Mandatory)]
        $TaskB
    )

    foreach ($scopeA in $TaskA.scope) {
        foreach ($scopeB in $TaskB.scope) {

            $normalizedA = $scopeA `
                -replace '/\*\*$', '' `
                -replace '\\\*\*$', ''

            $normalizedB = $scopeB `
                -replace '/\*\*$', '' `
                -replace '\\\*\*$', ''

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

# ------------------------------------------------------------
# Select a safe parallel execution wave
# ------------------------------------------------------------

function Get-ParallelExecutionWave {
    param(
        [Parameter(Mandatory)]
        $ReadyTasks,

        [Parameter(Mandatory)]
        [int]$MaxParallelWorkers
    )

    $wave = @()

    foreach ($candidate in $ReadyTasks) {

        if ($wave.Count -ge $MaxParallelWorkers) {
            break
        }

        $hasConflict = $false

        foreach ($selected in $wave) {

            if (
                Test-TaskScopeConflict `
                    -TaskA $candidate `
                    -TaskB $selected
            ) {
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

$wave = Get-ParallelExecutionWave `
    -ReadyTasks $readyTasks `
    -MaxParallelWorkers $settings.maxParallelWorkers

# ------------------------------------------------------------
# Start Codex Worker asynchronously
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

    $logDirectory = Join-Path $PSScriptRoot "logs"

    if (-not (Test-Path $logDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $logDirectory | Out-Null
    }

    $stdoutPath = Join-Path `
        $logDirectory `
        "$($Task.id)-stdout.txt"

    $stderrPath = Join-Path `
        $logDirectory `
        "$($Task.id)-stderr.txt"

    $promptTempPath = Join-Path `
        $logDirectory `
        "$($Task.id)-stdin.txt"

    $exitCodePath = Join-Path `
        $logDirectory `
        "$($Task.id)-exitcode.txt"

    # Remove old runtime artifacts
    Remove-Item $stdoutPath -ErrorAction SilentlyContinue
    Remove-Item $stderrPath -ErrorAction SilentlyContinue
    Remove-Item $exitCodePath -ErrorAction SilentlyContinue

    $prompt = Get-Content $PromptPath -Raw

    Set-Content `
        -Path $promptTempPath `
        -Value $prompt `
        -Encoding UTF8

    $escapedPromptPath = $promptTempPath.Replace("'", "''")
    $escapedExitCodePath = $exitCodePath.Replace("'", "''")

    $command = @"
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
        [Text.Encoding]::Unicode.GetBytes($command)
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

    return @{
        TaskId       = $Task.id
        Process      = $process
        StdOutPath   = $stdoutPath
        StdErrPath   = $stderrPath
        ExitCodePath = $exitCodePath
        PromptPath   = $PromptPath
        Worktree     = $WorktreePath
    }
}

function Save-RuntimeState {
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $json = $State | ConvertTo-Json -Depth 20

    Set-Content `
        -Path $Path `
        -Value $json `
        -Encoding UTF8
}

function Initialize-RuntimeState {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    foreach ($task in $Tasks) {

        $taskId = $task.id

        if (-not $RuntimeState.tasks.PSObject.Properties[$taskId]) {

            $taskState = [PSCustomObject]@{
                state             = "BACKLOG"
                approved          = $false
                attempts          = 0
                lastExitCode      = $null
                startedAt         = $null
                completedAt       = $null
                processId         = $null
                lastFailureReason = $null
            }

            $RuntimeState.tasks |
                Add-Member `
                    -MemberType NoteProperty `
                    -Name $taskId `
                    -Value $taskState
        }
    }
}

Initialize-RuntimeState `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState

Save-RuntimeState `
    -State $runtimeState `
    -Path $stateFile



function Get-TaskRuntimeState {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    return $RuntimeState.tasks.PSObject.Properties[$TaskId].Value
}

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

        $dependency =
            $Tasks |
            Where-Object { $_.id -eq $dependencyId }

        if (-not $dependency) {
            throw "Missing dependency '$dependencyId' for task '$($Task.id)'"
        }

        $dependencyState =
            Get-TaskRuntimeState `
                -TaskId $dependencyId `
                -RuntimeState $RuntimeState

        if ($dependencyState.state -ne "DONE") {
            return $false
        }
    }

    return $true
}


function Test-ProcessExists {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    $process = Get-Process `
        -Id $ProcessId `
        -ErrorAction SilentlyContinue

    return $null -ne $process
}

function Repair-StaleRunningTasks {
    param(
        [Parameter(Mandatory)]
        $Tasks,

        [Parameter(Mandatory)]
        $RuntimeState
    )

    foreach ($task in $Tasks) {

        $taskState =
            Get-TaskRuntimeState `
                -TaskId $task.id `
                -RuntimeState $RuntimeState

        if ($taskState.state -ne "RUNNING") {
            continue
        }

        if (-not $taskState.processId) {

            Write-Host "$($task.id): RUNNING without PID -> FAILED"

            $taskState.state = "FAILED"
            $taskState.lastFailureReason =
                "Stale RUNNING state with no process ID."

            $taskState.completedAt =
                (Get-Date).ToUniversalTime().ToString("o")

            continue
        }

        $exists =
            Test-ProcessExists `
                -ProcessId ([int]$taskState.processId)

        if (-not $exists) {

            Write-Host "$($task.id): stale RUNNING process detected."

            $taskState.state = "FAILED"
            $taskState.lastFailureReason =
                "Worker process disappeared before reconciliation."

            $taskState.processId = $null

            $taskState.completedAt =
                (Get-Date).ToUniversalTime().ToString("o")
        }
    }
}

Repair-StaleRunningTasks `
    -Tasks $data.tasks `
    -RuntimeState $runtimeState

Save-RuntimeState `
    -State $runtimeState `
    -Path $stateFile


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






# ============================================================
# MAIN EXECUTION - PARALLEL WAVE
# ============================================================

Write-Host ""
Write-Host "=== Looking For READY Tasks ==="
Write-Host ""

# ------------------------------------------------------------
# Find READY tasks
# ------------------------------------------------------------

$readyTasks = Get-ReadyTasks `
    -Tasks $data.tasks

if ($readyTasks.Count -eq 0) {
    Write-Host "No READY tasks available."
    Write-Host ""
    return
}

Write-Host "READY tasks:"
Write-Host ""

foreach ($task in $readyTasks) {
    Write-Host "  $($task.id) - $($task.name)"
}

Write-Host ""

# ------------------------------------------------------------
# Build safe parallel execution wave
# ------------------------------------------------------------

$wave = Get-ParallelExecutionWave `
    -ReadyTasks $readyTasks

if ($wave.Count -eq 0) {
    Write-Host "No tasks could be scheduled safely."
    Write-Host ""
    return
}

Write-Host ""
Write-Host "=== Parallel Execution Wave ==="
Write-Host ""

foreach ($task in $wave) {
    Write-Host "  $($task.id) - $($task.name)"
}

Write-Host ""

# ------------------------------------------------------------
# Human approval for execution wave
# ------------------------------------------------------------

$response = Read-Host "Launch these $($wave.Count) Codex worker(s) in parallel? (y/n)"

if ($response -notin @("y", "Y")) {
    Write-Host ""
    Write-Host "Parallel execution cancelled."
    Write-Host ""
    return
}

# ------------------------------------------------------------
# Prepare every worker first
# ------------------------------------------------------------

$preparedWorkers = @()

Write-Host ""
Write-Host "=== Preparing Workers ==="
Write-Host ""

foreach ($task in $wave) {

    Write-Host "Preparing $($task.id)..."

    Initialize-TaskExecutionMetadata `
        -Task $task

    $worker = Get-WorkerById `
        -Id $task.owner `
        -Workers $workerData.workers

    if (-not $worker) {
        throw "Worker '$($task.owner)' not found for task '$($task.id)'"
    }

    $worktreePath = Ensure-Worktree `
        -Task $task `
        -ProjectParent $projectParent `
        -Root $root

    $prompt = New-WorkerPrompt `
        -Task $task `
        -Worker $worker `
        -Root $root

    $promptPath = Save-WorkerPrompt `
        -TaskId $task.id `
        -Prompt $prompt

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
# Mark entire wave RUNNING
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Starting Execution Wave ==="
Write-Host ""

foreach ($item in $preparedWorkers) {

    $task = $item.Task

    Write-Host "$($task.id): READY -> RUNNING"

    $task.state = "RUNNING"
    $task.execution.attempts = [int]$task.execution.attempts + 1
    $task.execution.startedAt = (Get-Date).ToUniversalTime().ToString("o")
    $task.execution.completedAt = $null
    $task.execution.lastExitCode = $null
    $task.execution.processId = $null
}

Save-TaskManifest `
    -Data $data `
    -Path $taskFile

# ------------------------------------------------------------
# Launch all workers
# ------------------------------------------------------------

$runningWorkers = @()

foreach ($item in $preparedWorkers) {

    $task = $item.Task

    try {

        $runtime = Start-CodexWorkerProcess `
            -Task $task `
            -WorktreePath $item.WorktreePath `
            -PromptPath $item.PromptPath

        $task.execution.processId = $runtime.Process.Id

        $runningWorkers += @{
            Task    = $task
            Runtime = $runtime
        }

        Write-Host "$($task.id): Codex PID $($runtime.Process.Id)"
    }
    catch {

        Write-Host ""
        Write-Host "$($task.id): failed to launch Codex."
        Write-Host $_.Exception.Message

        $task.state = "FAILED"
        $task.execution.completedAt = (Get-Date).ToUniversalTime().ToString("o")
        $task.execution.lastExitCode = -1
        $task.execution.processId = $null
    }
}

Save-TaskManifest `
    -Data $data `
    -Path $taskFile

# ------------------------------------------------------------
# If nothing launched successfully
# ------------------------------------------------------------

if ($runningWorkers.Count -eq 0) {
    Write-Host ""
    Write-Host "No Codex workers were launched successfully."
    Write-Host ""
    return
}

# ------------------------------------------------------------
# Monitor workers
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Monitoring Worker Wave ==="
Write-Host ""

while ($runningWorkers.Count -gt 0) {

    foreach ($item in @($runningWorkers)) {

        $task = $item.Task
        $runtime = $item.Runtime
        $process = $runtime.Process

        if ($process.HasExited) {

            # Ensure Windows has completely finalized the process
            $process.WaitForExit()
            $process.Refresh()

            $exitCode = $null

            # Preferred source: exit-code file created by child worker
            if (Test-Path $runtime.ExitCodePath) {

                $rawExitCode = Get-Content `
                    $runtime.ExitCodePath `
                    -Raw

                $rawExitCode = $rawExitCode.Trim()

                if ($rawExitCode -match '^-?\d+$') {
                    $exitCode = [int]$rawExitCode
                }
            }

            # Fallback to Process.ExitCode
            if ($null -eq $exitCode) {

                try {
                    $exitCode = [int]$process.ExitCode
                }
                catch {
                    $exitCode = -999
                }
            }

            $task.execution.lastExitCode = $exitCode
            $task.execution.completedAt =
                (Get-Date).ToUniversalTime().ToString("o")

            $task.execution.processId = $null

            if ($exitCode -eq 0) {

                $task.state = "REVIEW"

                Write-Host ""
                Write-Host "$($task.id): RUNNING -> REVIEW"
            }
            else {

                $task.state = "FAILED"

                Write-Host ""
                Write-Host "$($task.id): RUNNING -> FAILED (exit code $exitCode)"
            }

            Write-Host "  stdout  : $($runtime.StdOutPath)"
            Write-Host "  stderr  : $($runtime.StdErrPath)"
            Write-Host "  exitcode: $($runtime.ExitCodePath)"
            Write-Host "  worktree: $($runtime.Worktree)"
            Write-Host ""

            Save-TaskManifest `
                -Data $data `
                -Path $taskFile

            $runningWorkers = @(
                $runningWorkers |
                    Where-Object {
                        $_.Task.id -ne $task.id
                    }
            )
        }
    }

    if ($runningWorkers.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
}

# ------------------------------------------------------------
# Resolve newly unblocked tasks
# REVIEW does NOT satisfy dependencies; only DONE does.
# ------------------------------------------------------------

$dependencyChanges = $false

foreach ($task in $data.tasks) {

    if ($task.state -eq "BLOCKED") {

        $dependenciesSatisfied = Test-DependenciesSatisfied `
            -Task $task `
            -Tasks $data.tasks

        if ($dependenciesSatisfied) {

            Write-Host "$($task.id): BLOCKED -> READY"

            $task.state = "READY"
            $dependencyChanges = $true
        }
    }
}

if ($dependencyChanges) {
    Save-TaskManifest `
        -Data $data `
        -Path $taskFile
}

# ------------------------------------------------------------
# Execution wave summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================"
Write-Host "=== Parallel Execution Wave Finished ==="
Write-Host "============================================"
Write-Host ""

foreach ($task in $wave) {

    Write-Host "$($task.id) - $($task.name)"
    Write-Host "  State     : $($task.state)"
    Write-Host "  Attempts  : $($task.execution.attempts)"
    Write-Host "  Exit Code : $($task.execution.lastExitCode)"
    Write-Host "  Started   : $($task.execution.startedAt)"
    Write-Host "  Completed : $($task.execution.completedAt)"
    Write-Host ""
}

# ------------------------------------------------------------
# Human review instructions
# ------------------------------------------------------------

$reviewTasks = @(
    $wave |
        Where-Object { $_.state -eq "REVIEW" }
)

if ($reviewTasks.Count -gt 0) {

    Write-Host "=== Human Review Required ==="
    Write-Host ""

    foreach ($task in $reviewTasks) {

        $worktreePath = Join-Path `
            $projectParent `
            $task.worktreeName

        Write-Host "$($task.id) - $($task.name)"
        Write-Host ""
        Write-Host "  cd `"$worktreePath`""
        Write-Host "  git status"
        Write-Host "  git diff --stat"
        Write-Host "  git diff"
        Write-Host ""
    }

    Write-Host "Do not mark a REVIEW task as DONE until the changes are human-approved."
    Write-Host ""
}

# ------------------------------------------------------------
# Failed task instructions
# ------------------------------------------------------------

$failedTasks = @(
    $wave |
        Where-Object { $_.state -eq "FAILED" }
)

if ($failedTasks.Count -gt 0) {

    Write-Host "=== Failed Workers ==="
    Write-Host ""

    foreach ($task in $failedTasks) {

        $stdoutPath = Join-Path `
            (Join-Path $PSScriptRoot "logs") `
            "$($task.id)-stdout.txt"

        $stderrPath = Join-Path `
            (Join-Path $PSScriptRoot "logs") `
            "$($task.id)-stderr.txt"

        Write-Host "$($task.id) - $($task.name)"
        Write-Host "  stdout: $stdoutPath"
        Write-Host "  stderr: $stderrPath"
        Write-Host ""
    }

    Write-Host "FAILED tasks require human inspection. They are not retried automatically."
    Write-Host ""
}
