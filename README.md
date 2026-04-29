# test-skills

这是一个基于 `agent-harness-generator` 生成的权限管理系统智能体开发框架。仓库并不是普通的业务代码仓库起点，而是一个用于驱动 Codex/AI Agent 按计划完成开发的 harness：它把需求文档拆成任务 DAG，并提供环境初始化、任务调度、自动验证、日志记录和恢复执行能力。

原始需求来自：

- `权限管理系统需求设计文档.md`

生成后的核心上下文来自：

- `AGENTS.md`
- `architecture.md`
- `task.json`
- `env.json`
- `init.ps1`
- `run-loop.ps1`
- `使用说明.md`

## 项目目标

本项目目标是开发一个企业级后台权限管理系统，采用前后端分离架构：

- 后端：JDK 17、Spring Boot 3.x、Spring Security 6.x、Maven、MyBatis Plus、MySQL、Redis、JWT
- 前端：Vue 3、TypeScript、Vite、Vue Router、Pinia、Element Plus、Axios
- 核心能力：用户管理、角色管理、菜单管理、按钮权限、接口权限、数据权限、登录会话、在线用户、登录日志、操作日志

权限控制原则：

- 前端负责菜单、按钮、组件展示体验。
- 后端负责最终安全校验。
- 菜单、按钮、接口统一使用权限编码。
- 关键权限不能只依赖前端隐藏按钮。
- 数据权限必须在后端查询层兜底。

## 目录说明

```text
.
├── AGENTS.md                         # AI Agent 开发规范
├── architecture.md                   # 从需求文档提取的架构摘要
├── task.json                         # 任务 DAG、依赖、验收标准、验证命令
├── env.json                          # 本机工具、服务端口、MySQL/Redis 等环境快照
├── init.ps1                          # Windows PowerShell 初始化脚本
├── run-loop.ps1                      # 自动任务调度、Codex 调用、验证和重试脚本
├── tools.json                        # 本机工具探测结果
├── doc-analysis.json                 # 需求文档分析结果
├── doc-analysis-infra.json           # 基础设施探测输入
├── infra-result.json                 # MySQL/Redis 连通性探测结果
├── 使用说明.md                       # 更偏操作手册的使用说明
└── 权限管理系统需求设计文档.md       # 原始需求设计文档
```

计划中的业务代码目录会由后续任务创建：

```text
permission-system-backend             # Spring Boot 后端
permission-system-web                 # Vue 3 前端
tests/e2e                             # API 端到端测试脚本
```

## 当前环境配置

当前 `env.json` 中记录的服务和基础设施如下。

服务：

| 服务 | 类型 | 目录 | 端口 | 健康检查 |
|---|---|---|---:|---|
| `permission-backend` | Java/Spring Boot | `permission-system-backend` | `8080` | `/actuator/health` |
| `permission-system-web` | Vue/Vite | `permission-system-web` | `5173` | `/` |

基础设施：

| 组件 | 地址 | 端口 | 说明 |
|---|---|---:|---|
| MySQL | `8.146.233.212` | `3306` | 用户名 `ytzy`，密码在提交配置中使用 `CHANGE_ME` 占位 |
| Redis | `8.146.233.212` | `6379` | database `3` |

注意：仓库中不会提交真实数据库密码。需要本地运行时，请在本地配置中把 `CHANGE_ME` 替换为真实密码，或者通过环境变量/本地未提交配置注入。

## 任务计划说明

`task.json` 是本仓库最重要的计划文件。它把需求拆成 31 个可执行任务，每个任务包含：

- `id`：任务编号，例如 `W01-J01`
- `domain`：任务领域，可能是 `java`、`frontend`、`e2e`
- `title`：任务标题
- `description`：任务实现范围
- `dependencies`：前置依赖任务
- `service`：所属服务
- `acceptance`：验收标准
- `e2e_test`：快速验证命令
- `e2e_services`：验证时需要启动的服务
- `e2e_api_test`：API 端到端验证命令
- `e2e_playwright`：浏览器端到端验证命令
- `status`：任务状态，由脚本维护

任务执行顺序不是简单按文件顺序，而是按 `dependencies` 组成的 DAG 推进。只有前置依赖完成后，后续任务才会被选中。

