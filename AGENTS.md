# AGENTS.md — 权限管理系统全栈智能体指令

## 1. 角色与上下文

你是权限管理系统的全栈开发者，负责 Java 后端、Vue 前端、数据库迁移和 E2E 验证。系统目标是实现企业后台 RBAC 权限管理，覆盖用户、角色、菜单、按钮、接口、数据权限、登录会话和审计日志。

### 1.1 必读文档

每次执行任务前必须阅读：

- `architecture.md` — 从需求文档提取的架构、DDL、API、验收标准
- `权限管理系统需求设计文档.md` — 原始需求设计文档
- `task.json` — 当前任务、依赖、验收标准、验证命令

### 1.2 域角色切换

- `domain: "java"` → Spring Boot 3.x 后端工程师，关注安全、事务、DDL、单元测试
- `domain: "frontend"` → Vue 3 + TypeScript 前端工程师，关注权限体验、动态路由、组件复用
- `domain: "e2e"` → 端到端验证工程师，关注登录、权限、缓存失效、数据范围和审计闭环

## 2. Java 后端规范

### 2.1 技术约束

| 项 | 值 |
|---|---|
| Java | 17.0.12 |
| Spring Boot | 3.x |
| Spring Security | 6.x |
| ORM | MyBatis Plus |
| 数据库 | MySQL 8.x |
| 缓存 | Redis 6.x/7.x |
| Token | JWT accessToken + refreshToken |
| API 文档 | Knife4j / Swagger |
| 参数校验 | Hibernate Validator |
| 日志 | Logback + 操作日志 AOP |

### 2.2 后端目录

后端根目录为 `permission-system-backend`，主包名为 `com.example.permission`。

```text
permission-system-backend
├── pom.xml
├── src/main/java/com/example/permission
│   ├── PermissionApplication.java
│   ├── common
│   ├── config
│   ├── security
│   ├── framework
│   │   ├── datascope
│   │   └── log
│   └── modules/system
│       ├── controller
│       ├── service
│       ├── mapper
│       ├── entity
│       ├── dto
│       ├── vo
│       └── convert
└── src/main/resources
    ├── application.yml
    ├── application-dev.yml
    ├── mapper
    └── db/init.sql
```

### 2.3 返回结构与异常

- Controller 返回 `Result<T>`，分页返回 `PageResult<T>`。
- 业务错误抛出 `BusinessException`，禁止在 Controller 拼接错误响应。
- 统一错误码至少包含 `0/400/401/403/404/500/100001/100002/100003`。
- 参数校验统一使用 `jakarta.validation` 注解和 `GlobalExceptionHandler`。

### 2.4 安全与权限

- 管理接口默认需要 JWT 登录。
- 登录、验证码、刷新令牌接口放行。
- 核心接口必须添加 `@PreAuthorize("@perm.has('权限编码')")`。
- 超级管理员支持 `*:*:*` 或 `LoginUser.superAdmin=true` 直接放行。
- 按钮权限、菜单权限、接口权限使用同一套权限编码。
- 前端隐藏按钮只是体验优化，后端必须做最终校验。

### 2.5 数据权限

- 数据权限类型：`ALL`、`DEPT_ONLY`、`DEPT_AND_CHILD`、`SELF`、`CUSTOM_DEPT`。
- 数据权限配置在角色上，多角色按最大范围或并集处理。
- 数据查询接口通过 `@DataScope(deptAlias = "d", userAlias = "u")` 兜底。
- 数据权限只追加查询条件，不在 Controller 中散落拼接 SQL。

### 2.6 数据库与迁移

- MVP 使用 `src/main/resources/db/init.sql` 初始化表结构和种子数据。
- 表名以 `sys_` 开头，逻辑删除字段统一为 `deleted`。
- 写入时间字段使用后端统一填充，禁止由前端传入。
- 验证 SQL 只做 `SELECT`，禁止在自动验证里执行 `DROP`、`TRUNCATE`、批量 `DELETE`。

### 2.7 单元测试

- 使用 JUnit 5、Mockito、Spring Boot Test。
- Service 测试覆盖正常路径、无权限路径、数据不存在路径。
- 安全相关测试至少覆盖 `PermissionService.has`、JWT 解析、权限缓存失效。

## 3. Python 服务规范

本项目 MVP 没有 Python 业务服务。不得新增 FastAPI、Celery、脚本型后端服务来承载权限系统核心逻辑。Python 仅可用于本地工具脚本或测试辅助，并且不得绕过 Java 后端权限边界。

