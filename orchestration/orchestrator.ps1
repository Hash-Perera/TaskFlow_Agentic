param(
    [ValidateSet(
        "run","status","retry","cancel","approve","fix","ci-fix","verify",
        "commit","push","create-pr","check-ci","merge-local","abort-merge",
        "verify-integration","rollback","abort-rollback"
    )]
    [string]$Command = "run",
    [string]$TaskId
)

$ErrorActionPreference = "Stop"

# TaskFlow Orchestrator - Stage 33
# Stage 25 history was intentionally skipped.
# Human gates remain at: approve/fix/ci-fix/final GitHub merge/rollback.

$root = Split-Path -Parent $PSScriptRoot
$projectParent = Split-Path -Parent $root
$taskFile = Join-Path $PSScriptRoot "tasks.json"
$workerFile = Join-Path $PSScriptRoot "workers.json"
$settingsFile = Join-Path $PSScriptRoot "settings.json"
$stateFile = Join-Path $PSScriptRoot "state.json"
$logDirectory = Join-Path $PSScriptRoot "logs"
$generatedDirectory = Join-Path $PSScriptRoot "generated"
$verificationDirectory = Join-Path $PSScriptRoot "verification"

foreach ($p in @($taskFile,$workerFile)) { if (-not (Test-Path $p)) { throw "Required file not found: $p" } }
foreach ($d in @($logDirectory,$generatedDirectory,$verificationDirectory)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

function Add-MissingProperty($Object,[string]$Name,$Value) {
    if (-not ($Object.PSObject.Properties.Name -contains $Name)) { $Object | Add-Member NoteProperty $Name $Value }
}
function Save-Json($Value,[string]$Path,[int]$Depth=40) {
    $tmp="$Path.tmp"; $Value | ConvertTo-Json -Depth $Depth | Set-Content $tmp -Encoding UTF8; Move-Item $tmp $Path -Force
}
function Now-Utc { (Get-Date).ToUniversalTime().ToString("o") }
function Normalize-RepoPath([string]$Path) { if ($null -eq $Path) { return $null }; $Path.Replace("\","/").TrimStart([char[]]"./") }
function Get-TaskById([string]$Id,$Tasks) { $Tasks | Where-Object id -eq $Id | Select-Object -First 1 }
function Get-WorkerById([string]$Id,$Workers) { $Workers | Where-Object id -eq $Id | Select-Object -First 1 }
function Save-RuntimeState($State,[string]$Path) { Save-Json $State $Path 50 }
function Get-TaskRuntimeState([string]$TaskId,$RuntimeState) {
    $p=$RuntimeState.tasks.PSObject.Properties[$TaskId]; if(-not $p){throw "Runtime state not found for '$TaskId'."}; $p.Value
}

if (-not (Test-Path $settingsFile)) {
    $s=[PSCustomObject]@{
        maxParallelWorkers=2; workerTimeoutMinutes=20; verificationTimeoutMinutes=10;
        integrationVerificationTimeoutMinutes=20; maxAttempts=3; maxFixAttempts=2;
        maxCiFixAttempts=2; pollIntervalSeconds=2; ciFailureLogLines=120;
        baseBranch="main"; gitRemote="origin"; verifierWorkerId="verification-worker";
        integrationVerificationCommand=".\scripts\verify.ps1";
        allowedVerificationCommandPrefixes=@("npm ","npx ","dotnet ","node ")
    }; Save-Json $s $settingsFile
}
$settings=Get-Content $settingsFile -Raw | ConvertFrom-Json
$defaults=@{
    maxParallelWorkers=2; workerTimeoutMinutes=20; verificationTimeoutMinutes=10;
    integrationVerificationTimeoutMinutes=20; maxAttempts=3; maxFixAttempts=2;
    maxCiFixAttempts=2; pollIntervalSeconds=2; ciFailureLogLines=120;
    baseBranch="main"; gitRemote="origin"; verifierWorkerId="verification-worker";
    integrationVerificationCommand=".\scripts\verify.ps1";
    allowedVerificationCommandPrefixes=@("npm ","npx ","dotnet ","node ")
}
foreach($k in $defaults.Keys){ Add-MissingProperty $settings $k $defaults[$k] }
if([int]$settings.maxParallelWorkers -lt 1){throw "maxParallelWorkers must be >= 1"}
if([double]$settings.workerTimeoutMinutes -le 0){throw "workerTimeoutMinutes must be > 0"}
if([double]$settings.verificationTimeoutMinutes -le 0){throw "verificationTimeoutMinutes must be > 0"}
if([int]$settings.maxAttempts -lt 1){throw "maxAttempts must be >= 1"}
Save-Json $settings $settingsFile

$data=Get-Content $taskFile -Raw | ConvertFrom-Json
$workerData=Get-Content $workerFile -Raw | ConvertFrom-Json
if(-not $data.tasks){throw "No tasks found."}; if(-not $workerData.workers){throw "No workers found."}

if(Test-Path $stateFile){$runtimeState=Get-Content $stateFile -Raw | ConvertFrom-Json}else{$runtimeState=[PSCustomObject]@{tasks=[PSCustomObject]@{}}}
if(-not $runtimeState.tasks){$runtimeState | Add-Member NoteProperty tasks ([PSCustomObject]@{}) -Force}

function Initialize-RuntimeState($Tasks,$RuntimeState){
    foreach($task in $Tasks){
        $id=[string]$task.id; $existing=$RuntimeState.tasks.PSObject.Properties[$id]
        if(-not $existing){
            $initial=if($task.PSObject.Properties.Name -contains "state"){[string]$task.state}elseif($task.dependencies -and @($task.dependencies).Count -gt 0){"BLOCKED"}else{"READY"}
            $st=[PSCustomObject]@{
                state=$initial; approved=$false; approvedAt=$null; attempts=0; fixAttempts=0; ciFixAttempts=0; executionMode=$null;
                lastExitCode=$null; startedAt=$null; completedAt=$null; processId=$null; processStartTime=$null;
                lastFailureReason=$null; lastFixReason=$null; lastCiFailureReason=$null;
                stdoutPath=$null; stderrPath=$null; exitCodePath=$null; worktreePath=$null;
                agentResultPath=$null; verifierResultPath=$null; verificationResultPath=$null;
                commitSha=$null; remoteBranch=$null; pullRequestNumber=$null; pullRequestUrl=$null;
                ciState=$null; ciRunId=$null; lastCiCheckedAt=$null; ciFailureLogPath=$null;
                integrationSha=$null; integratedAt=$null; integrationVerifiedAt=$null; integrationVerificationExitCode=$null;
                rollbackSha=$null; rolledBackAt=$null
            }
            if($task.PSObject.Properties.Name -contains "approved"){$st.approved=[bool]$task.approved}
            if($task.PSObject.Properties.Name -contains "execution" -and $task.execution){
                if($null -ne $task.execution.attempts){$st.attempts=[int]$task.execution.attempts}; if($null -ne $task.execution.lastExitCode){$st.lastExitCode=$task.execution.lastExitCode}
                if($task.execution.startedAt){$st.startedAt=$task.execution.startedAt}; if($task.execution.completedAt){$st.completedAt=$task.execution.completedAt}; if($task.execution.processId){$st.processId=$task.execution.processId}
            }
            $RuntimeState.tasks | Add-Member NoteProperty $id $st
        } else {
            $st=$existing.Value
            $props=@{state="BACKLOG";approved=$false;approvedAt=$null;attempts=0;fixAttempts=0;ciFixAttempts=0;executionMode=$null;lastExitCode=$null;startedAt=$null;completedAt=$null;processId=$null;processStartTime=$null;lastFailureReason=$null;lastFixReason=$null;lastCiFailureReason=$null;stdoutPath=$null;stderrPath=$null;exitCodePath=$null;worktreePath=$null;agentResultPath=$null;verifierResultPath=$null;verificationResultPath=$null;commitSha=$null;remoteBranch=$null;pullRequestNumber=$null;pullRequestUrl=$null;ciState=$null;ciRunId=$null;lastCiCheckedAt=$null;ciFailureLogPath=$null;integrationSha=$null;integratedAt=$null;integrationVerifiedAt=$null;integrationVerificationExitCode=$null;rollbackSha=$null;rolledBackAt=$null}
            foreach($k in $props.Keys){Add-MissingProperty $st $k $props[$k]}
        }
    }
}

function Test-IsDependencyCompleteState([string]$State){$State -in @("DONE","MERGED","INTEGRATION_VERIFIED")}
function Test-DependenciesSatisfied($Task,$Tasks,$RuntimeState){
    foreach($depId in @($Task.dependencies)){ $dep=Get-TaskById $depId $Tasks; if(-not $dep){throw "Missing dependency '$depId' for '$($Task.id)'"}; if(-not (Test-IsDependencyCompleteState (Get-TaskRuntimeState $depId $RuntimeState).state)){return $false} }; return $true
}
function Resolve-DependencyStates($Tasks,$RuntimeState){$changed=$false;foreach($t in $Tasks){$s=Get-TaskRuntimeState $t.id $RuntimeState;if($s.state -eq "BLOCKED" -and (Test-DependenciesSatisfied $t $Tasks $RuntimeState)){Write-Host "$($t.id): BLOCKED -> READY";$s.state="READY";$changed=$true}};$changed}

function Get-ProcessByIdSafe([int]$ProcessId){Get-Process -Id $ProcessId -ErrorAction SilentlyContinue}
function Test-ProcessIdentityMatches($Process,$ExpectedStartTime){if(-not $ExpectedStartTime){return $true};try{$e=[DateTime]::Parse($ExpectedStartTime).ToUniversalTime();$a=$Process.StartTime.ToUniversalTime();[Math]::Abs(($a-$e).TotalSeconds)-lt 2}catch{$false}}
function Get-ExitCodeFile([string]$Path){if(-not(Test-Path $Path)){return $null};try{$v=(Get-Content $Path -Raw).Trim();if($v -match '^-?\d+$'){return [int]$v}}catch{};$null}
function Stop-ProcessTree([int]$ProcessId){$null=& cmd.exe /d /s /c "taskkill /PID $ProcessId /T /F >nul 2>&1"}
function Complete-Recovered($State,[int]$ExitCode,[string]$Id){$State.lastExitCode=$ExitCode;$State.completedAt=Now-Utc;$State.processId=$null;$State.processStartTime=$null;if($ExitCode -eq 0){$State.state="VALIDATION_PENDING";$State.lastFailureReason=$null;Write-Host "$Id: recovered -> VALIDATION_PENDING"}else{$State.state="FAILED";$State.lastFailureReason="Recovered worker exited $ExitCode";Write-Host "$Id: recovered -> FAILED"}}
function Repair-StaleRunningTasks($Tasks,$RuntimeState,$Settings){
    $changed=$false;foreach($t in $Tasks){$s=Get-TaskRuntimeState $t.id $RuntimeState;if($s.state -notin @("RUNNING","FIXING","CI_FIXING")){continue};$ep=$s.exitCodePath;if(-not $ep){$ep=Join-Path $logDirectory "$($t.id)-exitcode.txt";$s.exitCodePath=$ep}
        if(-not $s.processId){$ec=Get-ExitCodeFile $ep;if($null -ne $ec){Complete-Recovered $s $ec $t.id}else{$s.state="FAILED";$s.completedAt=Now-Utc;$s.lastFailureReason="Stale active state without PID/exit artifact."};$changed=$true;continue}
        $p=Get-ProcessByIdSafe ([int]$s.processId);$match=$p -and (Test-ProcessIdentityMatches $p $s.processStartTime)
        if($match){if($s.startedAt){$elapsed=(Get-Date).ToUniversalTime()-([DateTime]::Parse($s.startedAt).ToUniversalTime());if($elapsed.TotalMinutes -ge [double]$Settings.workerTimeoutMinutes){Stop-ProcessTree ([int]$s.processId);$s.state="FAILED";$s.lastExitCode=-408;$s.lastFailureReason="Worker timeout.";$s.completedAt=Now-Utc;$s.processId=$null;$s.processStartTime=$null;$changed=$true}};continue}
        $ec=Get-ExitCodeFile $ep;if($null -ne $ec){Complete-Recovered $s $ec $t.id}else{$s.state="FAILED";$s.processId=$null;$s.processStartTime=$null;$s.completedAt=Now-Utc;$s.lastFailureReason="Worker disappeared and no valid exit artifact exists."};$changed=$true
    };$changed
}

function Ensure-Worktree($Task,[string]$ProjectParent,[string]$Root){
    if(-not $Task.branch -or -not $Task.worktreeName){throw "$($Task.id): branch/worktree config missing."};$path=Join-Path $ProjectParent $Task.worktreeName;$current=$null;$found=$null
    foreach($line in (& git -C $Root worktree list --porcelain)){if($line -match '^worktree (.+)$'){$current=$Matches[1]}elseif($line -eq "branch refs/heads/$($Task.branch)"){$found=$current;break}}
    if($found){return [string]$found};if(Test-Path $path){return [string]$path};Push-Location $Root;try{& git show-ref --verify --quiet "refs/heads/$($Task.branch)";if($LASTEXITCODE -eq 0){& git worktree add $path $Task.branch}else{& git worktree add $path -b $Task.branch};if($LASTEXITCODE -ne 0){throw "git worktree add failed."}}finally{Pop-Location};[string]$path
}
function Get-WorktreeBranch([string]$Path){Push-Location $Path;try{(& git branch --show-current).Trim()}finally{Pop-Location}}
function Get-WorktreeHead([string]$Path){Push-Location $Path;try{(& git rev-parse HEAD).Trim()}finally{Pop-Location}}
function Get-RootHead([string]$Path){Push-Location $Path;try{(& git rev-parse HEAD).Trim()}finally{Pop-Location}}
function Get-ChangedFiles([string]$Path){Push-Location $Path;try{$a=@(& git diff --name-only HEAD);$b=@(& git ls-files --others --exclude-standard);@($a+$b|ForEach-Object{Normalize-RepoPath $_}|Where-Object{$_ -and $_ -notin @(".agent-result.json",".verifier-result.json")}|Sort-Object -Unique)}finally{Pop-Location}}
function Get-WorktreeFingerprint([string]$Path){Push-Location $Path;try{$text=(@(& git diff --binary HEAD)-join "`n");foreach($f in @(& git ls-files --others --exclude-standard|Where-Object{$_ -notin @(".agent-result.json",".verifier-result.json")}|Sort-Object)){if(Test-Path $f -PathType Leaf){$text+="`nUNTRACKED:$f`n$((Get-FileHash $f -Algorithm SHA256).Hash)"}};$bytes=[Text.Encoding]::UTF8.GetBytes($text);$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","")}finally{$sha.Dispose()}}finally{Pop-Location}}
function Test-RootClean([string]$Path){Push-Location $Path;try{@(& git status --porcelain).Count -eq 0}finally{Pop-Location}}
function Test-Remote([string]$Root,[string]$Remote){Push-Location $Root;try{$Remote -in @(& git remote)}finally{Pop-Location}}
function Get-CommitMessage($Task){if($Task.commitMessage){[string]$Task.commitMessage}else{"task($($Task.id)): $($Task.name)"}}
function Get-CiFixCommitMessage($Task){if($Task.ciFixCommitMessage){[string]$Task.ciFixCommitMessage}else{"fix($($Task.id)): address CI failure"}}
function Commit-Worktree($Task,[string]$Path,[string]$Message,[switch]$AllowClean){
    if((Get-WorktreeBranch $Path) -ne $Task.branch){return [PSCustomObject]@{success=$false;reason="Branch mismatch";commit=$null}};Push-Location $Path;try{$dirty=@(& git status --porcelain).Count -gt 0;if(-not $dirty){if($AllowClean){return [PSCustomObject]@{success=$true;reason="Using current HEAD";commit=(& git rev-parse HEAD).Trim()}}else{return [PSCustomObject]@{success=$false;reason="No changes to commit";commit=$null}}}; & git add --all;if($LASTEXITCODE -ne 0){return [PSCustomObject]@{success=$false;reason="git add failed";commit=$null}};$null=& git reset -- .agent-result.json .verifier-result.json 2>$null;& git commit -m $Message;if($LASTEXITCODE -ne 0){return [PSCustomObject]@{success=$false;reason="git commit failed";commit=$null}};[PSCustomObject]@{success=$true;reason=$null;commit=(& git rev-parse HEAD).Trim()}}finally{Pop-Location}
}
function Push-Task($Task,[string]$Path,[string]$Remote,[string]$Expected){if((Get-WorktreeBranch $Path)-ne $Task.branch){return [PSCustomObject]@{success=$false;reason="Branch mismatch"}};if($Expected -and (Get-WorktreeHead $Path)-ne $Expected){return [PSCustomObject]@{success=$false;reason="Branch HEAD changed after approval"}};Push-Location $Path;try{& git push --set-upstream $Remote $Task.branch;$ec=$LASTEXITCODE}finally{Pop-Location};$reason=$(if($ec -eq 0){$null}else{"git push failed"});[PSCustomObject]@{success=($ec -eq 0);reason=$reason}}

# ---------- Stage 26 structured result ----------
function Get-AgentResult([string]$Path){if(-not(Test-Path $Path)){return $null};try{Get-Content $Path -Raw|ConvertFrom-Json}catch{$null}}
function Test-AgentResult($Result,$Task){$e=@();if(-not $Result){return [PSCustomObject]@{Valid=$false;Errors=@("Missing/invalid .agent-result.json")}};if($Result.taskId-ne$Task.id){$e+="taskId mismatch"};if($Result.outcome-notin@("SUCCESS","BLOCKED","FAILED")){$e+="invalid outcome"};if([string]::IsNullOrWhiteSpace([string]$Result.summary)){$e+="summary required"};foreach($p in @("filesChanged","verification","scopeRespected","blockers","unresolvedIssues")){if(-not($Result.PSObject.Properties.Name-contains$p)){$e+="$p required"}};[PSCustomObject]@{Valid=($e.Count-eq 0);Errors=$e}}
function Test-AgentVerification($Result){foreach($v in @($Result.verification)){if($v.passed-ne$true){return $false}};$true}
function Test-FileInScope([string]$File,[string]$Scope){(Normalize-RepoPath $File) -like ((Normalize-RepoPath $Scope).Replace("**","*"))}
function Test-Scope($Files,$Task){$bad=@();foreach($f in @($Files)){$ok=$false;foreach($s in @($Task.scope)){if(Test-FileInScope $f $s){$ok=$true;break}};if(-not$ok){$bad+=$f}};[PSCustomObject]@{Valid=($bad.Count-eq 0);Violations=$bad}}
function Test-ClaimedFiles($Result,$Actual,[switch]$AllowAdditionalActual){$c=@(@($Result.filesChanged)|ForEach-Object{Normalize-RepoPath $_}|Where-Object{$_}|Sort-Object -Unique);$a=@(@($Actual)|ForEach-Object{Normalize-RepoPath $_}|Where-Object{$_}|Sort-Object -Unique);if($AllowAdditionalActual){$d=@($c|Where-Object{$_ -notin $a})}else{$d=@(Compare-Object $c $a)};[PSCustomObject]@{Matches=($d.Count-eq 0);Differences=$d}}

# ---------- Stage 28 deterministic verification ----------
function Test-VerificationCommandAllowed([string]$Command,$Settings){if($Command-match'[&|<>]' -or $Command.Contains("`n") -or $Command.Contains("`r")){return $false};foreach($p in @($Settings.allowedVerificationCommandPrefixes)){if($Command.StartsWith([string]$p,[StringComparison]::OrdinalIgnoreCase)){return $true}};$false}
function Get-VerificationCommands($Task,$Settings){if($Task.verificationCommands){return @($Task.verificationCommands)};$out=@();foreach($v in @($Task.verification)){if($v -and (Test-VerificationCommandAllowed ([string]$v) $Settings)){$out+=[string]$v}};@($out)}
function Get-VerificationDir($Task){if($Task.verificationWorkingDirectory){return [string]$Task.verificationWorkingDirectory};foreach($s in @($Task.scope)){$n=Normalize-RepoPath $s;if($n.StartsWith("backend/taskflow-api")){return "backend/taskflow-api"};if($n.StartsWith("frontend/taskflow-web")){return "frontend/taskflow-web"}};"."}
function Invoke-CommandTimeout([string]$Command,[string]$WorkingDirectory,[double]$TimeoutMinutes,[string]$Out,[string]$Err){Remove-Item $Out,$Err -ErrorAction SilentlyContinue;$p=Start-Process cmd.exe -ArgumentList @("/d","/s","/c",$Command) -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $Out -RedirectStandardError $Err -PassThru;$deadline=(Get-Date).AddMinutes($TimeoutMinutes);while(-not$p.HasExited){if((Get-Date)-ge$deadline){Stop-ProcessTree ([int]$p.Id);return [PSCustomObject]@{exitCode=-408;passed=$false;timedOut=$true}};Start-Sleep -Milliseconds 500;$p.Refresh()};$p.WaitForExit();$p.Refresh();[PSCustomObject]@{exitCode=[int]$p.ExitCode;passed=([int]$p.ExitCode-eq 0);timedOut=$false}}
function Invoke-TaskVerification($Task,[string]$Worktree,$Settings){$cmds=Get-VerificationCommands $Task $Settings;if($cmds.Count-eq 0){Write-Host "$($Task.id): no executable verification commands configured.";return [PSCustomObject]@{passed=$true;results=@()}};$rel=Get-VerificationDir $Task;$dir=if($rel-eq"."){$Worktree}else{Join-Path $Worktree $rel};if(-not(Test-Path $dir)){throw "Verification directory missing: $dir"};$r=@();$i=1;foreach($c in $cmds){if(-not(Test-VerificationCommandAllowed ([string]$c) $Settings)){throw "Verification command not allowed: $c"};$o=Join-Path $verificationDirectory "$($Task.id)-check-$i-stdout.txt";$e=Join-Path $verificationDirectory "$($Task.id)-check-$i-stderr.txt";Write-Host "VERIFY $($Task.id): $c";$x=Invoke-CommandTimeout ([string]$c) $dir ([double]$Settings.verificationTimeoutMinutes) $o $e;$r+=[PSCustomObject]@{command=[string]$c;exitCode=$x.exitCode;passed=$x.passed;timedOut=$x.timedOut;stdoutPath=$o;stderrPath=$e};if(-not$x.passed){break};$i++};[PSCustomObject]@{passed=(@($r|Where-Object{-not$_.passed}).Count-eq 0);results=$r}}
function Save-VerificationResult($Task,$Result){$p=Join-Path $verificationDirectory "$($Task.id)-verification.json";Save-Json ([PSCustomObject]@{taskId=$Task.id;verifiedAt=Now-Utc;passed=$Result.passed;results=$Result.results}) $p 20;[string]$p}

# ---------- prompts ----------
function New-WorkerPrompt($Task,$Worker){$scope=@($Task.scope)-join"`n- ";$verify=@($Task.verification)-join"`n- ";@"
You are $($Worker.role) for TaskFlow in an isolated Git worktree.
Read AGENTS.md, docs/requirements.md, docs/acceptance-criteria.md, docs/api-contract.md, docs/architecture.md and $($Task.taskFile).
Task: $($Task.id) - $($Task.name)
Allowed task scope:
- $scope
Do not silently expand scope or modify shared contracts/architecture unless explicitly authorized.
Verification expected:
- $verify
Implement the task and run safe relevant verification. Do not weaken correct tests.
At the end create repository-root .agent-result.json with valid JSON:
{"taskId":"$($Task.id)","outcome":"SUCCESS","summary":"short summary","filesChanged":["repo/relative/path"],"verification":[{"command":"command actually run","passed":true,"details":"result"}],"scopeRespected":true,"blockers":[],"unresolvedIssues":[]}
outcome must be SUCCESS, BLOCKED, or FAILED. .agent-result.json is an allowed orchestration artifact. Do not merge main.
"@}
function New-FixPrompt($Task,$Worker,$State){$scope=@($Task.scope)-join"`n- ";@"
You are $($Worker.role) performing a bounded FIX for $($Task.id) - $($Task.name).
Read the normal repository instructions and original task file $($Task.taskFile).
Failure evidence: $($State.lastFixReason)
Make the smallest correct repair, remain in original scope, do not weaken tests, do not change contracts unless authorized.
Allowed scope:
- $scope
Create .agent-result.json using the normal structured contract with taskId $($Task.id). Do not merge main.
"@}
function New-CiFixPrompt($Task,$Worker,[string]$Category,[string]$Log){$scope=@($Task.scope)-join"`n- ";@"
You are $($Worker.role) repairing GitHub CI for $($Task.id) - $($Task.name).
Failure category: $Category
Relevant CI evidence:
$Log
Make the smallest correct repair on the existing PR branch. Stay in scope:
- $scope
Do not weaken tests or modify CI just to hide a real product failure. Create .agent-result.json using the normal structured contract. Do not merge main.
"@}
function Save-Prompt([string]$Id,[string]$Text,[string]$Suffix){$p=Join-Path $generatedDirectory "$Id-$Suffix.txt";Set-Content $p $Text -Encoding UTF8;[string]$p}

# ---------- Codex launch ----------
function Start-Codex($Task,[string]$Worktree,[string]$PromptPath,[string]$Suffix){$out=Join-Path $logDirectory "$($Task.id)-$Suffix-stdout.txt";$err=Join-Path $logDirectory "$($Task.id)-$Suffix-stderr.txt";$stdin=Join-Path $logDirectory "$($Task.id)-$Suffix-stdin.txt";$exit=Join-Path $logDirectory "$($Task.id)-$Suffix-exitcode.txt";$result=Join-Path $Worktree ".agent-result.json";Remove-Item $out,$err,$exit,$result -ErrorAction SilentlyContinue;$prompt=Get-Content $PromptPath -Raw;Set-Content $stdin $prompt -Encoding UTF8;$sp=$stdin.Replace("'","''");$se=$exit.Replace("'","''");$child=@"
`$ErrorActionPreference="Continue"
Get-Content '$sp' -Raw | & cmd.exe /d /s /c "codex exec - 2>&1"
`$ec=`$LASTEXITCODE
Set-Content '$se' `$ec -Encoding ASCII
exit `$ec
"@;$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child));$p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-EncodedCommand",$encoded) -WorkingDirectory $Worktree -RedirectStandardOutput $out -RedirectStandardError $err -PassThru;@{Process=$p;ProcessStartTime=$p.StartTime.ToUniversalTime().ToString("o");StdOutPath=$out;StdErrPath=$err;ExitCodePath=$exit;ResultPath=$result;Worktree=$Worktree}}
function Wait-Codex($Runtime,[double]$Timeout){$p=$Runtime.Process;$deadline=(Get-Date).AddMinutes($Timeout);while(-not$p.HasExited){if((Get-Date)-ge$deadline){Stop-ProcessTree ([int]$p.Id);return [PSCustomObject]@{exitCode=-408}};Start-Sleep -Milliseconds 750;$p.Refresh()};$p.WaitForExit();$p.Refresh();$ec=Get-ExitCodeFile $Runtime.ExitCodePath;if($null-eq$ec){try{$ec=[int]$p.ExitCode}catch{$ec=-999}};[PSCustomObject]@{exitCode=[int]$ec}}

# ---------- Stage 27 verifier ----------
function Get-VerifierWorker($Task,$Workers,$Settings){$id=if($Task.verificationWorker){[string]$Task.verificationWorker}else{[string]$Settings.verifierWorkerId};$w=Get-WorkerById $id $Workers;if($w){return $w};[PSCustomObject]@{id=$id;role="Independent Verification Worker";readOnly=$true}}
function New-VerifierPrompt($Task,$Verifier){@"
You are the $($Verifier.role). Verify $($Task.id) - $($Task.name) independently and READ ONLY.
Read repository instructions, task, requirements, contracts, actual Git diff and .agent-result.json. Do not fix code. You may create only .verifier-result.json.
Create valid JSON: {"taskId":"$($Task.id)","outcome":"PASS","summary":"summary","checks":[{"name":"check","passed":true,"details":"evidence"}],"scopeViolations":[],"contractViolations":[],"architectureViolations":[],"issues":[]}
outcome must be PASS, FAIL, or BLOCKED.
"@}
function Test-VerifierResult($R,$Task){$e=@();if(-not$R){return [PSCustomObject]@{Valid=$false;Errors=@("missing/invalid verifier result")}};if($R.taskId-ne$Task.id){$e+="taskId mismatch"};if($R.outcome-notin@("PASS","FAIL","BLOCKED")){$e+="invalid outcome"};foreach($p in @("summary","checks","scopeViolations","contractViolations","architectureViolations","issues")){if(-not($R.PSObject.Properties.Name-contains$p)){$e+="$p required"}};[PSCustomObject]@{Valid=($e.Count-eq 0);Errors=$e}}
function Invoke-Verifier($Task,[string]$Worktree,$Workers,$Settings){
    $v=Get-VerifierWorker $Task $Workers $Settings
    $rp=Join-Path $Worktree ".verifier-result.json"
    Remove-Item $rp -ErrorAction SilentlyContinue
    $before=Get-WorktreeFingerprint $Worktree
    $prompt=New-VerifierPrompt $Task $v
    $null=Save-Prompt $Task.id $prompt "verifier-prompt"
    $out=Join-Path $logDirectory "$($Task.id)-verifier-stdout.txt"
    $err=Join-Path $logDirectory "$($Task.id)-verifier-stderr.txt"
    $stdin=Join-Path $logDirectory "$($Task.id)-verifier-stdin.txt"
    $exit=Join-Path $logDirectory "$($Task.id)-verifier-exitcode.txt"
    Set-Content $stdin $prompt -Encoding UTF8
    Remove-Item $out,$err,$exit -ErrorAction SilentlyContinue
    $sp=$stdin.Replace("'","''"); $se=$exit.Replace("'","''")
    $child=@"
`$ErrorActionPreference="Continue"
Get-Content '$sp' -Raw | & cmd.exe /d /s /c "codex exec - 2>&1"
`$ec=`$LASTEXITCODE
Set-Content '$se' `$ec -Encoding ASCII
exit `$ec
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
    $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-EncodedCommand",$encoded) -WorkingDirectory $Worktree -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $wait=Wait-Codex @{Process=$p;ExitCodePath=$exit} ([double]$Settings.workerTimeoutMinutes)
    if($wait.exitCode -ne 0){return [PSCustomObject]@{passed=$false;blocked=$false;reason="Verifier exited $($wait.exitCode)";resultPath=$rp}}
    $after=Get-WorktreeFingerprint $Worktree
    if($before -ne $after){return [PSCustomObject]@{passed=$false;blocked=$false;reason="Verifier modified worktree";resultPath=$rp}}
    try{$r=Get-Content $rp -Raw|ConvertFrom-Json}catch{$r=$null}
    $val=Test-VerifierResult $r $Task
    if(-not $val.Valid){return [PSCustomObject]@{passed=$false;blocked=$false;reason=("Invalid verifier result: "+($val.Errors-join"; "));resultPath=$rp}}
    if($r.outcome -eq "BLOCKED"){return [PSCustomObject]@{passed=$false;blocked=$true;reason=$r.summary;resultPath=$rp}}
    if($r.outcome -eq "FAIL"){
        $reason=$(if(@($r.issues).Count -gt 0){@($r.issues)-join"; "}else{$r.summary})
        return [PSCustomObject]@{passed=$false;blocked=$false;reason=$reason;resultPath=$rp}
    }
    if(@($r.checks|Where-Object{$_.passed -ne $true}).Count -gt 0){return [PSCustomObject]@{passed=$false;blocked=$false;reason="Verifier PASS contained failed checks";resultPath=$rp}}
    [PSCustomObject]@{passed=$true;blocked=$false;reason=$null;resultPath=$rp}
}

# ---------- Stage 32/33 GitHub helpers ----------
function Assert-Gh { if(-not(Get-Command gh -ErrorAction SilentlyContinue)){throw "GitHub CLI (gh) not found on PATH."} }
function Get-PrInfo([string]$Branch,[string]$Root){Assert-Gh;Push-Location $Root;try{$j=& gh pr view $Branch --json number,url,state,mergedAt,mergeCommit,statusCheckRollup 2>$null;if($LASTEXITCODE-ne 0){return $null};$j|ConvertFrom-Json}finally{Pop-Location}}
function Create-Pr($Task,[string]$Root,$Settings){$existing=Get-PrInfo $Task.branch $Root;if($existing){return $existing};$title=if($Task.pullRequest.title){[string]$Task.pullRequest.title}else{"$($Task.id): $($Task.name)"};$base=if($Task.pullRequest.base){[string]$Task.pullRequest.base}else{[string]$Settings.baseBranch};$scope=(@($Task.scope)|ForEach-Object{"- $_"})-join"`n";$verify=(@($Task.verification)|ForEach-Object{"- $_"})-join"`n";$body=@"
## Task
$($Task.id) - $($Task.name)
## Scope
$scope
## Verification
$verify
## Governance
Structured implementation result, independent verifier, deterministic verification, and human code approval were completed before PR creation. Final merge remains human-controlled.
"@;Push-Location $Root;try{& gh pr create --head $Task.branch --base $base --title $title --body $body;if($LASTEXITCODE-ne 0){throw "gh pr create failed"}}finally{Pop-Location};$p=Get-PrInfo $Task.branch $Root;if(-not$p){throw "PR created but could not be queried"};$p}
function Get-CheckState($C){if($C.conclusion){$x=([string]$C.conclusion).ToUpperInvariant();if($x-eq"SUCCESS"){return"PASSED"};if($x-in@("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","NEUTRAL","SKIPPED","STALE")){return"FAILED"}};if($C.state){$x=([string]$C.state).ToUpperInvariant();if($x-eq"SUCCESS"){return"PASSED"};if($x-in@("FAILURE","ERROR")){return"FAILED"}};"RUNNING"}
function Get-CiStatus([int]$Pr,[string]$Root){Assert-Gh;Push-Location $Root;try{$j=& gh pr view $Pr --json number,url,state,mergedAt,mergeCommit,statusCheckRollup;if($LASTEXITCODE-ne 0){throw "Could not query PR checks"};$p=$j|ConvertFrom-Json}finally{Pop-Location};if($p.state-eq"MERGED" -or $p.mergedAt){return [PSCustomObject]@{state="MERGED";checks=@($p.statusCheckRollup);pr=$p}};$checks=@($p.statusCheckRollup);if($checks.Count-eq 0){return [PSCustomObject]@{state="PENDING";checks=@();pr=$p}};$states=@($checks|ForEach-Object{Get-CheckState $_});if("FAILED"-in$states){$s="FAILED"}elseif("RUNNING"-in$states){$s="RUNNING"}else{$s="PASSED"};[PSCustomObject]@{state=$s;checks=$checks;pr=$p}}
function Get-CheckName($C){foreach($p in @("name","context","workflowName")){if($C.PSObject.Properties.Name-contains$p -and $C.$p){return [string]$C.$p}};"Unknown check"}
function Get-LatestCiFailure($Task,[string]$Root,$Settings){Assert-Gh;$wt=Join-Path $projectParent $Task.worktreeName;$head=Get-WorktreeHead $wt;Push-Location $Root;try{$j=& gh run list --branch $Task.branch --limit 10 --json databaseId,status,conclusion,headSha,event,workflowName,createdAt;if($LASTEXITCODE-ne 0){throw "gh run list failed"};$runs=@($j|ConvertFrom-Json);$r=$runs|Where-Object{$_.headSha-eq$head -and $_.event-eq"pull_request"}|Sort-Object createdAt -Descending|Select-Object -First 1;if(-not$r){$r=$runs|Sort-Object createdAt -Descending|Select-Object -First 1};if(-not$r){return $null};$lines=@(& gh run view $r.databaseId --log-failed);$n=[int]$Settings.ciFailureLogLines;if($n-gt 0 -and $lines.Count-gt$n){$lines=$lines[($lines.Count-$n)..($lines.Count-1)]};[PSCustomObject]@{runId=[string]$r.databaseId;log=($lines-join"`n")}}finally{Pop-Location}}
function Get-CiCategory([string]$Log){if([string]::IsNullOrWhiteSpace($Log)){return"UNKNOWN"};if($Log-match"Could not resolve host|ECONNRESET|ENETUNREACH|service unavailable"){return"INFRASTRUCTURE_OR_NETWORK"};if($Log-match"npm ERR!|Module not found|Cannot find module"){return"DEPENDENCY_OR_BUILD"};if($Log-match"Tests?:.*failed|FAIL |AssertionError"){return"TEST_FAILURE"};if($Log-match"lint|eslint"){return"LINT_FAILURE"};if($Log-match"TypeScript|TS\d{4}"){return"TYPECHECK_OR_BUILD"};"UNKNOWN"}

# ---------- Stage 30/31 local integration ----------
function Local-Merge($Task,$State,[string]$Root){if(-not(Test-RootClean $Root)){return [PSCustomObject]@{success=$false;reason="Main worktree not clean";sha=$null}};Push-Location $Root;try{$actual=(& git rev-parse $Task.branch).Trim();if($actual-ne$State.commitSha){return [PSCustomObject]@{success=$false;reason="Branch changed after approval";sha=$null}};& git merge --no-ff $Task.branch;if($LASTEXITCODE-ne 0){return [PSCustomObject]@{success=$false;reason="git merge failed";sha=$null}};[PSCustomObject]@{success=$true;reason=$null;sha=(& git rev-parse HEAD).Trim()}}finally{Pop-Location}}
function Integration-Verify([string]$Root,$Settings,[string]$Id){$o=Join-Path $verificationDirectory "$Id-integration-stdout.txt";$e=Join-Path $verificationDirectory "$Id-integration-stderr.txt";Invoke-CommandTimeout ([string]$Settings.integrationVerificationCommand) $Root ([double]$Settings.integrationVerificationTimeoutMinutes) $o $e}
function Rollback-Integration([string]$Root,[string]$Sha){if(-not(Test-RootClean $Root)){return [PSCustomObject]@{success=$false;reason="Main worktree not clean";sha=$null}};Push-Location $Root;try{& git revert -m 1 $Sha --no-edit;if($LASTEXITCODE-ne 0){return [PSCustomObject]@{success=$false;reason="git revert failed";sha=$null}};[PSCustomObject]@{success=$true;reason=$null;sha=(& git rev-parse HEAD).Trim()}}finally{Pop-Location}}

# ---------- post implementation validation ----------
function Validate-CompletedWorker($Task,$State,$Workers,$Settings,$RuntimeState,[string]$StateFile){
    $wt=if($State.worktreePath){[string]$State.worktreePath}else{Join-Path $projectParent $Task.worktreeName};if(-not(Test-Path $wt)){$State.state="FAILED";$State.lastFailureReason="Worktree missing during validation";Save-RuntimeState $RuntimeState $StateFile;return}
    $rp=Join-Path $wt ".agent-result.json";$State.agentResultPath=$rp;$r=Get-AgentResult $rp;$v=Test-AgentResult $r $Task;if(-not$v.Valid){$State.state="FAILED";$State.lastFailureReason="Invalid agent result: "+($v.Errors-join"; ");Save-RuntimeState $RuntimeState $StateFile;return}
    if($r.outcome-eq"BLOCKED"){$State.state="BLOCKED";$State.lastFailureReason=if(@($r.blockers).Count){@($r.blockers)-join"; "}else{$r.summary};Save-RuntimeState $RuntimeState $StateFile;return};if($r.outcome-eq"FAILED"){$State.state="FAILED";$State.lastFailureReason=$r.summary;Save-RuntimeState $RuntimeState $StateFile;return};if($r.scopeRespected-ne$true){$State.state="FAILED";$State.lastFailureReason="Agent reported scope violation";Save-RuntimeState $RuntimeState $StateFile;return};if(-not(Test-AgentVerification $r)){$State.state="FAILED";$State.lastFailureReason="Agent reported failed verification";Save-RuntimeState $RuntimeState $StateFile;return}
    $actual=Get-ChangedFiles $wt;$scope=Test-Scope $actual $Task;if(-not$scope.Valid){$State.state="FAILED";$State.lastFailureReason="Git scope violation: "+($scope.Violations-join", ");Save-RuntimeState $RuntimeState $StateFile;return};$claims=Test-ClaimedFiles $r $actual -AllowAdditionalActual:($State.executionMode-in@("FIX","CIFIX"));if(-not$claims.Matches){$State.state="FAILED";$State.lastFailureReason="filesChanged does not match Git changes";Save-RuntimeState $RuntimeState $StateFile;return}
    $State.state="IMPLEMENTED";Save-RuntimeState $RuntimeState $StateFile;Write-Host "$($Task.id): structured result accepted -> IMPLEMENTED";$State.state="VERIFYING";Save-RuntimeState $RuntimeState $StateFile;$ver=Invoke-Verifier $Task $wt $Workers.workers $Settings;$State.verifierResultPath=$ver.resultPath;if($ver.blocked){$State.state="BLOCKED";$State.lastFailureReason=$ver.reason;Save-RuntimeState $RuntimeState $StateFile;return};if(-not$ver.passed){$State.state="VERIFICATION_FAILED";$State.lastFailureReason=$ver.reason;Save-RuntimeState $RuntimeState $StateFile;return}
    $State.state="ORCHESTRATOR_VERIFYING";Save-RuntimeState $RuntimeState $StateFile;$det=Invoke-TaskVerification $Task $wt $Settings;$State.verificationResultPath=Save-VerificationResult $Task $det;if(-not$det.passed){$f=@($det.results|Where-Object{-not$_.passed})|Select-Object -First 1;$State.state="VERIFICATION_FAILED";$State.lastFailureReason="Deterministic verification failed: $($f.command) exited $($f.exitCode)";Save-RuntimeState $RuntimeState $StateFile;return}
    if($State.executionMode-eq"CIFIX"){$c=Commit-Worktree $Task $wt (Get-CiFixCommitMessage $Task);if(-not$c.success){$State.state="FAILED";$State.lastFailureReason="CI fix could not commit: $($c.reason)";Save-RuntimeState $RuntimeState $StateFile;return};$p=Push-Task $Task $wt ([string]$Settings.gitRemote) $c.commit;if(-not$p.success){$State.state="CI_FAILED";$State.commitSha=$c.commit;$State.lastCiFailureReason="CI fix push failed: $($p.reason)";Save-RuntimeState $RuntimeState $StateFile;return};$State.commitSha=$c.commit;$State.remoteBranch=$Task.branch;$State.state="CI_RUNNING";$State.ciState="RUNNING";$State.lastCiFailureReason=$null;$State.lastFailureReason=$null;Save-RuntimeState $RuntimeState $StateFile;Write-Host "$($Task.id): CI fix committed/pushed -> CI_RUNNING";return}
    $State.state="REVIEW";$State.lastFailureReason=$null;Save-RuntimeState $RuntimeState $StateFile;Write-Host "$($Task.id): verification pipeline passed -> REVIEW"
}

# ---------- scheduling ----------
function Get-RunningTasks($Tasks,$RuntimeState){@($Tasks|Where-Object{(Get-TaskRuntimeState $_.id $RuntimeState).state-in@("RUNNING","FIXING","CI_FIXING")})}
function Get-Schedulable($Tasks,$RuntimeState,$Settings){$ci=@($Tasks|Where-Object{$s=Get-TaskRuntimeState $_.id $RuntimeState;$s.state-eq"CI_FIX_REQUIRED"-and[int]$s.ciFixAttempts-lt[int]$Settings.maxCiFixAttempts});$fx=@($Tasks|Where-Object{$s=Get-TaskRuntimeState $_.id $RuntimeState;$s.state-eq"FIX_REQUIRED"-and[int]$s.fixAttempts-lt[int]$Settings.maxFixAttempts});$rd=@($Tasks|Where-Object{$s=Get-TaskRuntimeState $_.id $RuntimeState;$s.state-eq"READY"-and[int]$s.attempts-lt[int]$Settings.maxAttempts});@($ci)+@($fx)+@($rd)}
function Test-ScopeConflict($A,$B){foreach($a in @($A.scope)){foreach($b in @($B.scope)){$x=($a-replace'/\*\*$',''-replace'\\\*\*$','').TrimEnd('/','\');$y=($b-replace'/\*\*$',''-replace'\\\*\*$','').TrimEnd('/','\');if($x.StartsWith($y,[StringComparison]::OrdinalIgnoreCase)-or$y.StartsWith($x,[StringComparison]::OrdinalIgnoreCase)){return$true}}};$false}
function Get-Wave([array]$Tasks,[int]$Slots,[array]$Running){$w=@();foreach($c in $Tasks){if($w.Count-ge$Slots){break};$conflict=$false;foreach($r in $Running){if(Test-ScopeConflict $c $r){$conflict=$true;break}};if($conflict){continue};foreach($s in $w){if(Test-ScopeConflict $c $s){$conflict=$true;break}};if(-not$conflict){$w+=$c}};@($w)}

function Show-Status($Tasks,$RuntimeState,$Settings){Write-Host "`n=== TaskFlow Stage 33 Status ===`n";Write-Host "Workers: $($Settings.maxParallelWorkers)  Timeout: $($Settings.workerTimeoutMinutes)m  Verify: $($Settings.verificationTimeoutMinutes)m";foreach($t in $Tasks){$s=Get-TaskRuntimeState $t.id $RuntimeState;Write-Host "`n$($t.id) - $($t.name)";Write-Host "  State          : $($s.state)";Write-Host "  Owner          : $($t.owner)";Write-Host "  Attempts       : $($s.attempts)";Write-Host "  Fix Attempts   : $($s.fixAttempts)/$($Settings.maxFixAttempts)";Write-Host "  CI Fix Attempts: $($s.ciFixAttempts)/$($Settings.maxCiFixAttempts)";if($s.processId){Write-Host "  PID            : $($s.processId)"};if($s.commitSha){Write-Host "  Commit         : $($s.commitSha)"};if($s.pullRequestNumber){Write-Host "  PR             : #$($s.pullRequestNumber)"};if($s.pullRequestUrl){Write-Host "  PR URL         : $($s.pullRequestUrl)"};if($s.ciState){Write-Host "  CI             : $($s.ciState)"};if($s.integrationSha){Write-Host "  Integration    : $($s.integrationSha)"};if($s.rollbackSha){Write-Host "  Rollback       : $($s.rollbackSha)"};if($s.lastFailureReason){Write-Host "  Failure        : $($s.lastFailureReason)"};if($s.lastCiFailureReason){Write-Host "  CI Failure     : $($s.lastCiFailureReason)"}};Write-Host ""}

# ---------- startup ----------
Write-Host "`n=== TaskFlow Orchestrator - Stage 33 ===`n"
Initialize-RuntimeState $data.tasks $runtimeState
$null=Repair-StaleRunningTasks $data.tasks $runtimeState $settings
$null=Resolve-DependencyStates $data.tasks $runtimeState
Save-RuntimeState $runtimeState $stateFile

$needsId=@("retry","cancel","approve","fix","ci-fix","verify","commit","push","create-pr","check-ci","merge-local","verify-integration","rollback")
if($Command-in$needsId -and -not$TaskId){throw "TaskId is required for '$Command'."}
if($TaskId){$requestedTask=Get-TaskById $TaskId $data.tasks;if(-not$requestedTask){throw "Unknown task: $TaskId"};$requestedState=Get-TaskRuntimeState $TaskId $runtimeState}

if($Command-eq"status"){Show-Status $data.tasks $runtimeState $settings;return}
if($Command-eq"retry"){
    if($requestedState.state-notin@("FAILED","VERIFICATION_FAILED")){throw "$TaskId is not retryable."};if([int]$requestedState.attempts-ge[int]$settings.maxAttempts){throw "Max attempts reached."};$requestedState.state="READY";$requestedState.approved=$false;$requestedState.approvedAt=$null;$requestedState.lastExitCode=$null;$requestedState.completedAt=$null;$requestedState.processId=$null;$requestedState.processStartTime=$null;$requestedState.lastFailureReason=$null;$requestedState.executionMode=$null;Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId -> READY";return
}
if($Command-eq"cancel"){
    if($requestedState.state-notin@("RUNNING","FIXING","CI_FIXING")){throw "$TaskId is not running."};if($requestedState.processId){$p=Get-ProcessByIdSafe ([int]$requestedState.processId);if($p-and(Test-ProcessIdentityMatches $p $requestedState.processStartTime)){Stop-ProcessTree ([int]$requestedState.processId)}};$requestedState.state="FAILED";$requestedState.lastExitCode=-499;$requestedState.lastFailureReason="Worker cancelled by human.";$requestedState.processId=$null;$requestedState.processStartTime=$null;$requestedState.completedAt=Now-Utc;Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId cancelled.";return
}
if($Command-eq"approve"){
    if($requestedState.state-ne"REVIEW"){throw "$TaskId is not REVIEW."};$requestedState.state="COMMIT_READY";$requestedState.approved=$true;$requestedState.approvedAt=Now-Utc;$requestedState.lastFailureReason=$null;Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId: REVIEW -> COMMIT_READY";Write-Host "Next: -Command commit -TaskId $TaskId";return
}
if($Command-eq"fix"){
    if($requestedState.state-ne"VERIFICATION_FAILED"){throw "$TaskId is not VERIFICATION_FAILED."};if([int]$requestedState.fixAttempts-ge[int]$settings.maxFixAttempts){throw "Max fix attempts reached."};$requestedState.lastFixReason=$requestedState.lastFailureReason;$requestedState.state="FIX_REQUIRED";Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId -> FIX_REQUIRED. Run -Command run.";return
}
if($Command-eq"verify"){
    $wt=if($requestedState.worktreePath){$requestedState.worktreePath}else{Join-Path $projectParent $requestedTask.worktreeName};$r=Invoke-TaskVerification $requestedTask $wt $settings;$p=Save-VerificationResult $requestedTask $r;Write-Host "Verification passed: $($r.passed)";Write-Host "Result: $p";return
}
if($Command-eq"commit"){
    if($requestedState.state-ne"COMMIT_READY"){throw "$TaskId is not COMMIT_READY."};$wt=if($requestedState.worktreePath){$requestedState.worktreePath}else{Join-Path $projectParent $requestedTask.worktreeName};$r=Commit-Worktree $requestedTask $wt (Get-CommitMessage $requestedTask) -AllowClean;if(-not$r.success){throw $r.reason};$requestedState.commitSha=$r.commit;$requestedState.state="PUSH_READY";Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId: COMMIT_READY -> PUSH_READY ($($r.commit))";return
}
if($Command-eq"push"){
    if($requestedState.state-ne"PUSH_READY"){throw "$TaskId is not PUSH_READY."};$remote=[string]$settings.gitRemote;if(-not(Test-Remote $root $remote)){throw "Remote '$remote' not found."};$wt=if($requestedState.worktreePath){$requestedState.worktreePath}else{Join-Path $projectParent $requestedTask.worktreeName};$r=Push-Task $requestedTask $wt $remote $requestedState.commitSha;if(-not$r.success){throw $r.reason};$requestedState.remoteBranch=$requestedTask.branch;$requestedState.state="PR_READY";Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId: PUSH_READY -> PR_READY";return
}
if($Command-eq"create-pr"){
    if($requestedState.state-notin@("PR_READY","PR_OPEN")){throw "$TaskId is not PR_READY."};$pr=Create-Pr $requestedTask $root $settings;$requestedState.pullRequestNumber=[int]$pr.number;$requestedState.pullRequestUrl=[string]$pr.url;$requestedState.state="PR_OPEN";$requestedState.ciState="PENDING";Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId: PR_OPEN #$($pr.number) $($pr.url)";return
}
if($Command-eq"check-ci"){
    if(-not$requestedState.pullRequestNumber){throw "$TaskId has no PR."};$ci=Get-CiStatus ([int]$requestedState.pullRequestNumber) $root;$requestedState.lastCiCheckedAt=Now-Utc;if($ci.state-eq"MERGED"){$requestedState.state="MERGED";$requestedState.ciState="PASSED";if($ci.pr.mergeCommit -and $ci.pr.mergeCommit.oid){$requestedState.integrationSha=[string]$ci.pr.mergeCommit.oid};$requestedState.integratedAt=if($ci.pr.mergedAt){[string]$ci.pr.mergedAt}else{Now-Utc};$null=Resolve-DependencyStates $data.tasks $runtimeState;Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId: PR MERGED";return};if($ci.state-in@("PENDING","RUNNING")){$requestedState.state="CI_RUNNING";$requestedState.ciState=$ci.state;Write-Host "$TaskId: CI $($ci.state)"}elseif($ci.state-eq"PASSED"){$requestedState.state="MERGE_READY";$requestedState.ciState="PASSED";$requestedState.lastCiFailureReason=$null;Write-Host "$TaskId: CI PASSED -> MERGE_READY. Merge in GitHub after human review."}else{$requestedState.state="CI_FAILED";$requestedState.ciState="FAILED";$names=@($ci.checks|Where-Object{(Get-CheckState $_)-eq"FAILED"}|ForEach-Object{Get-CheckName $_});$requestedState.lastCiFailureReason=if($names.Count){"Failed checks: "+($names-join", ")}else{"CI failed"};Write-Host "$TaskId: CI_FAILED - $($requestedState.lastCiFailureReason)"};Save-RuntimeState $runtimeState $stateFile;return
}
if($Command-eq"ci-fix"){
    if($requestedState.state-ne"CI_FAILED"){throw "$TaskId is not CI_FAILED."};if([int]$requestedState.ciFixAttempts-ge[int]$settings.maxCiFixAttempts){throw "Max CI fix attempts reached."};$f=Get-LatestCiFailure $requestedTask $root $settings;if(-not$f){throw "Could not retrieve failed CI logs."};$cat=Get-CiCategory $f.log;if($cat-eq"INFRASTRUCTURE_OR_NETWORK"){Write-Host "Infrastructure/network failure detected; source repair not scheduled. Rerun CI manually.";return};$p=Join-Path $generatedDirectory "$TaskId-ci-failure.txt";Set-Content $p $f.log -Encoding UTF8;$requestedState.ciRunId=$f.runId;$requestedState.ciFailureLogPath=$p;$requestedState.lastCiFailureReason="$cat - $($requestedState.lastCiFailureReason)";$requestedState.state="CI_FIX_REQUIRED";Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId: CI_FAILED -> CI_FIX_REQUIRED. Run -Command run.";return
}

# Optional local merge path retained for Stages 30-31. PR flow is preferred from Stage 32 onward.
if($Command-eq"merge-local"){
    if($requestedState.state-ne"PUSH_READY"){throw "$TaskId must be PUSH_READY for local merge."};$ans=Read-Host "Bypass PR path and merge locally? (y/n)";if($ans-notin@("y","Y")){return};$requestedState.state="INTEGRATING";Save-RuntimeState $runtimeState $stateFile;$r=Local-Merge $requestedTask $requestedState $root;if($r.success){$requestedState.state="INTEGRATED";$requestedState.integrationSha=$r.sha;$requestedState.integratedAt=Now-Utc;$requestedState.lastFailureReason=$null}else{$requestedState.state="INTEGRATION_FAILED";$requestedState.lastFailureReason=$r.reason};Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId -> $($requestedState.state)";return
}
if($Command-eq"abort-merge"){Push-Location $root;try{& git merge --abort;if($LASTEXITCODE-ne 0){throw "git merge --abort failed"}}finally{Pop-Location};Write-Host "Merge aborted.";return}
if($Command-eq"verify-integration"){
    if($requestedState.state-ne"INTEGRATED"){throw "$TaskId is not INTEGRATED."};if((Get-RootHead $root)-ne$requestedState.integrationSha){throw "Main HEAD no longer equals this task integration SHA."};$requestedState.state="INTEGRATION_VERIFYING";Save-RuntimeState $runtimeState $stateFile;$r=Integration-Verify $root $settings $TaskId;$requestedState.integrationVerificationExitCode=$r.exitCode;if($r.passed){$requestedState.state="INTEGRATION_VERIFIED";$requestedState.integrationVerifiedAt=Now-Utc;$requestedState.lastFailureReason=$null;$null=Resolve-DependencyStates $data.tasks $runtimeState}else{$requestedState.state="ROLLBACK_REQUIRED";$requestedState.lastFailureReason="Integration verification failed: exit $($r.exitCode)"};Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId -> $($requestedState.state)";return
}
if($Command-eq"rollback"){
    if($requestedState.state-ne"ROLLBACK_REQUIRED"){throw "$TaskId is not ROLLBACK_REQUIRED."};$ans=Read-Host "Revert integration $($requestedState.integrationSha)? (y/n)";if($ans-notin@("y","Y")){return};$requestedState.state="ROLLING_BACK";Save-RuntimeState $runtimeState $stateFile;$r=Rollback-Integration $root $requestedState.integrationSha;if($r.success){$requestedState.state="ROLLED_BACK";$requestedState.rollbackSha=$r.sha;$requestedState.rolledBackAt=Now-Utc;$requestedState.lastFailureReason=$null}else{$requestedState.state="ROLLBACK_FAILED";$requestedState.lastFailureReason=$r.reason};Save-RuntimeState $runtimeState $stateFile;Write-Host "$TaskId -> $($requestedState.state)";return
}
if($Command-eq"abort-rollback"){Push-Location $root;try{& git revert --abort;if($LASTEXITCODE-ne 0){throw "git revert --abort failed"}}finally{Pop-Location};if($TaskId){$s=Get-TaskRuntimeState $TaskId $runtimeState;if($s.state-eq"ROLLBACK_FAILED"){$s.state="ROLLBACK_REQUIRED";Save-RuntimeState $runtimeState $stateFile}};Write-Host "Rollback aborted.";return}

# ---------- RUN ----------
$pending=@($data.tasks|Where-Object{(Get-TaskRuntimeState $_.id $runtimeState).state-eq"VALIDATION_PENDING"});foreach($t in $pending){Validate-CompletedWorker $t (Get-TaskRuntimeState $t.id $runtimeState) $workerData $settings $runtimeState $stateFile}
$running=@(Get-RunningTasks $data.tasks $runtimeState);$slots=[int]$settings.maxParallelWorkers-$running.Count;if($slots-le 0){Write-Host "All worker slots are occupied.";return}
$sched=@(Get-Schedulable $data.tasks $runtimeState $settings);if($sched.Count-eq 0){Write-Host "No READY/FIX_REQUIRED/CI_FIX_REQUIRED tasks.";return};$wave=@(Get-Wave $sched $slots $running);if($wave.Count-eq 0){Write-Host "No non-conflicting tasks can run.";return}
Write-Host "`nExecution wave:";foreach($t in $wave){$s=Get-TaskRuntimeState $t.id $runtimeState;Write-Host "  $($t.id) [$($s.state)]"};$ans=Read-Host "Launch these $(@($wave).Count) Codex worker(s)? (y/n)";if($ans-notin@("y","Y")){return}

$prepared=@();foreach($t in $wave){$s=Get-TaskRuntimeState $t.id $runtimeState;$w=Get-WorkerById $t.owner $workerData.workers;if(-not$w){throw "Worker '$($t.owner)' not found."};$wt=Ensure-Worktree $t $projectParent $root;if($s.state-eq"FIX_REQUIRED"){$mode="FIX";$prompt=New-FixPrompt $t $w $s;$suffix="fix"}elseif($s.state-eq"CI_FIX_REQUIRED"){$mode="CIFIX";if(-not(Test-Path $s.ciFailureLogPath)){throw "CI failure evidence missing."};$log=Get-Content $s.ciFailureLogPath -Raw;$prompt=New-CiFixPrompt $t $w (Get-CiCategory $log) $log;$suffix="ci-fix"}else{$mode="NORMAL";$prompt=New-WorkerPrompt $t $w;$suffix="worker"};$pp=Save-Prompt $t.id $prompt "$suffix-prompt";$prepared+=@{Task=$t;State=$s;Worker=$w;Worktree=$wt;Mode=$mode;Prompt=$pp;Suffix=$suffix}}
foreach($i in $prepared){$s=$i.State;if($i.Mode-eq"FIX"){$s.state="FIXING";$s.fixAttempts=[int]$s.fixAttempts+1}elseif($i.Mode-eq"CIFIX"){$s.state="CI_FIXING";$s.ciFixAttempts=[int]$s.ciFixAttempts+1}else{$s.state="RUNNING";$s.attempts=[int]$s.attempts+1};$s.executionMode=$i.Mode;$s.approved=$false;$s.approvedAt=$null;$s.startedAt=Now-Utc;$s.completedAt=$null;$s.lastExitCode=$null;$s.processId=$null;$s.processStartTime=$null;$s.lastFailureReason=$null;$s.worktreePath=$i.Worktree};Save-RuntimeState $runtimeState $stateFile

$active=@();foreach($i in $prepared){try{$rt=Start-Codex $i.Task $i.Worktree $i.Prompt $i.Suffix;$i.State.processId=[int]$rt.Process.Id;$i.State.processStartTime=$rt.ProcessStartTime;$i.State.stdoutPath=$rt.StdOutPath;$i.State.stderrPath=$rt.StdErrPath;$i.State.exitCodePath=$rt.ExitCodePath;$i.State.agentResultPath=$rt.ResultPath;$active+=@{Task=$i.Task;Runtime=$rt}}catch{$i.State.state="FAILED";$i.State.lastExitCode=-1;$i.State.lastFailureReason="Launch failed: $($_.Exception.Message)";$i.State.completedAt=Now-Utc};Save-RuntimeState $runtimeState $stateFile}
$validate=@();while($active.Count-gt 0){foreach($i in @($active)){$t=$i.Task;$rt=$i.Runtime;$s=Get-TaskRuntimeState $t.id $runtimeState;$p=$rt.Process;if($p.HasExited){$p.WaitForExit();$p.Refresh();$ec=Get-ExitCodeFile $rt.ExitCodePath;if($null-eq$ec){try{$ec=[int]$p.ExitCode}catch{$ec=-999}};$s.lastExitCode=$ec;$s.completedAt=Now-Utc;$s.processId=$null;$s.processStartTime=$null;if($ec-eq 0){$s.state="VALIDATION_PENDING";$validate+=$t}else{$s.state="FAILED";$s.lastFailureReason="Codex exited $ec"};Save-RuntimeState $runtimeState $stateFile;$active=@($active|Where-Object{$_.Task.id-ne$t.id});continue};$elapsed=(Get-Date).ToUniversalTime()-([DateTime]::Parse($s.startedAt).ToUniversalTime());if($elapsed.TotalMinutes-ge[double]$settings.workerTimeoutMinutes){Stop-ProcessTree ([int]$p.Id);$s.state="FAILED";$s.lastExitCode=-408;$s.lastFailureReason="Worker timeout";$s.completedAt=Now-Utc;$s.processId=$null;$s.processStartTime=$null;Save-RuntimeState $runtimeState $stateFile;$active=@($active|Where-Object{$_.Task.id-ne$t.id})}};if($active.Count){Start-Sleep -Seconds ([int]$settings.pollIntervalSeconds)}}
foreach($t in $validate){Validate-CompletedWorker $t (Get-TaskRuntimeState $t.id $runtimeState) $workerData $settings $runtimeState $stateFile}
$null=Resolve-DependencyStates $data.tasks $runtimeState;Save-RuntimeState $runtimeState $stateFile;Show-Status $wave $runtimeState $settings
$reviews=@($wave|Where-Object{(Get-TaskRuntimeState $_.id $runtimeState).state-eq"REVIEW"});if($reviews.Count){Write-Host "Human review required:";foreach($t in $reviews){$s=Get-TaskRuntimeState $t.id $runtimeState;Write-Host "  cd `"$($s.worktreePath)`"; git status; git diff";Write-Host "  .\orchestration\orchestrator.ps1 -Command approve -TaskId $($t.id)"}}
