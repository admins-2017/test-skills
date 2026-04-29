# 权限管理系统架构摘录

本文件由 `权限管理系统需求设计文档.md` 提取，供自动编码 agent 快速读取。原始需求文档仍是最高优先级上下文。

## 1. 项目定位

权限管理系统是企业级后台管理系统，采用前后端分离架构。第一阶段为单体后台管理系统，核心是稳定、清晰、可扩展的 RBAC 权限模型，并增强按钮级权限和数据权限。

核心原则：

- 前端负责菜单、按钮、组件的体验控制。
- 后端负责接口权限和数据权限的最终安全校验。
- 菜单权限、按钮权限、接口权限使用统一权限编码。
- 所有关键权限必须在后端二次校验。

## 2. 技术栈

后端：

- JDK 17
- Spring Boot 3.x
- Spring Security 6.x
- Maven
- MyBatis Plus
- MySQL 8.x
- Redis 6.x/7.x
- JWT
- Hibernate Validator
- Knife4j / Swagger
- Logback

前端：

- Vue 3
- TypeScript
- Vite
- Vue Router
- Pinia
- Element Plus
- Axios
- ECharts 可选
- SCSS 可选

## 3. 服务与端口

| 服务 | 目录 | 端口 | 健康检查 | 说明 |
|---|---|---:|---|---|
| permission-backend | `permission-system-backend` | 8080 | `/actuator/health` | Spring Boot 后端 |
| permission-system-web | `permission-system-web` | 5173 | `/` | Vite 前端 |

服务依赖：

- `permission-backend` 依赖 MySQL 和 Redis。
- `permission-system-web` 依赖 `permission-backend`。

## 4. 后端模块结构

```text
permission-system-backend
├── pom.xml
├── src/main/java/com/example/permission
│   ├── PermissionApplication.java
│   ├── common
│   │   ├── result
│   │   ├── exception
│   │   ├── constant
│   │   ├── enums
│   │   └── utils
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

## 5. 前端模块结构

```text
permission-system-web
├── package.json
├── vite.config.ts
├── tsconfig.json
├── src
│   ├── main.ts
│   ├── App.vue
│   ├── api
│   ├── router
│   ├── store/modules
│   ├── layouts
│   ├── directives
│   ├── components
│   ├── views/login
│   ├── views/dashboard
│   └── views/system
└── tests/e2e
```

## 6. 请求链路

1. 前端 Axios 携带 `Authorization: Bearer accessToken`。
2. 后端 `JwtAuthenticationFilter` 解析 Token。
3. 从 Redis 或数据库加载当前登录用户信息。
4. Spring Security 建立认证上下文。
5. Controller 进入具体接口。
6. `@PreAuthorize` 调用权限服务校验按钮或接口权限。
7. 数据查询接口由数据权限切面追加数据范围。
8. Service 执行业务逻辑。
9. Mapper 查询或写入 MySQL。
10. 操作日志切面记录请求、响应和异常。
11. 返回统一 `Result<T>`。

## 7. 数据库表

MVP 必须包含以下表：

- `sys_user`
- `sys_role`
- `sys_user_role`
- `sys_menu`
- `sys_role_menu`
- `sys_dept`
- `sys_role_data_scope`
- `sys_operation_log`
- `sys_login_log`

关键字段：

- 所有业务表使用 `id BIGINT PRIMARY KEY AUTO_INCREMENT`。
- 逻辑删除字段为 `deleted TINYINT NOT NULL DEFAULT 0`。
- 状态字段为 `status TINYINT NOT NULL DEFAULT 1`。
- 创建/更新时间字段为 `create_time`、`update_time`。

## 8. 核心 API

认证：

- `POST /auth/login`
- `POST /auth/logout`
- `POST /auth/refresh`
- `GET /auth/me`
- `GET /auth/captcha`

用户：

- `GET /system/users`
- `GET /system/users/{id}`
- `POST /system/users`
- `PUT /system/users/{id}`
- `DELETE /system/users/{id}`
- `PUT /system/users/{id}/status`
- `PUT /system/users/{id}/password`
- `PUT /system/users/{id}/roles`

角色：

- `GET /system/roles`
- `GET /system/roles/{id}`
- `POST /system/roles`
- `PUT /system/roles/{id}`
- `DELETE /system/roles/{id}`
- `PUT /system/roles/{id}/status`
- `GET /system/roles/{id}/permissions`
- `PUT /system/roles/{id}/permissions`
- `PUT /system/roles/{id}/data-scope`

菜单：

- `GET /system/menus/tree`
- `GET /system/menus/{id}`
- `POST /system/menus`
- `PUT /system/menus/{id}`
- `DELETE /system/menus/{id}`

部门：

- `GET /system/depts/tree`
- `GET /system/depts/{id}`
- `POST /system/depts`
- `PUT /system/depts/{id}`
- `DELETE /system/depts/{id}`

日志：

- `GET /system/logs/login`
- `GET /system/logs/operation`
- `DELETE /system/logs/login`
- `DELETE /system/logs/operation`

## 9. 权限编码

格式：`模块:资源:动作`。

用户：

- `system:user:list`
- `system:user:query`
- `system:user:add`
- `system:user:edit`
- `system:user:delete`
- `system:user:reset-password`
- `system:user:assign-role`
- `system:user:export`

角色：

- `system:role:list`
- `system:role:query`
- `system:role:add`
- `system:role:edit`
- `system:role:delete`
- `system:role:assign-permission`
- `system:role:data-scope`

菜单、部门、日志：

- `system:menu:add`
- `system:menu:edit`
- `system:menu:delete`
- `system:dept:add`
- `system:dept:edit`
- `system:dept:delete`
- `system:log:login`
- `system:log:operation`

## 10. 初始角色

- `admin` 超级管理员，权限 `*:*:*`
- `system_manager` 系统管理员，权限 `system:user:*`、`system:role:*`、`system:menu:*`、`system:dept:*`
- `audit_manager` 审计管理员，权限 `system:log:login`、`system:log:operation`
- `normal_user` 普通用户，权限 `dashboard:view`

## 11. 验收标准

- 用户可以正常登录、退出和刷新登录状态。
- 不同角色登录后看到不同菜单。
- 用户无按钮权限时前端不展示对应按钮。
- 用户直接调用无权限接口时后端返回 403。
- 角色权限变更后用户权限缓存能够刷新。
- 数据权限能够限制用户查询范围。
- 用户、角色、菜单、部门管理功能可正常使用。
- 权限变更、删除、重置密码等操作有审计日志。
- 前端刷新页面后动态路由和按钮权限仍能正确恢复。
