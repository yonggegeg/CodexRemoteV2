# Codex Remote v2 使用说明

v2 是重新设计版，不再是简单的 `codex exec` 外壳。

## 当前已实现

- 更完整的 iOS App UI：会话 / 窗口 / 文件 / 设置
- 双窗口监看：手机上同时看电脑两个指定窗口
- 电脑窗口列表：选择任意打开的软件/游戏/Codex窗口
- 窗口截图发送：点“截图发给 Codex”，把指定窗口当前截图作为图片附件发送
- 引导消息：发现 Codex 正在做错方向时，手机发送纠正指令
- 引导截图：窗口截图也可以勾选“作为引导消息发送”
- Relay v2：支持窗口状态、图片上传、消息队列
- Windows Agent v2：枚举窗口、截图上传、接收手机消息并保存

## 还要继续接入

- Codex app-server 的真实会话列表
- 手机发送普通消息 -> turn/start
- 手机发送引导消息 -> turn/steer
- 把手机上传的图片注入当前 Codex 会话
- 电脑 Codex 输出实时同步到手机

## 服务器 v2

建议使用端口 8081，避免和旧版 8080 冲突。

```bash
cd relay-server-v2
APP_TOKEN="你的v2-app-token" \
AGENT_TOKEN="你的v2-agent-token" \
PORT=8081 \
node server.js
```

## Windows Agent v2

```powershell
cd windows-agent-v2
$env:RELAY_URL="http://115.159.221.170:8081"
$env:AGENT_TOKEN="你的v2-agent-token"
node agent-v2.js
```

## iOS App v2

上传到 GitHub 后运行：

```text
Actions -> Build Unsigned IPA v2 -> Run workflow
```

下载 Artifact：

```text
CodexRemoteV2-unsigned-ipa
```

## 手机设置

```text
服务器地址：http://115.159.221.170:8081
App Token：你的v2-app-token
```
