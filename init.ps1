param(
    [switch]$SkipInfra = $false
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$EnvJsonPath = Join-Path $ProjectRoot "env.json"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-WARN($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-FAIL($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

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

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        $wait = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $tcp.Connected) {
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

if (-not (Test-Path $EnvJsonPath)) {
    Write-FAIL "env.json 不存在: $EnvJsonPath"
    exit 1
}

$EnvData = Get-Content $EnvJsonPath -Raw | ConvertFrom-Json

Write-Step "Phase A: 工具版本验证与编码环境"

if (-not $env:MAVEN_OPTS -or $env:MAVEN_OPTS -notmatch 'file\.encoding') {
    $env:MAVEN_OPTS = "$env:MAVEN_OPTS -Dfile.encoding=UTF-8"
}
$env:PYTHONIOENCODING = "utf-8"
$env:NODE_OPTIONS = "--max-old-space-size=4096"

$oldPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"

$javaVer = & java -version 2>&1 | Out-String
if ($javaVer -match '(\d+)\.') {
    $javaMajor = [int]$Matches[1]
    if ($javaMajor -lt 17) {
        Write-FAIL "Java 版本过低，需要 17+"
        exit 1
    }
    Write-OK "Java: $($javaVer.Trim().Split("`n")[0])"
} else {
    Write-FAIL "Java 未安装或不可用"
    exit 1
}

$mvnVer = & mvn --version 2>&1 | Out-String
if ($mvnVer -match 'Apache Maven') {
    Write-OK "Maven: $($mvnVer.Trim().Split("`n")[0])"
} else {
    Write-FAIL "Maven 未安装或不可用"
    exit 1
}

$nodeVer = & node --version 2>&1 | Out-String
if ($nodeVer.Trim()) {
    Write-OK "Node: $($nodeVer.Trim())"
} else {
    Write-FAIL "Node 未安装或不可用"
    exit 1
}

$npmVer = & npm --version 2>&1 | Out-String
if ($npmVer.Trim()) {
    Write-OK "npm: $($npmVer.Trim())"
} else {
    Write-FAIL "npm 未安装或不可用"
    exit 1
}

$gitVer = & git --version 2>&1 | Out-String
if ($gitVer.Trim()) {
    Write-OK "Git: $($gitVer.Trim())"
} else {
    Write-FAIL "Git 未安装或不可用"
    exit 1
}

$ErrorActionPreference = $oldPref

Write-Step "Phase B: Java 模块结构验证"

$backendDir = Join-Path $ProjectRoot "permission-system-backend"
if (Test-Path $backendDir) {
    Write-OK "后端目录存在: permission-system-backend"
} else {
    Write-WARN "后端目录不存在，将由任务 W01-J01 创建"
}

$backendPom = Join-Path $backendDir "pom.xml"
if (Test-Path $backendPom) {
    Write-OK "后端 pom.xml 存在"
} else {
    Write-WARN "后端 pom.xml 不存在，将由任务 W01-J01 创建"
}

Write-Step "Phase C: Python 虚拟环境初始化"
if ($EnvData.pythonServices -and $EnvData.pythonServices.services -and $EnvData.pythonServices.services.Count -gt 0) {
    foreach ($svc in $EnvData.pythonServices.services) {
        Write-WARN "检测到 Python 服务 $($svc.name)，但权限系统 MVP 不应新增 Python 服务"
    }
} else {
    Write-OK "本项目无 Python 服务，跳过 venv 初始化"
}

Write-Step "Phase C2: Playwright 安装检查"

$frontendDir = Join-Path $ProjectRoot $EnvData.frontendProject.name
if (Test-Path $frontendDir) {
    $pkgJsonPath = Join-Path $frontendDir "package.json"
    if (Test-Path $pkgJsonPath) {
        Push-Location $frontendDir
        $pkg = Get-Content $pkgJsonPath -Raw | ConvertFrom-Json
        $pwInstalled = $false
        if ($pkg.devDependencies -and $pkg.devDependencies.'@playwright/test') {
            $pwInstalled = $true
        }
        if (-not $pwInstalled) {
            Write-OK "安装 @playwright/test"
            npm install -D "@playwright/test" --silent
        } else {
            Write-OK "@playwright/test 已声明"
        }
        $browserRoot = Join-Path $env:LOCALAPPDATA "ms-playwright"
        if (-not (Test-Path $browserRoot)) {
            Write-OK "安装 Playwright chromium"
            npx playwright install chromium
        } else {
            Write-OK "Playwright 浏览器目录存在"
        }
        Pop-Location
    } else {
        Write-WARN "前端 package.json 不存在，将由任务 W01-F01 创建"
    }
} else {
    Write-WARN "前端目录不存在，将由任务 W01-F01 创建"
}

Write-Step "Phase D: 前端依赖安装"

if (Test-Path $frontendDir) {
    $nodeModules = Join-Path $frontendDir "node_modules"
    if (-not (Test-Path $nodeModules)) {
        if (Test-Path (Join-Path $frontendDir "package.json")) {
            Push-Location $frontendDir
            Write-OK "执行 npm install"
            npm install
            Pop-Location
        } else {
            Write-WARN "package.json 不存在，跳过 npm install"
        }
    } else {
        Write-OK "node_modules 已存在"
    }
} else {
    Write-WARN "前端目录不存在，跳过 npm install"
}

Write-Step "Phase E: 基础设施连接测试"

if (-not $SkipInfra) {
    $infraOk = $true
    foreach ($infra in $EnvData.infrastructure) {
        if ($infra.phase -ne "mvp") {
            continue
        }
        $ok = Test-TcpPort -HostName $infra.host -Port ([int]$infra.port)
        if ($ok) {
            Write-OK "$($infra.name): $($infra.host):$($infra.port) 连通"
        } else {
            Write-FAIL "$($infra.name): $($infra.host):$($infra.port) 不可达"
            $infraOk = $false
        }
    }
    if (-not $infraOk) {
        Write-FAIL "基础设施连接失败。开发前请启动 MySQL/Redis，或使用 -SkipInfra 仅初始化文件结构。"
        exit 1
    }
} else {
    Write-WARN "跳过基础设施检测 (-SkipInfra)"
}

Write-Step "Phase E2: 服务端口可用性检查"

$portsToCheck = @()
foreach ($svc in $EnvData.serviceRegistry.java) {
    $portsToCheck += @{ Name = $svc.name; Port = [int]$svc.port }
}
foreach ($svc in $EnvData.serviceRegistry.frontend) {
    $portsToCheck += @{ Name = $svc.name; Port = [int]$svc.port }
}

foreach ($entry in $portsToCheck) {
    $inUse = Get-NetTCPConnection -LocalPort $entry.Port -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        $pid = $inUse.OwningProcess
        $procName = (Get-Process -Id $pid -ErrorAction SilentlyContinue).ProcessName
        Write-WARN "端口 $($entry.Port) ($($entry.Name)) 被 $procName (PID=$pid) 占用"
    } else {
        Write-OK "端口 $($entry.Port) ($($entry.Name)) 可用"
    }
}

Write-Step "Phase F: Git 初始化与工作目录文件"

if (-not (Test-Path (Join-Path $ProjectRoot ".git"))) {
    Push-Location $ProjectRoot
    git init
    Pop-Location
    Write-OK "Git 仓库已初始化"
} else {
    Write-OK "Git 仓库已存在"
}

git config core.quotepath false
git config i18n.commitEncoding utf-8
git config i18n.logOutputEncoding utf-8
git config core.autocrlf input

$gitattributesPath = Join-Path $ProjectRoot ".gitattributes"
if (-not (Test-Path $gitattributesPath)) {
    $gitattributesContent = @"
* text=auto eol=lf
*.ps1 text eol=crlf
*.bat text eol=crlf
*.cmd text eol=crlf
"@
    Write-Utf8NoBom -Path $gitattributesPath -Content $gitattributesContent
    Write-OK ".gitattributes 已创建"
} else {
    Write-OK ".gitattributes 已存在"
}

$gitignorePath = Join-Path $ProjectRoot ".gitignore"
if (-not (Test-Path $gitignorePath)) {
    $gitignoreContent = @"
# Java
target/
*.class

# Node
node_modules/
dist/
coverage/
playwright-report/
test-results/

# Logs and local state
logs/
*.log
progress.log
.tmp-*

# IDE / OS
.idea/
.vscode/
*.iml
.DS_Store
Thumbs.db
"@
    Write-Utf8NoBom -Path $gitignorePath -Content $gitignoreContent
    Write-OK ".gitignore 已创建"
} else {
    Write-OK ".gitignore 已存在"
}

$progressLog = Join-Path $ProjectRoot "progress.log"
if (-not (Test-Path $progressLog)) {
    $header = "# Progress Log - 权限管理系统`n# Generated by Agent Harness Generator v4`n# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
    Add-Content -Path $progressLog -Value $header -Encoding UTF8
    Write-OK "progress.log 已创建"
} else {
    Write-OK "progress.log 已存在"
}

$e2eDir = Join-Path $ProjectRoot "tests\e2e"
if (-not (Test-Path $e2eDir)) {
    New-Item -ItemType Directory -Path $e2eDir -Force | Out-Null
    Write-OK "tests/e2e 目录已创建"
} else {
    Write-OK "tests/e2e 目录已存在"
}

$logsDir = Join-Path $ProjectRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Write-OK "logs 目录已创建"
} else {
    Write-OK "logs 目录已存在"
}

if (-not $EnvData.mirrors.maven.hasAliyunMirror) {
    Write-WARN "Maven 未检测到国内镜像，首次下载依赖可能较慢"
}

Write-Step "Phase G: 环境摘要"

$taskCount = 0
$taskJsonPath = Join-Path $ProjectRoot "task.json"
if (Test-Path $taskJsonPath) {
    $taskCount = (Get-Content $taskJsonPath -Raw | ConvertFrom-Json).tasks.Count
}

Write-Host ""
Write-Host "项目根目录:   $ProjectRoot" -ForegroundColor White
Write-Host "后端服务:     permission-backend:8080" -ForegroundColor White
Write-Host "前端项目:     permission-system-web:5173" -ForegroundColor White
Write-Host "任务总数:     $taskCount" -ForegroundColor White
Write-Host ""
Write-Host "下一步操作:" -ForegroundColor Yellow
Write-Host "  powershell -ExecutionPolicy Bypass -File run-loop.ps1 -DryRun" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File run-loop.ps1" -ForegroundColor Green
Write-Host ""
Write-OK "初始化完成"