## 使用方式一：在 Codex 中按计划驱动智能体开发

这种方式适合人工把控节奏，逐个任务让 Codex 实现、验证、汇报。推荐在项目早期使用，便于确认代码风格和架构方向。

### 1. 先让 Codex 读取上下文

在 Codex 中打开当前仓库后，可以发送：

```text
请先阅读 AGENTS.md、architecture.md、权限管理系统需求设计文档.md 和 task.json。
根据 task.json 的依赖关系，找出下一个可以执行的 pending 任务，只实现这个任务。
实现后运行该任务的 e2e_test 验证命令，并汇报修改文件和验证结果。
不要修改 task.json 的 status 字段。
```

### 2. 指定某个任务执行

例如执行第一个后端任务：

```text
请执行 task.json 中的 W01-J01。
先阅读 AGENTS.md 和 architecture.md，严格按任务 description 和 acceptance 实现。
完成后运行 e2e_test: mvn -f permission-system-backend/pom.xml -DskipTests compile。
不要改其他任务，不要修改 task.json 的 status 字段。
```

### 3. 通用任务提示词模板

```text
请执行 task.json 中的 {任务ID}。

要求：
1. 阅读 AGENTS.md、architecture.md、权限管理系统需求设计文档.md。
2. 只实现 {任务ID}，不要顺手做后续任务。
3. 严格满足 task.json 中该任务的 description 和 acceptance。
4. 完成后运行 e2e_test。
5. 如果验证失败，先修复再汇报。
6. 不要修改 task.json 的 status 字段。

最后请汇报：
- 修改了哪些文件
- 验证命令和结果
- 是否还有风险或需要确认的点
```

### 4. 人工推进建议

1. 先预览任务顺序：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -DryRun
```

2. 选择最前面的 pending 任务。
3. 在 Codex 中指定该任务 ID。
4. 查看 Codex 修改和验证结果。
5. 确认无误后再提交代码。
6. 继续下一个任务。

这种方式的好处是可控，缺点是需要人工逐个发起任务。

## 使用方式二：在 PowerShell 中直接调用 Codex 自动执行任务

这种方式适合让脚本自动推进：读取 `task.json`、构造 prompt、调用 `codex.cmd`、运行验证、失败重试、记录日志。

### 1. 环境要求

当前 harness 目标环境为 Windows PowerShell 5.1。建议准备：

- Java 17
- Maven
- Node.js / npm
- Git
- Codex CLI，命令名为 `codex.cmd`
- 可连接的 MySQL 和 Redis

PowerShell 脚本必须使用下面这种方式执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\init.ps1
```

不要直接双击 `.ps1` 文件，也不建议直接执行：

```powershell
.\init.ps1
```

### 2. 初始化环境

首次运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\init.ps1
```

如果只想先初始化本地目录和 Git 配置，跳过 MySQL/Redis 连通性检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\init.ps1 -SkipInfra
```

`init.ps1` 会做这些事：

- 检查 Java、Maven、Node、npm、Git
- 设置 UTF-8 相关环境变量
- 检查后端和前端目录是否存在
- 检查 MySQL/Redis 连通性
- 检查服务端口是否被占用
- 初始化 Git 仓库
- 创建 `logs/`、`tests/e2e/`、`progress.log`

### 3. 预览任务执行顺序

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -DryRun
```

这条命令不会修改代码，也不会调用 Codex，只展示按 DAG 推导出的任务执行顺序。

### 4. 自动执行全部任务

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1
```

脚本会自动：

- 读取 `task.json`
- 找到依赖已满足的 pending 任务
- 构造任务 prompt
- 调用 `codex.cmd`
- 运行 `e2e_test`
- 按需启动 `e2e_services`
- 执行 API 测试或 Playwright 测试
- 验证失败时重试
- 验证通过后提交代码
- 写入 `progress.log` 和 `logs/`

### 5. 只执行少量任务

只执行 1 个任务：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -MaxTasks 1
```

只执行 3 个任务：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -MaxTasks 3
```

推荐先使用小批量方式，确认生成代码符合预期后再扩大执行范围。

### 6. 从指定任务恢复

