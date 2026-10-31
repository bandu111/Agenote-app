# SoniNote / SoniCloud SDK 来源记录

- 官方仓库：https://github.com/SonicloudTech/sonicloud_opensdk
- 固定提交：`f10cd9bf2a2341566d923818602ac93fb9246091`，2026-10-25 获取。
- 克隆位置：项目外临时目录；未复制整个 Demo。
- Android：独立 SDK 目录的 `pnote_20260827161403.aar`，不是 Demo 内较早的 `pnote_20260728171001.aar`。
- iOS：独立 SDK 目录的 `libPNote.a` 与 `PNode.h`。
- 每个实际二进制/头文件的 SHA-256、字节数见 `sdk_manifest.json`。
- 上游 SDK 方法和回调参考 Flutter Demo、2026-04-23 双端文档及 `SDK 集成引导.docx`。引导仍提及旧 AAR 名称，实际以固定提交交付物及字节码中可核对的方法签名为准。

## 许可边界

仓库根目录公开声明 MIT，原文保留于 `UPSTREAM_LICENSE`，随 SDK 文件另保留副本。未找到独立二进制 SDK EULA、供应商商业授权书或第三方组件完整许可清单。**不能把示例/仓库的 MIT 声明直接等同于专有二进制 SDK、设备固件或所有依赖的商用与再分发授权。** 本次仅完成用户授权的本机源码集成；对外发布前需供应商确认 SDK 二进制授权及再分发条件，整理各依赖的许可/通知。

Android 引入的是官方 Demo/文档使用的 RxAndroidBle、RxJava 2/3、Retrofit、EventBus、greenDAO、AndroidAsync、xUtils、AppCompat、OkHttp 日志拦截依赖。其中 xUtils 是实际 AAR 的 `WindBluetoothService.onCreate()` 直接引用，不能只照旧 Markdown 列表遗漏。依赖通过 Maven 解析，不把整个 Demo 的 Gradle 配置搬进工程。

iOS 静态库经 LLVM 检查含 26 个 arm64/iPhoneOS 对象，最低版本字段为 iOS 11.0；现有 Runner 的更高最低版本不改。没有模拟器切片，不能声称兼容 iOS Simulator。未发现该二进制的 Opus 符号依赖，本期也不解码，不添加指南中的可选解码 Pod；CoreBluetooth、AVFoundation、AudioToolbox 和 Security 按实际符号引用链接。Xcode 编译、签名和链接结果仍须在 macOS 验证。
