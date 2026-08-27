$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$taskFile = Join-Path $PSScriptRoot "tasks.json"

if (-not (Test-Path $taskFile)) {
    throw "Task manifest not found: $taskFile"
}

$data = Get-Content $taskFile -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "=== TaskFlow Orchestrator ==="
Write-Host ""


function Get-TaskById {
    param(
        [string]$Id,
        $Tasks
    )

    return $Tasks | Where-Object { $_.id -eq $Id }
}

function Test-DependenciesSatisfied {
    param(
        $Task,
        $Tasks
    )

    foreach ($dependencyId in $Task.dependencies) {
        $dependency = Get-TaskById -Id $dependencyId -Tasks $Tasks

        if (-not $dependency) {
            throw "Missing dependency '$dependencyId' for task '$($Task.id)'"
        }

        if ($dependency.state -ne "DONE") {
            return $false
        }
    }

    return $true
}

function Ensure-Worktree {
    param(
        $Task,
        [string]$Root
    )

    if (-not $Task.branch -or -not $Task.worktree) {
        return
    }

    $worktreePath = Join-Path $Root $Task.worktree

    if (Test-Path $worktreePath) {
        Write-Host "$($Task.id): worktree already exists."
        return
    }

    Write-Host "$($Task.id): creating worktree..."

    git worktree add $worktreePath -b $Task.branch

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create worktree for $($Task.id)"
    }
}

$changed = $false

foreach ($task in $data.tasks) {

    if ($task.state -eq "BLOCKED") {

        if (Test-DependenciesSatisfied -Task $task -Tasks $data.tasks) {

            Write-Host "$($task.id): BLOCKED -> READY"

            $task.state = "READY"
            $changed = $true
        }
    }
}

if ($changed) {

    $json = $data | ConvertTo-Json -Depth 10

    Set-Content `
        -Path $taskFile `
        -Value $json `
        -Encoding UTF8

    Write-Host ""
    Write-Host "Task manifest updated."
}