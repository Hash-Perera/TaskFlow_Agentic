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
        [string]$ProjectParent
    )

    if (-not $Task.branch -or -not $Task.worktreeName) {
        Write-Host "$($Task.id): no branch/worktree configured."
        return
    }

    $worktreePath = Join-Path $ProjectParent $Task.worktreeName

    if (Test-Path $worktreePath) {
        Write-Host "$($Task.id): worktree already exists at $worktreePath"
        return
    }

    Write-Host "$($Task.id): creating worktree..."

    git worktree add $worktreePath -b $Task.branch

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create worktree for $($Task.id)"
    }

    Write-Host "$($Task.id): worktree created at $worktreePath"
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