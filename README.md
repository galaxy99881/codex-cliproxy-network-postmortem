# Codex + CLIProxyAPI 分流故障复盘

这是一份经过脱敏的网络故障复盘，目的是提醒使用 Codex、CLIProxyAPI 和本地代理工具组合的用户：不要在没有隔离和回滚验证的情况下修改全局代理出口。

> 本仓库不包含真实 OAuth 凭据、API Key、邮箱、节点地址、节点密码或原始配置备份。

## 事故现象

Codex 请求本地 Responses API 时返回：

```text
503 Service Unavailable: auth_unavailable: no auth available
```

同时，切换系统代理或开启 TUN 后，GPT 恢复可用。这很容易被误判为模型、Codex 登录或 Web Search 本身故障。

## 涉及的本地链路

```text
Codex Desktop
  -> 127.0.0.1:8318 透明鉴权代理
  -> 127.0.0.1:8317 CLIProxyAPI
       |-> GPT/Codex OAuth -> 127.0.0.1:17890 -> 主代理出口
       `-> Gemini OAuth   -> 127.0.0.1:17891 -> 独立 Mihomo 固定节点
```

端口和名称只是本次案例中的示例，不应直接照抄。

## 根因

故障发生在代理策略迁移的中间状态：

1. CLIProxyAPI 曾配置全局 `proxy-url`，导致所有 OAuth 提供商共同依赖一个出口。
2. 为 Gemini 增加独立出口时，清空了全局 `proxy-url`。
3. Gemini 凭据获得了账号级 `proxy_url`，但 GPT/Codex 凭据一度没有账号级代理。
4. 在直连无法访问上游认证服务的网络环境中，GPT 的 token 刷新或 API 请求失败。
5. CLIProxyAPI 找不到可用凭据，最终向 Codex 返回 `auth_unavailable`。

这不是简单的“GPT 没有登录”。`no auth available` 也可能表示：凭据存在，但刷新、网络出口或上游请求失败后被暂时判定为不可用。

## 更安全的分流方式

如果所用 CLIProxyAPI 版本明确支持账号级 `proxy_url`，可以让全局代理保持为空，再为不同 OAuth 凭据指定各自的本地出口：

```yaml
# CLIProxyAPI：不要让全部提供商被迫共享一个出口
proxy-url: ""
```

```json
{
  "type": "antigravity",
  "proxy_url": "http://127.0.0.1:17891"
}
```

```json
{
  "type": "codex",
  "proxy_url": "http://127.0.0.1:17890"
}
```

JSON 片段仅展示相关字段，不是完整凭据文件。

## 修改前必须做的检查

- 备份 CLIProxyAPI 配置和 OAuth 文件，并限制备份权限。
- 确认每个本地代理端口都在监听。
- 分别通过每个代理出口测试对应上游服务。
- 一次只改一层：代理节点、CLIProxyAPI 全局设置、账号级路由、Codex Provider 不要同时修改。
- 每次修改后分别验证 GPT 和 Gemini，不能以其中一个成功代表整体成功。
- 保留当前可用会话，不要在验证期间反复重启所有组件。
- 准备一条明确、经过验证的回滚路径。

## 建议的验证顺序

1. 检查本地端口监听状态。
2. 检查 CLIProxyAPI 健康接口和 `/v1/models`。
3. 测试 GPT/Codex 使用的代理出口。
4. 测试 Gemini 使用的代理出口。
5. 通过 CLIProxyAPI 分别发送最小请求。
6. 最后使用 Codex 本身做端到端模型探测。

直接请求代理只能证明网络链路，不能证明 Codex 已正确消费 Provider 和模型目录。

## 出现 503 时如何排查

按以下顺序检查：

1. `8318` 透明代理是否运行。
2. `8317` CLIProxyAPI 是否运行。
3. 账号级 `proxy_url` 对应端口是否运行。
4. 该出口是否能访问对应上游认证及 API 域名。
5. OAuth 凭据是否过期、被禁用或进入冷却状态。
6. CLIProxyAPI 日志中是否存在 token refresh、timeout、TLS 或 upstream 错误。

开启 TUN 后恢复，是“原先直连路径不可达”的重要证据，但不代表必须永久依赖 TUN。

## 备份安全提醒

以下内容绝不能提交到 GitHub：

- OAuth `access_token`、`refresh_token`、`id_token`
- CLIProxyAPI `api-keys` 和管理密钥
- 代理节点服务器、端口、UUID、密码、私钥及订阅地址
- 真实邮箱、账号 ID、项目 ID和包含这些信息的日志
- 原始 `.json`、`.yaml`、`.conf`、LaunchAgent 快照

即使仓库先设为私有，敏感数据进入 Git 历史后也不能只靠删除文件解决；应立即吊销凭据，并清理整个 Git 历史。

## 核心教训

代理可达性是认证系统的一部分。修改模型出口时，必须把“已有 GPT 会话继续工作”作为硬性验收条件，而不是只测试新增的 Gemini 路由。

