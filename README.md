# Codex + CLIProxyAPI 分流故障复盘

这是一份经过脱敏的网络故障复盘，目的是提醒使用 Codex、CLIProxyAPI 和本地代理工具组合的用户：不要在没有隔离和回滚验证的情况下修改全局代理出口。

> 本仓库不包含真实 OAuth 凭据、API Key、邮箱、节点地址、节点密码或原始配置备份。

## 完整历程

这次尝试的目标，是在不改变 Codex 原生 `openai` Provider 身份和历史记录归属的前提下，通过本地 CLIProxyAPI 把 Gemini 3.7 加入 Codex 模型目录。

大致经历如下：

1. 在本机运行 CLIProxyAPI，并增加一个仅监听回环地址的透明鉴权代理。
2. Codex 保持 `model_provider = "openai"`，但临时将 Responses API 指向本地透明代理。
3. CLIProxyAPI 同时载入 Codex OAuth 与 Antigravity/Gemini OAuth 凭据。
4. 最初使用 CLIProxyAPI 的全局 `proxy-url`，导致 GPT 和 Gemini 共用同一个代理出口。
5. 为降低相互影响，随后尝试账号级 `proxy_url`：GPT 走主代理端口，Gemini 走独立 Mihomo 端口。
6. 测试发现部分节点能访问 Google OAuth 和 Gemini API 首页，但真实 Gemini 请求仍可能失败。
7. Gemini 改回主代理端口后，对香港、英国和多个美国节点进行了真实 Responses 请求验证。
8. 多个节点虽然 TLS、HTTP 和测速均正常，Google 仍返回 `User location is not supported for the API use.`。
9. 同时，GPT/Codex 链路曾出现 TLS handshake EOF、`auth_unavailable`、503 和频繁重连。
10. 最终判断：这套链路增加的进程、认证刷新、代理端口和节点变量过多，稳定性收益不足以覆盖维护成本，因此放弃并卸载 CLIProxyAPI。

## 为什么“网络测试通过”仍不代表 Gemini 可用

这次排查最容易误判的地方，是以下检查都可能成功：

- Google OAuth 域名可以完成 TLS 握手；
- Gemini API 域名返回 HTTP 响应；
- 节点下载速度正常；
- CLIProxyAPI 的 `/v1/models` 中存在目标模型；

但真实模型请求依然可能因为出口 IP 的地理识别、OAuth 刷新、上游协议或账号策略而失败。只有通过 Codex 发起一次完整 Responses 请求并收到正常最终响应，才能认定该节点和路由真正可用。

## 最终结局：卸载 CLIProxyAPI

最终执行了完整卸载：

- 卸载 Homebrew 安装的 CLIProxyAPI；
- 停止并移除透明代理和 Gemini 辅助 Mihomo 的 LaunchAgent；
- 释放本地 `8317`、`8318` 和 `17891` 端口；
- 清理 CLIProxyAPI、模型桥和 Gemini 辅助代理的运行配置；
- 清理 Homebrew 配置目录中的 CLIProxyAPI 配置及历史副本；
- Codex 恢复使用官方 `openai` Provider，不再指向本地 `8318`；
- 完整原始备份继续保存在本机，未提交到 GitHub。

本仓库中的检测脚本作为故障排查参考保留。卸载 CLIProxyAPI 后，本地端口检查失败属于预期结果。

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

## 手动检测脚本

仓库提供了一个只读检测脚本。它不会切换节点、修改 TUN、编辑凭据或重启服务：

```bash
./scripts/check-yunniao-gemini.sh
```

默认检查当前云鸟节点、Google OAuth、Gemini API、下载速度、CLIProxyAPI 健康状态和 3.7 模型路由。

需要真正通过 Codex 调用一次 Gemini 3.7 时运行：

```bash
./scripts/check-yunniao-gemini.sh --full
```

`--full` 会消耗少量模型额度。可以使用 `--bytes` 调整测速下载量：

```bash
./scripts/check-yunniao-gemini.sh --bytes 10000000
```

批量检测云鸟全部真实节点：

```bash
./scripts/benchmark-yunniao-gemini.sh
```

脚本会逐个临时切换 `GLOBAL` 节点，记录节点类型、历史延迟、出口 IP/国家、Google OAuth、Gemini API TLS 和下载速度，最后自动恢复原节点。运行期间当前网络可能短暂中断。

如果 EasyCLIProxyAPI 的 `8317` 正在被 Claude Code 使用，脚本默认拒绝执行，以免切换节点造成 Claude 会话断线。暂停 Claude Code 后再运行；确认可以接受中断时才使用 `--force`。

如果 EasyCLIProxyAPI 桌面版正在 `127.0.0.1:8317` 提供目标模型，脚本会自动通过它已有的 OAuth 做真实 Responses 验证。客户端密钥只从桌面版本地配置读取到内存，不会打印或写入报告。

没有桌面版路由时，也可以设置官方 Gemini API Key：

```bash
GEMINI_API_KEY='your-key' ./scripts/benchmark-yunniao-gemini.sh
```

密钥只作为进程环境变量使用，不会写入报告。桌面版路由和 API Key 都不可用时，结果统一标记为 `UNVERIFIED`，避免把“域名可以访问”误报为“Gemini 正常使用”。先测试三个节点可运行：

```bash
./scripts/benchmark-yunniao-gemini.sh --limit 3
```

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

如果引入第三方模型必须让原生 GPT 请求也经过多个本地中间层，那么新增能力和整体稳定性应被放在同等优先级评估。能跑通一次不等于适合长期使用；无法做到故障隔离、自动回滚和端到端持续验证时，恢复官方直连往往是更稳妥的选择。
