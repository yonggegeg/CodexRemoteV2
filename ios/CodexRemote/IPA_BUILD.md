# iOS IPA 打包说明

当前工程是 SwiftUI iOS 原生 App。`.ipa` 必须经过 Apple 的 iOS SDK 编译，实际打包环境必须是 macOS + Xcode。

## 方式一：Mac 本地生成未签名 IPA

```bash
cd ios/CodexRemote
chmod +x scripts/build-unsigned-ipa.sh
scripts/build-unsigned-ipa.sh
```

输出：

```text
ios/CodexRemote/build/CodexRemote-unsigned.ipa
```

说明：这个 IPA 是未签名包，主要用于后续重签名或归档，不保证能直接安装到 iPhone。

## 方式二：GitHub Actions 自动生成 IPA

把整个 `CodexRemoteRelay` 项目上传到 GitHub，并确保目录结构是：

```text
.github/workflows/build-ipa.yml
ios/CodexRemote/CodexRemote.xcodeproj
```

然后进入 GitHub：

```text
Actions → Build Unsigned IPA → Run workflow
```

完成后在 Artifacts 下载：

```text
CodexRemote-unsigned.ipa
```

## 要生成可安装 IPA

需要 Apple Developer 签名证书、Provisioning Profile、Bundle ID 和 Team ID。后续可以把 workflow 改成签名导出版本。
