param(
    [string]$StartFrom = "",
    [switch]$DryRun = $false,
    [int]$MaxRetries = 2,
    [int]$MaxTasks = 0,
    [string]$Model = "gpt-5.4",
    [string]$Level = "xhigh",
    [ValidateSet("codex", "claude")]
    [string]$Engine = "codex"
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$RateLimitWaitSec = 30

$script:ServiceRegistry = @{}
$script:ServiceDeps = @{}
$script:RunningProcesses = @{}
$script:EnvData = $null

function Write-Step($msg) { Write-Host "`n=== STEP: $msg ===" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-FAIL($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-WARN($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-INFO($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkGray }
function Get-Timestamp { return (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Log-Progress {
    param(
        [string]$TaskId,
        [string]$Status,
        [string]$Detail = ""
    )
    $logPath = Join-Path $ProjectRoot "progress.log"
    $line = "$(Get-Timestamp) | $TaskId | $Status | $Detail"
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

function Save-Tasks {
    param(
        [object[]]$Tasks,
        [string]$TaskJsonPath
    )
    $obj = Get-Content $TaskJsonPath -Raw | ConvertFrom-Json
    $obj | Add-Member -MemberType NoteProperty -Name "tasks" -Value $Tasks -Force
    $json = $obj | ConvertTo-Json -Depth 20
    Write-Utf8NoBom -Path $TaskJsonPath -Content $json
}

function Get-NextTask {
    param([object[]]$Tasks)
    foreach ($task in $Tasks) {
        if ($task.status -ne "pending") {
            continue
        }
        $depsOk = $true
        foreach ($dep in $task.dependencies) {
            $depTask = $Tasks | Where-Object { $_.id -eq $dep } | Select-Object -First 1
            if (-not $depTask -or $depTask.status -ne "completed") {
                $depsOk = $false
                break
            }
        }
        if ($depsOk) {
            return $task
        }
    }
    return $null
}

function Build-VerifyCommand {
    param([object]$Task)
    if ($Task.e2e_test -and $Task.e2e_test.Trim() -ne "") {
        return $Task.e2e_test
    }
    if ($Task.domain -eq "java") {
        return "mvn -f permission-system-backend/pom.xml test"
    }
    if ($Task.domain -eq "frontend") {
        return "cd permission-system-web && npm run build"
    }
    return "Write-Host 'No verify command'"
}

function Run-Command {
    param([string]$Cmd)
    if (-not $Cmd -or $Cmd.Trim() -eq "") {
        return $true
    }

    Write-INFO "执行: $Cmd"
    $exitCode = 0
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        if ($Cmd -match '&&') {
            if ($Cmd -match '^cd\s+([^\s]+)\s*&&\s*(.+)$') {
                $workDir = $Matches[1]
                $restCmd = $Matches[2]
                $targetDir = Join-Path $ProjectRoot $workDir
                Push-Location $targetDir
                cmd /c $restCmd
                $exitCode = $LASTEXITCODE
                Pop-Location
            } else {
                cmd /c $Cmd
                $exitCode = $LASTEXITCODE
            }
        } else {
            Invoke-Expression $Cmd
            $exitCode = $LASTEXITCODE
        }
    } catch {
        Write-FAIL "命令异常: $_"
        $exitCode = 1
    }

    $ErrorActionPreference = $oldPref
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    return ($exitCode -eq 0)
}

function Initialize-ServiceRegistry {
    $envJsonPath = Join-Path $ProjectRoot "env.json"
    if (-not (Test-Path $envJsonPath)) {
        Write-WARN "env.json 不存在，服务生命周期不可用"
        return
    }

    $script:EnvData = Get-Content $envJsonPath -Raw | ConvertFrom-Json

    foreach ($svc in $script:EnvData.serviceRegistry.java) {
        $script:ServiceRegistry[$svc.name] = @{
            type = "java"
            port = [int]$svc.port
            module = $svc.module
            healthPath = $svc.healthPath
            startupTimeout = [int]$svc.startupTimeout
            workDir = $ProjectRoot
            cmd = "mvn spring-boot:run -f $($svc.module)/pom.xml -Dspring-boot.run.jvmArguments=`"-Dfile.encoding=UTF-8`""
        }
    }

    foreach ($svc in $script:EnvData.serviceRegistry.python) {
        $venvPython = Join-Path $ProjectRoot "$($svc.name)\.venv\Scripts\python.exe"
        $script:ServiceRegistry[$svc.name] = @{
            type = "python"
            port = [int]$svc.port
            healthPath = $svc.healthPath
            startupTimeout = [int]$svc.startupTimeout
            workDir = Join-Path $ProjectRoot $svc.name
            cmd = "`"$venvPython`" -m uvicorn app.main:app --host 0.0.0.0 --port $($svc.port)"
        }
    }

    foreach ($svc in $script:EnvData.serviceRegistry.frontend) {
        $script:ServiceRegistry[$svc.name] = @{
            type = "frontend"
            port = [int]$svc.port
            healthPath = $svc.healthPath
            startupTimeout = [int]$svc.startupTimeout
            workDir = Join-Path $ProjectRoot $svc.name
            cmd = "npm run dev"
        }
    }

    foreach ($prop in $script:EnvData.serviceDependencyGraph.PSObject.Properties) {
        $script:ServiceDeps[$prop.Name] = @($prop.Value)
    }
}

function Get-RequiredServices {
    param([object]$Task)
    $required = @()
    if ($Task.e2e_services) {
        foreach ($svc in $Task.e2e_services) {
            if ($svc -and $required -notcontains $svc) {
                $required += $svc
            }
        }
    }
    if ($required.Count -eq 0 -and $script:ServiceDeps.ContainsKey($Task.service)) {
        foreach ($dep in $script:ServiceDeps[$Task.service]) {
            if ($required -notcontains $dep) {
                $required += $dep
            }
        }
        if ($required -notcontains $Task.service) {
            $required += $Task.service
        }
    }
    return $required
}

function Add-ServiceWithDeps {
    param(
        [string]$Name,
        [hashtable]$Visited,
        [ref]$Order
    )
    if ($Visited.ContainsKey($Name)) {
        return
    }
    $Visited[$Name] = $true
    if ($script:ServiceDeps.ContainsKey($Name)) {
        foreach ($dep in $script:ServiceDeps[$Name]) {
            Add-ServiceWithDeps -Name $dep -Visited $Visited -Order $Order
        }
    }
    if ($Order.Value -notcontains $Name) {
        $Order.Value = @($Order.Value + $Name)
    }
}

function Start-ServiceBackground {
    param([string]$ServiceName)

    if (-not $script:ServiceRegistry.ContainsKey($ServiceName)) {
        Write-WARN "服务 $ServiceName 未在 env.json 注册，跳过启动"
        return $false
    }

    $svc = $script:ServiceRegistry[$ServiceName]
    if ($script:RunningProcesses.ContainsKey($ServiceName)) {
        Write-INFO "$ServiceName 已在运行"
        return $true
    }

    $portInUse = Get-NetTCPConnection -LocalPort $svc.port -State Listen -ErrorAction SilentlyContinue
    if ($portInUse) {
        $existPid = $portInUse.OwningProcess
        Write-WARN "$ServiceName 端口 $($svc.port) 已被 PID=$existPid 占用，视为外部运行"
        $script:RunningProcesses[$ServiceName] = @{
            PID = $existPid
            Port = $svc.port
            Name = $ServiceName
            External = $true
        }
        return $true
    }

    $logsDir = Join-Path $ProjectRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    $logFile = Join-Path $logsDir "$ServiceName.log"
    $workDir = $svc.workDir
    $cmd = $svc.cmd

    if (-not (Test-Path $workDir)) {
        Write-FAIL "$ServiceName 工作目录不存在: $workDir"
        return $false
    }

    Write-INFO "启动 $ServiceName (Port=$($svc.port))"
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c cd /d `"$workDir`" && $cmd > `"$logFile`" 2>&1" `
        -WindowStyle Hidden `
        -PassThru

    $script:RunningProcesses[$ServiceName] = @{
        PID = $proc.Id
        Port = $svc.port
        Name = $ServiceName
        External = $false
    }
    return $true
}

function Wait-ForHealth {
    param([string]$ServiceName)
    if (-not $script:ServiceRegistry.ContainsKey($ServiceName)) {
        return $false
    }
    $svc = $script:ServiceRegistry[$ServiceName]
    $timeout = [int]$svc.startupTimeout
    $interval = 5
    if ($script:EnvData -and $script:EnvData.testing -and $script:EnvData.testing.healthCheckInterval) {
        $interval = [int]$script:EnvData.testing.healthCheckInterval
    }

    $url = "http://localhost:$($svc.port)$($svc.healthPath)"
    $elapsed = 0
    Write-INFO "等待 $ServiceName 健康检查: $url"

    while ($elapsed -lt $timeout) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Write-OK "$ServiceName 健康检查通过"
                return $true
            }
        } catch {
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval

        if ($script:RunningProcesses.ContainsKey($ServiceName)) {
            $info = $script:RunningProcesses[$ServiceName]
            if (-not $info.External) {
                $proc = Get-Process -Id $info.PID -ErrorAction SilentlyContinue
                if (-not $proc) {
                    Write-FAIL "$ServiceName 进程已退出，请查看 logs\$ServiceName.log"
                    return $false
                }
            }
        }
    }

    Write-FAIL "$ServiceName 健康检查超时"
    return $false
}

function Stop-ServiceByName {
    param([string]$ServiceName)
    if (-not $script:RunningProcesses.ContainsKey($ServiceName)) {
        return
    }

    $info = $script:RunningProcesses[$ServiceName]
    if ($info.External) {
        Write-INFO "跳过外部进程 $ServiceName (PID=$($info.PID))"
        $script:RunningProcesses.Remove($ServiceName)
        return
    }

    $null = & taskkill /PID $info.PID /T /F 2>&1
    Start-Sleep -Milliseconds 500
    $portPid = (Get-NetTCPConnection -LocalPort $info.Port -State Listen -ErrorAction SilentlyContinue).OwningProcess
    if ($portPid) {
        Stop-Process -Id $portPid -Force -ErrorAction SilentlyContinue
    }
    $script:RunningProcesses.Remove($ServiceName)
    Write-INFO "已停止 $ServiceName"
}

function Stop-AllServices {
    $names = @($script:RunningProcesses.Keys)
    foreach ($name in $names) {
        Stop-ServiceByName $name
    }
}

function Start-RequiredServices {
    param([string[]]$ServiceNames)
    $order = @()
    $visited = @{}
    $orderRef = [ref]$order
    foreach ($name in $ServiceNames) {
        Add-ServiceWithDeps -Name $name -Visited $visited -Order $orderRef
    }
    $order = $orderRef.Value

    foreach ($name in $order) {
        if (-not $script:ServiceRegistry.ContainsKey($name)) {
            Write-WARN "服务 $name 未注册，跳过"
            continue
        }
        $started = Start-ServiceBackground $name
        if (-not $started) {
            return $false
        }
        $healthy = Wait-ForHealth $name
        if (-not $healthy) {
            Stop-AllServices
            return $false
        }
    }
    return $true
}

function Run-MultiStageVerify {
    param([object]$Task)

    Write-Step "验证阶段1: 快速门控 ($($Task.domain))"
    $gateCmd = Build-VerifyCommand $Task
    $gateOk = Run-Command $gateCmd
    if (-not $gateOk) {
        Write-FAIL "快速门控失败"
        return $false
    }
    Write-OK "快速门控通过"

    $services = Get-RequiredServices $Task
    if ($services.Count -eq 0) {
        Write-OK "无需启动服务"
        return $true
    }

    Write-Step "验证阶段2: 启动服务 ($($services -join ', '))"
    $startOk = Start-RequiredServices $services
    if (-not $startOk) {
        Write-FAIL "服务启动失败"
        Stop-AllServices
        return $false
    }

    try {
        $e2eOk = $true
        if ($Task.e2e_api_test) {
            Write-Step "验证阶段3a: API 测试"
            $apiOk = Run-Command $Task.e2e_api_test
            if (-not $apiOk) {
                $e2eOk = $false
            }
        }
        if ($e2eOk -and $Task.e2e_playwright) {
            Write-Step "验证阶段3b: Playwright 测试"
            $pwOk = Run-Command $Task.e2e_playwright
            if (-not $pwOk) {
                $e2eOk = $false
            }
        }
        return $e2eOk
    } finally {
        Write-Step "验证阶段4: 停止服务"
        Stop-AllServices
    }
}

function Build-Prompt {
    param([object]$Task)

    $acceptanceLines = ""
    foreach ($item in $Task.acceptance) {
        $acceptanceLines += "- $item`n"
    }

    $serviceList = "无"
    if ($Task.e2e_services -and $Task.e2e_services.Count -gt 0) {
        $serviceList = ($Task.e2e_services -join ", ")
    }

    $apiTest = "无"
    if ($Task.e2e_api_test) {
        $apiTest = $Task.e2e_api_test
    }

    $playwrightTest = "无"
    if ($Task.e2e_playwright) {
        $playwrightTest = $Task.e2e_playwright
    }

    $domainHint = "阅读 AGENTS.md 和 architecture.md，按任务域完成实现。"
    if ($Task.domain -eq "java") {
        $domainHint = "阅读 architecture.md 的后端设计和 AGENTS.md 的 Java 规范。遵循 Spring Boot 3.x、Spring Security 6.x、MyBatis Plus、Result<T> 返回结构。"
    }
    if ($Task.domain -eq "frontend") {
        $domainHint = "阅读 architecture.md 的前端设计和 AGENTS.md 的前端规范。遵循 Vue 3 Composition API、TypeScript、Element Plus、Pinia、Axios 封装。"
    }
    if ($Task.domain -eq "e2e") {
        $domainHint = "阅读 architecture.md 的验收标准和 AGENTS.md 的 E2E 门控规范。覆盖 API、前端、数据库、缓存和权限行为。"
    }

    $prompt = @"
你是权限管理系统的全栈开发者。

$domainHint

## 当前任务
- 任务 ID: $($Task.id)
- 域: $($Task.domain)
- 标题: $($Task.title)
- 服务: $($Task.service)
- 阶段: $($Task.phase)

## 任务描述
$($Task.description)

## 验收标准
$acceptanceLines
## E2E 验证命令
- 快速门控: $($Task.e2e_test)
- 需启动服务: $serviceList
- API 测试: $apiTest
- Playwright: $playwrightTest

## 要求
1. 严格遵循 AGENTS.md 中对应域的代码规范。
2. 参考 architecture.md 和原始需求文档。
3. 完成代码和测试后确保验证命令通过。
4. 不要修改 task.json 的 status 字段。
5. Windows PowerShell 5.1 不支持 && / ||，脚本中不要使用这些语法。
6. JSON 和 prompt 临时文件使用 BOM-free UTF-8。
"@
    return $prompt
}

function Build-RetryPrompt {
    param(
        [object]$Task,
        [string]$LastLogFile
    )

    $errorOutput = ""
    if (Test-Path $LastLogFile) {
        $errorOutput = Get-Content $LastLogFile -Raw -ErrorAction SilentlyContinue
    }
    $maxChars = 2000
    $errorSnippet = $errorOutput
    if ($errorOutput.Length -gt $maxChars) {
        $errorSnippet = "...(截断)...`n" + $errorOutput.Substring($errorOutput.Length - $maxChars)
    }

    $acceptanceLines = ""
    foreach ($item in $Task.acceptance) {
        $acceptanceLines += "- $item`n"
    }

    $prompt = @"
上次执行任务 $($Task.id) 后验证失败。请修复以下错误。

## 错误信息
$errorSnippet

## 原始任务
$($Task.title): $($Task.description)

## 验收标准
$acceptanceLines
## 修复要求
1. 分析错误原因并定位到具体文件。
2. 修复代码，确保验证命令通过: $($Task.e2e_test)
3. 不要引入新的问题。
4. 不要修改 task.json 的 status 字段。
"@
    return $prompt
}

function Invoke-Codex {
    param(
        [string]$PromptContent,
        [string]$LogFile
    )
    $promptFile = Join-Path $ProjectRoot ".tmp-codex-prompt.md"
    Write-Utf8NoBom -Path $promptFile -Content $PromptContent

    $codexArgs = @(
        "exec",
        "-C",
        $ProjectRoot,
        "-s",
        "danger-full-access",
        "--model",
        $Model,
        "--level",
        $Level,
        "--ephemeral",
        "-"
    )

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Get-Content $promptFile -Raw | & codex.cmd @codexArgs 2>&1 | Tee-Object -FilePath $LogFile
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPref

    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    $logContent = ""
    if (Test-Path $LogFile) {
        $logContent = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
    }
    if ($logContent -match 'status (409|503|429)') {
        Write-WARN "检测到 Codex API 限流，等待 ${RateLimitWaitSec}s"
        Start-Sleep -Seconds $RateLimitWaitSec
        return @{ Success = $false; RateLimited = $true; ExitCode = $exitCode }
    }
    return @{ Success = ($exitCode -eq 0); RateLimited = $false; ExitCode = $exitCode }
}

function Invoke-Claude {
    param(
        [string]$PromptContent,
        [string]$LogFile
    )
    $promptFile = Join-Path $ProjectRoot ".tmp-claude-prompt.md"
    Write-Utf8NoBom -Path $promptFile -Content $PromptContent

    $allowedTools = "Edit,Read,Bash,Write,MultiEdit,Glob,Grep,LS"
    $claudeArgs = @(
        "code",
        "--dangerously-skip-permissions",
        "-p",
        $promptFile,
        "--cwd",
        $ProjectRoot,
        "--allowedTools",
        $allowedTools
    )

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & claude @claudeArgs 2>&1 | Tee-Object -FilePath $LogFile
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPref

    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    $logContent = ""
    if (Test-Path $LogFile) {
        $logContent = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
    }
    if ($logContent -match 'rate_limit|overloaded') {
        Write-WARN "检测到 Claude API 限流，等待 ${RateLimitWaitSec}s"
        Start-Sleep -Seconds $RateLimitWaitSec
        return @{ Success = $false; RateLimited = $true; ExitCode = $exitCode }
    }
    return @{ Success = ($exitCode -eq 0); RateLimited = $false; ExitCode = $exitCode }
}

function Invoke-AIEngine {
    param(
        [string]$PromptContent,
        [string]$LogFile
    )
    if ($Engine -eq "codex") {
        return Invoke-Codex -PromptContent $PromptContent -LogFile $LogFile
    }
    if ($Engine -eq "claude") {
        return Invoke-Claude -PromptContent $PromptContent -LogFile $LogFile
    }
    Write-FAIL "未知引擎: $Engine"
    return @{ Success = $false; RateLimited = $false; ExitCode = 1 }
}

function Git-Commit {
    param([object]$Task)
    Push-Location $ProjectRoot
    $gitDir = Join-Path $ProjectRoot ".git"
    if (-not (Test-Path $gitDir)) {
        git init
    }
    git add -A
    git reset -- task.json progress.log
    $commitMsg = "feat($($Task.service)): $($Task.title)"
    $changed = git diff --cached --name-only
    if ($changed) {
        git commit -m $commitMsg
        Write-OK "Git 提交: $commitMsg"
    } else {
        Write-INFO "无文件变更，跳过提交"
    }
    Pop-Location
}

function Show-Stats {
    param([string]$TaskJsonPath)
    $taskData = Get-Content $TaskJsonPath -Raw | ConvertFrom-Json
    $tasks = @($taskData.tasks)
    $completed = ($tasks | Where-Object { $_.status -eq "completed" }).Count
    $failed = ($tasks | Where-Object { $_.status -eq "failed" }).Count
    $pending = ($tasks | Where-Object { $_.status -eq "pending" }).Count
    $skipped = ($tasks | Where-Object { $_.status -eq "skipped" }).Count

    Write-Host "`n===== 执行统计 =====" -ForegroundColor Cyan
    Write-Host "  完成: $completed" -ForegroundColor Green
    Write-Host "  失败: $failed" -ForegroundColor Red
    Write-Host "  待执行: $pending" -ForegroundColor Yellow
    Write-Host "  跳过: $skipped" -ForegroundColor DarkGray

    if ($failed -gt 0) {
        $failedTasks = $tasks | Where-Object { $_.status -eq "failed" }
        Write-Host "`n失败任务:" -ForegroundColor Red
        foreach ($ft in $failedTasks) {
            Write-Host "  - $($ft.id): $($ft.title)" -ForegroundColor Red
        }
        $firstFailed = ($failedTasks | Select-Object -First 1).id
        Write-Host "`n重启命令:" -ForegroundColor Yellow
        Write-Host "  powershell -ExecutionPolicy Bypass -File run-loop.ps1 -StartFrom $firstFailed" -ForegroundColor Green
    }
    Log-Progress "SUMMARY" "DONE" "completed=$completed failed=$failed pending=$pending"
}

function Invoke-Main {
    $taskJsonPath = Join-Path $ProjectRoot "task.json"
    if (-not (Test-Path $taskJsonPath)) {
        Write-FAIL "task.json 不存在"
        exit 1
    }

    $logsDir = Join-Path $ProjectRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    $progressLog = Join-Path $ProjectRoot "progress.log"
    if (-not (Test-Path $progressLog)) {
        Add-Content -Path $progressLog -Value "# Progress Log - 权限管理系统" -Encoding UTF8
    }

    Initialize-ServiceRegistry

    $taskData = Get-Content $taskJsonPath -Raw | ConvertFrom-Json
    $tasks = @($taskData.tasks)

    $zombies = $tasks | Where-Object { $_.status -eq "in_progress" }
    foreach ($zombie in $zombies) {
        Write-WARN "恢复僵尸任务: $($zombie.id) -> pending"
        $zombie.status = "pending"
    }
    if ($zombies.Count -gt 0) {
        Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
    }

    if ($DryRun) {
        Write-Step "DryRun 模式: 任务执行顺序预览"
        $simTasks = @()
        foreach ($t in $tasks) {
            $simTasks += $t.PSObject.Copy()
        }
        $preview = @()
        while ($true) {
            $next = Get-NextTask $simTasks
            if (-not $next) {
                break
            }
            $preview += $next
            $next.status = "completed"
        }
        $i = 1
        foreach ($p in $preview) {
            Write-Host "  $i. [$($p.domain)] $($p.id): $($p.title)"
            $i++
        }
        Write-Host "`n共 $($preview.Count) 个可执行任务"
        return
    }

    $skipMode = ($StartFrom -ne "")
    $completedCount = 0
    $failedCount = 0
    $maxLoops = $tasks.Count * ($MaxRetries + 2)
    $loopCount = 0

    while ($true) {
        $loopCount++
        if ($loopCount -gt $maxLoops) {
            Write-FAIL "安全阀触发: 循环次数超过 $maxLoops"
            break
        }

        $taskData = Get-Content $taskJsonPath -Raw | ConvertFrom-Json
        $tasks = @($taskData.tasks)
        $task = Get-NextTask $tasks
        if (-not $task) {
            Write-INFO "没有更多可执行任务"
            break
        }

        if ($skipMode) {
            if ($task.id -eq $StartFrom) {
                $skipMode = $false
            } else {
                Write-INFO "StartFrom 跳过: $($task.id)"
                $task.status = "skipped"
                Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
                continue
            }
        }

        if ($MaxTasks -gt 0 -and $completedCount -ge $MaxTasks) {
            Write-INFO "已达到 MaxTasks=$MaxTasks"
            break
        }

        Write-Step "任务 $($task.id): $($task.title) [$($task.domain)]"
        $task.status = "in_progress"
        Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
        Log-Progress $task.id "STARTED"

        $prompt = Build-Prompt $task
        $logFile = Join-Path $logsDir "$Engine-$($task.id)-attempt1.log"
        $result = Invoke-AIEngine -PromptContent $prompt -LogFile $logFile

        if ($result.RateLimited) {
            $task.status = "pending"
            Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
            continue
        }

        $verifyOk = Run-MultiStageVerify $task
        if ($verifyOk) {
            $task.status = "completed"
            Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
            Log-Progress $task.id "COMPLETED"
            $completedCount++
            Git-Commit $task
            Start-Sleep -Seconds 10
            continue
        }

        $retrySuccess = $false
        for ($retry = 1; $retry -le $MaxRetries; $retry++) {
            Write-WARN "重试 $retry/$MaxRetries"
            Log-Progress $task.id "RETRY" "attempt $($retry + 1)"
            $retryPrompt = Build-RetryPrompt -Task $task -LastLogFile $logFile
            $retryLog = Join-Path $logsDir "$Engine-$($task.id)-attempt$($retry + 1).log"
            $retryResult = Invoke-AIEngine -PromptContent $retryPrompt -LogFile $retryLog
            if ($retryResult.RateLimited) {
                $retry--
                continue
            }
            $retryVerify = Run-MultiStageVerify $task
            if ($retryVerify) {
                $retrySuccess = $true
                break
            }
            $logFile = $retryLog
        }

        if ($retrySuccess) {
            $task.status = "completed"
            Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
            Log-Progress $task.id "COMPLETED" "after retry"
            $completedCount++
            Git-Commit $task
        } else {
            $task.status = "failed"
            Save-Tasks -Tasks $tasks -TaskJsonPath $taskJsonPath
            Log-Progress $task.id "FAILED" "after $MaxRetries retries"
            $failedCount++
        }

        Start-Sleep -Seconds 10
    }

    Show-Stats -TaskJsonPath $taskJsonPath
}

$null = Register-EngineEvent PowerShell.Exiting -Action { Stop-AllServices }

try {
    Invoke-Main
} finally {
    Stop-AllServices
}