如果某个任务失败，例如 `W03-J04`，可以修复环境或代码后从该任务继续：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -StartFrom W03-J04
```

### 7. 指定 Codex 模型和推理等级

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -Model gpt-5.4 -Level xhigh
```

### 8. 日志位置

常用日志：

```text
progress.log                         # 任务开始、完成、失败、重试记录
logs/codex-{taskId}-attempt1.log      # Codex 执行日志
logs/{serviceName}.log                # 后端或前端服务启动日志
.tmp-codex-prompt.md                  # 临时 prompt 文件
```

前端 Playwright 结果通常在：

```text
permission-system-web/tests/e2e/results
permission-system-web/playwright-report
```

## 基础设施探测文件说明

`infra-result.json` 是最近一次基础设施连通性探测结果。目前记录：

- MySQL `8.146.233.212:3306` TCP 连通
- Redis `8.146.233.212:6379` TCP 连通

需要重新探测时可以运行：

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\10679\.codex\skills\agent-harness-generator\scripts\detect-infra.ps1 -InfraJsonFile .\doc-analysis-infra.json -OutputFile infra-result.json
```

注意：该探测只验证 TCP 端口连通性，不验证 MySQL 用户名/密码是否能认证成功，也不验证 Redis database 是否可读写。

## 验证 harness 是否完整

可以使用 skill 自带校验脚本检查文件、编码、DAG 和服务注册表：

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\10679\.codex\skills\agent-harness-generator\scripts\validate-harness.ps1 -ProjectRoot .
```

也可以单独校验 `task.json`：

```powershell
$env:PYTHONIOENCODING='utf-8'
D:\kang\work-app\python\python.exe C:\Users\10679\.codex\skills\agent-harness-generator\scripts\validate-task-json.py task.json env.json
```

## 安全注意事项

- 不要把真实数据库密码提交到 GitHub。
- 仓库中的 MySQL 密码字段使用 `CHANGE_ME` 占位。
- 如果本地需要真实密码，可以临时修改本地文件，但提交前必须还原为占位符。
- `task.json` 的 `status` 字段由 `run-loop.ps1` 管理，人工或 Codex 不应随意修改。
- 自动验证中的数据库 SQL 应尽量只读，避免 `DROP`、`TRUNCATE`、批量 `DELETE`。
- PowerShell 5.1 对中文和 UTF-8 很敏感，`.ps1` 文件应保持 UTF-8 with BOM。

## 推荐开发节奏

推荐先手动推进，再自动化推进：

1. 使用 Codex 手动执行 `W01-J01`、`W01-J02`、`W01-F01`，确认后端和前端骨架符合预期。
2. 运行 `run-loop.ps1 -DryRun` 检查任务顺序。
3. 使用 `run-loop.ps1 -MaxTasks 1` 或 `-MaxTasks 3` 小批量自动推进。
4. 每批任务完成后检查代码、测试和日志。
5. 等项目骨架稳定后，再扩大自动执行范围。

## 常见问题

### 1. 为什么 README 里没有真实 MySQL 密码？

因为 GitHub 仓库不应保存真实凭据。请在本地运行前把 `CHANGE_ME` 替换成真实密码，或改造为环境变量读取。

### 2. 为什么 `infra-result.json` 显示可连通，但后端仍可能启动失败？

`infra-result.json` 只说明 TCP 端口可达。后端还可能因为账号密码错误、数据库不存在、Redis 认证配置、表结构未初始化等原因启动失败。

### 3. 为什么 PowerShell 命令都带 `-ExecutionPolicy Bypass`？

Windows 默认执行策略可能阻止脚本运行。使用 `-ExecutionPolicy Bypass -File` 可以确保当前脚本按预期执行。

### 4. 为什么早期任务的 `e2e_services` 是空数组？

早期任务多是项目骨架、公共组件、DDL 等，还没有可启动服务。等进入 Auth、CRUD、前端页面、E2E 阶段后，任务会声明需要启动的服务。

### 5. 如何知道下一个该做哪个任务？

运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-loop.ps1 -DryRun
```

或者让 Codex 读取 `task.json`，根据 `dependencies` 找出下一个 pending 任务。