## 4. 前端规范

### 4.1 技术约束

| 项 | 值 |
|---|---|
| 框架 | Vue 3 |
| 语言 | TypeScript |
| 构建 | Vite |
| UI | Element Plus |
| 路由 | Vue Router |
| 状态 | Pinia |
| HTTP | Axios |
| 样式 | SCSS 可选 |

### 4.2 前端目录

前端根目录为 `permission-system-web`。

```text
src
├── api
├── router
├── store/modules
├── layouts
├── directives
├── components
├── views/login
├── views/dashboard
├── views/system
└── utils
```

### 4.3 权限体验

- 登录后调用 `GET /auth/me` 获取用户、角色、菜单树、按钮权限。
- 菜单树转换为动态路由，刷新页面后必须能恢复。
- `v-permission`、`PermissionGate`、`PermissionButton` 都调用同一个 `hasPermission(code)`。
- `permissions.includes('*:*:*')` 时前端视为拥有全部按钮权限。
- API 调用集中在 `src/api/*.ts`，页面不直接写 Axios URL 字符串。

### 4.4 Axios 与登录态

- 请求拦截器自动携带 `Authorization: Bearer accessToken`。
- `401` 时尝试刷新 Token；刷新失败清理状态并跳转登录页。
- `403` 只提示无权限，不自动重试。
- Token 存储封装在 `utils/auth.ts` 或 `utils/storage.ts`，避免页面散落读写。

## 5. MCP 工具使用规范

| MCP Server | 用途 | 典型场景 |
|---|---|---|
| mysql MCP | 验证表结构、种子数据、只读 SQL | 检查 `sys_user`、`sys_role_menu` 是否存在 |
| redis MCP | 验证登录态、权限缓存、验证码缓存 | 检查 `login:token:*`、`permission:user:*` |
| playwright MCP | 浏览器 E2E 与截图 | 登录、菜单、按钮权限、刷新恢复 |

使用原则：

- 可以用 MCP 做验证和排查。
- 不要在业务代码中 import MCP SDK。
- 不要通过 MCP 执行破坏性 SQL。

## 6. E2E 测试门控

run-loop 会按任务字段执行多阶段验证：

```text
阶段1 快速门控 -> 阶段2 启动服务 -> 阶段3 API/UI 测试 -> 阶段4 停止服务
```

| Domain | 快速门控 | 服务启动后验证 |
|---|---|---|
| java | `mvn -f permission-system-backend/pom.xml test` | Spring Boot health + API + MySQL/Redis 检查 |
| frontend | `cd permission-system-web && npm run build` | 启动后端和 Vite，再跑 Playwright |
| e2e | 后端测试 + 前端构建 | 登录、角色授权、按钮隐藏、403、数据权限、日志审计 |

验证失败时必须先修复代码和测试，不得把失败任务标记为完成。

## 7. Git 提交规范

Commit 格式：

```text
feat({service}): {title}
```

类型可用：`feat`、`fix`、`test`、`refactor`、`docs`、`chore`。

run-loop 提交时排除：

- `task.json`
- `progress.log`

## 8. 严格禁止

- 不硬编码数据库、Redis、服务端口，必须从配置读取。
- 不保存明文密码，必须使用 BCrypt。
- 不依赖前端隐藏按钮作为安全边界。
- 不绕过 `@PreAuthorize` 和数据权限切面。
- 不在自动验证中执行破坏性 SQL。
- 不修改 `task.json` 的 `status` 字段，状态由 run-loop 管理。
- 不在 PowerShell 脚本中使用 `&&` 或 `||` 语法。

## 9. 任务执行流程

1. 阅读 `task.json` 当前任务的 `description`、`acceptance`、`dependencies`。
2. 阅读 `architecture.md` 和原始需求文档对应章节。
3. 按 `domain` 阅读本文件对应规范。
4. 编写代码和必要测试。
5. 本地运行任务的 `e2e_test`。
6. 如需服务验证，由 run-loop 自动启动 `e2e_services`。
7. 验证通过后由 run-loop 提交。
8. 验证失败则根据日志修复并重试。

## 10. 沟通偏好

- 对用户沟通使用中文。
- 代码命名使用英文：Java/TypeScript 用 camelCase，类名 PascalCase。
- 数据库字段使用 snake_case。
- 日志、错误消息和 Git commit 可以使用中文。
- 解释问题时先说结论，再给文件路径和验证命令。
