# Codex Remote v2

v2 目标：Codex 会话同步 + 电脑双窗口监看 + 窗口截图发给 Codex。

## 已完成

- iOS 底部 Tab：会话 / 窗口 / 文件 / 设置
- Windows Agent v2 枚举桌面窗口
- 手机选择窗口 A / B
- 手机同时查看两个窗口截图流
- 在窗口页输入问题描述
- 一键把指定窗口当前截图作为图片附件发送给 Codex 通道
- Relay v2 支持图片上传和消息队列

## 待接入

- Codex app-server 真实 ThreadList / ThreadRead
- 把手机图片消息注入当前 Codex 会话
- 电脑端 Codex 操作实时同步到手机

## v2 默认端口

```text
8081
```

手机 App 设置：

```text
服务器地址：http://你的服务器:8081
App Token：v2 APP_TOKEN
```
