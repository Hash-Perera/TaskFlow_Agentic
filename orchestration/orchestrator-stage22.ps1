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

if (-not (Test-Path $taskFile)) {
    throw "Task manifest not found: $taskFile"
}

# ------------------------------------------------------------
# Load task manifest
# ------------------------------------------------------------

$data = Get-Content $taskFile -Raw | ConvertFrom-Json

if (-not $data.tasks) {
    throw "No tasks found in task manifest."
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
# Helper: Check Dependencies
# ------------------------------------------------------------

function Test-DependenciesSatisfied {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        $Tasks
    )

    # Task has no dependencies
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

    if (Test-Path $worktreePath) {
        Write-Host "$($Task.id): worktree already exists."
        return $worktreePath
    }

    Push-Location $Root

    try {

        & git show-ref --verify --quiet "refs/heads/$($Task.branch)"

        if ($LASTEXITCODE -eq 0) {

            Write-Host "$($Task.id): existing branch found."
            Write-Host "$($Task.id): creating worktree from existing branch."

            $gitOutput = & git worktree add `
                $worktreePath `
                $Task.branch 2>&1
        }
        else {

            Write-Host "$($Task.id): creating branch and worktree."

            $gitOutput = & git worktree add `
                $worktreePath `
                -b $Task.branch 2>&1
        }

        $gitExitCode = $LASTEXITCODE

        # Display Git output without returning it from this function
        foreach ($line in $gitOutput) {
            Write-Host $line
        }

        if ($gitExitCode -ne 0) {
            throw "Failed to create worktree for $($Task.id)"
        }
    }
    finally {
        Pop-Location
    }

    return [string]$worktreePath
}

# ------------------------------------------------------------
# Update Dependency States
# ------------------------------------------------------------

$changed = $false

foreach ($task in $data.tasks) {

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

# ------------------------------------------------------------
# Persist Changed States
# ------------------------------------------------------------

if ($changed) {

    $json = $data | ConvertTo-Json -Depth 10

    Set-Content `
        -Path $taskFile `
        -Value $json `
        -Encoding UTF8

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
# Add worker lookup
# ------------------------------------------------------------

$workerFile = Join-Path $PSScriptRoot "workers.json"

if (-not (Test-Path $workerFile)) {
    throw "Worker registry not found: $workerFile"
}

$workerData = Get-Content $workerFile -Raw | ConvertFrom-Json

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

    return $promptPath
}


# ------------------------------------------------------------
# Manifest persistence helper
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
# Find a READY task
# ------------------------------------------------------------
function Get-NextReadyTask {
    param(
        [Parameter(Mandatory)]
        $Tasks
    )

    return $Tasks |
        Where-Object { $_.state -eq "READY" } |
        Select-Object -First 1
}


# ------------------------------------------------------------
# Invoke Codex Worker
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

        # --------------------------------------------------------
        # Run through cmd.exe instead of the npm PowerShell shim.
        #
        # Codex writes normal status information to stderr.
        # Windows PowerShell converts native stderr into
        # NativeCommandError when $ErrorActionPreference = "Stop".
        #
        # cmd.exe performs 2>&1 before PowerShell receives output,
        # allowing stdout/stderr to be safely logged together.
        # --------------------------------------------------------

        $prompt |
            & cmd.exe /d /s /c "codex exec - 2>&1" |
            Tee-Object -FilePath $outputPath

        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return @{
        ExitCode  = $exitCode
        OutputPath = $outputPath
    }
}

# ============================================================
# MAIN EXECUTION
# ============================================================

Write-Host ""
Write-Host "=== Looking For READY Task ==="
Write-Host ""

$nextTask = Get-NextReadyTask -Tasks $data.tasks

if (-not $nextTask) {
    Write-Host "No READY tasks available."
    Write-Host ""
    return
}

Write-Host "Selected Task:"
Write-Host "  ID    : $($nextTask.id)"
Write-Host "  Name  : $($nextTask.name)"
Write-Host "  Owner : $($nextTask.owner)"
Write-Host ""

# ------------------------------------------------------------
# Resolve Assigned Worker
# ------------------------------------------------------------

$worker = Get-WorkerById `
    -Id $nextTask.owner `
    -Workers $workerData.workers

if (-not $worker) {
    throw "Worker '$($nextTask.owner)' not found for task '$($nextTask.id)'"
}

Write-Host "Worker:"
Write-Host "  ID   : $($worker.id)"
Write-Host "  Role : $($worker.role)"
Write-Host ""

# ------------------------------------------------------------
# Ensure Worktree
# ------------------------------------------------------------

$worktreePath = Ensure-Worktree `
    -Task $nextTask `
    -ProjectParent $projectParent `
    -Root $root

Write-Host ""
Write-Host "Worktree:"
Write-Host "  $worktreePath"
Write-Host ""

# ------------------------------------------------------------
# Generate Worker Prompt
# ------------------------------------------------------------

$prompt = New-WorkerPrompt `
    -Task $nextTask `
    -Worker $worker `
    -Root $root

$promptPath = Save-WorkerPrompt `
    -TaskId $nextTask.id `
    -Prompt $prompt

Write-Host "Generated Prompt:"
Write-Host "  $promptPath"
Write-Host ""

# ------------------------------------------------------------
# Human Launch Approval
# ------------------------------------------------------------

$response = Read-Host "Launch this Codex worker? (y/n)"

if ($response -notin @("y", "Y")) {
    Write-Host ""
    Write-Host "Worker launch cancelled."
    return
}

# ------------------------------------------------------------
# READY -> RUNNING
# ------------------------------------------------------------

Write-Host ""
Write-Host "$($nextTask.id): READY -> RUNNING"

$nextTask.state = "RUNNING"

$nextTask.execution.attempts =
    [int]$nextTask.execution.attempts + 1

$nextTask.execution.startedAt =
    (Get-Date).ToUniversalTime().ToString("o")

$nextTask.execution.completedAt = $null
$nextTask.execution.lastExitCode = $null

Save-TaskManifest `
    -Data $data `
    -Path $taskFile

# ------------------------------------------------------------
# Execute Codex
# ------------------------------------------------------------

$result = Invoke-CodexWorker `
    -Task $nextTask `
    -WorktreePath $worktreePath `
    -PromptPath $promptPath

# ------------------------------------------------------------
# Save Execution Result
# ------------------------------------------------------------

$nextTask.execution.lastExitCode =
    $result.ExitCode

$nextTask.execution.completedAt =
    (Get-Date).ToUniversalTime().ToString("o")

if ($result.ExitCode -eq 0) {

    $nextTask.state = "REVIEW"

    Write-Host ""
    Write-Host "$($nextTask.id): RUNNING -> REVIEW"
}
else {

    $nextTask.state = "FAILED"

    Write-Host ""
    Write-Host "$($nextTask.id): RUNNING -> FAILED"
}

Save-TaskManifest `
    -Data $data `
    -Path $taskFile

# ------------------------------------------------------------
# Final Execution Summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Worker Execution Finished ==="
Write-Host ""
Write-Host "Task      : $($nextTask.id)"
Write-Host "State     : $($nextTask.state)"
Write-Host "Exit Code : $($result.ExitCode)"
Write-Host "Log       : $($result.OutputPath)"
Write-Host ""

if ($nextTask.state -eq "REVIEW") {

    Write-Host "Human review is required before this task can become DONE."
    Write-Host ""
    Write-Host "Review the worker worktree:"
    Write-Host ""
    Write-Host "  cd `"$worktreePath`""
    Write-Host "  git status"
    Write-Host "  git diff --stat"
    Write-Host "  git diff"
    Write-Host ""
}