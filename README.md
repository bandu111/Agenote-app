# Agenote App

Agenote 是面向个人的会议与工作跟进助手。它将手机或 AI Voice 录音卡采集的讨论连接到逐字稿、会议纪要、行动项、持续目标、双方承诺和知识库，并通过已绑定的微信 ClawBot 支持会前准备与会后问答。

本仓库为原前端 `jqz_dev` 的工程快照，包含此次确认纳入的本地修复。Dart 包名仍为 `yanshu`，现有应用标识保留为 `com.example.yanshu`，避免影响既有签名与 TestFlight 应用。

配套服务：[Agenote-server](https://github.com/bandu111/Agenote-server)。

## 功能与场景

| 场景 | 已有能力 |
| --- | --- |
| 开始会议 | 选择手机麦克风、已连接 AI Voice 或可用蓝牙音源；实体录音键联动当前会议 |
| 会中记录 | 腾讯云实时 ASR V2、发言分段、行业术语解释、重点标注、风险和信息补全、疑问标记 |
| 会后回顾 | 整理状态页、AI 纪要、可缩放思维导图、逐字稿、原声回放和时间戳依据 |
| 跟进事项 | 首页“任务与会议”、日期筛选、任务完成与撤回、纪要后续行动同步、本周节奏 |
| 目标与承诺 | 目标确认、里程碑、跨会议明确续接、承诺补全/确认/履约状态及来源关联 |
| 管理资料 | 文件及文本导入、文件夹、检索、资料改名和删除、会议纪要归档、AI 引用 |
| 管理设备 | BLE 扫描、添加与本地设备记录、昵称、电量、容量、固件、SN 和录音状态 |
| 个人设置 | 注册、登录、个性化资料、职业、主题、权限、声纹注册与管理 |
| 微信助手 | 每个账号独立扫码绑定、推送偏好、职业报告与 PDF；全局会议/知识库问答主要在微信中进行 |

### 使用规则

- 会议不足 1 分钟时不新建 AI 纪要；录音与逐字稿的保存状态独立处理。
- 已结束且完成纪要归档的会议，后端对满 3 分钟的会议启用自动职业报告规则；生成和发送仍依赖授权、配额、有效证据及微信会话。
- 会议陈述进度不等于独立核验完成；未明确的信息保留待确认状态。
- 会前准备需要已确认且有效的未来会议，并由后端调度。普通问答成功不代表定时提醒已验收。
- 录音卡离线文件写入、文件同步和 OTA 不作为本阶段已开放能力；隐藏的历史代码不代表可用入口。

## 开发环境

- Flutter **3.44.1** / Dart **3.12.1**（与 iOS 工作流一致）。
- Android SDK、JDK 和已开启调试的 Android 设备。
- iOS 构建需要 macOS、工作流所指定的 Xcode，以及正确的证书和描述文件。
- Git LFS：仓库内有 LFS 管理的模型资源。SDK 与模型来源说明保留在对应资源目录。

```bash
git clone https://github.com/bandu111/Agenote-app.git
cd Agenote-app
git lfs install
git lfs pull
flutter pub get
```

## 运行

### 云端后端

```bash
flutter run --flavor cloud --target lib/main.dart --dart-define-from-file=config/cloud.json
```

`config/cloud.json` 保存环境和服务地址，不存服务端模型密钥。开发者应根据自己的部署调整 `YANSHU_API_BASE_URL`。

### 本地后端

```bash
flutter run --flavor local --target lib/main.dart --dart-define-from-file=config/local.json
```

Android USB 调试可先执行 `adb reverse tcp:8001 tcp:8001`。iOS 真机使用能访问电脑的局域网地址，修改本地配置中的后端 URL；手机上的 `127.0.0.1` 指向手机自身。

本地后端与本地语音引擎是不同配置：当前 `config/local.json` 仍选择腾讯云 ASR，因此本地服务也要配置腾讯凭据。环境、账号令牌及业务缓存按现有隔离规则保存。

## 工程结构

```text
lib/app/                 应用入口、路由、主题与本地化
lib/core/                网络与基础设施
lib/features/home/       首页、任务、会议与本周节奏
lib/features/meeting/    实时会议、逐字稿、纪要与证据回放
lib/features/progress/   目标、承诺和里程碑
lib/features/knowledge/  知识库
lib/features/recording_device/  AI Voice 设备与会议联动
lib/features/work_assistant/   微信绑定、偏好和成果展示
lib/features/voiceprint/       声纹流程
assets/                  本地图片、字体、术语词典与语音资源
android/、ios/            原生桥接、权限与系统录音状态
test/、integration_test/  单元、Widget 和设备测试
tool/ci/                 iOS 签名、导出与 Apple 状态核对脚本
.github/workflows/       IPA 构建及 TestFlight 上传
```

## 检查与测试

```bash
flutter analyze
flutter test
python tool/check_soninote_sdk.py
```

按模块验证示例：

```bash
flutter test test/progress_page_test.dart test/goal_topology_test.dart
flutter test test/meeting_minutes_test.dart test/meeting_archive_failure_isolation_test.dart
flutter test test/meeting_pending_completion_test.dart test/knowledge_view_model_test.dart
flutter test test/work_assistant_test.dart
```

自动测试不替代硬件验收。Android/iOS 应分别检查权限、真实音源、实体键开始/结束、断线重连、前后台、锁屏与录音回放。iOS 的 Live Activities 和 Android 的厂商实时状态展示取决于系统版本、授权和设备支持。

## 构建与 TestFlight

Android APK：

```bash
flutter build apk --release --flavor cloud --target lib/main.dart --dart-define-from-file=config/cloud.json
```

iOS 已保留两个工作流：

| 文件 | 用途 |
| --- | --- |
| `.github/workflows/dart.yml` | 构建签名 IPA，可选择上传 App Store Connect / TestFlight |
| `.github/workflows/testflight-upload.yml` | 上传指定构建运行产生的现有 IPA |

新 GitHub 仓库需要单独设置 Actions Secrets，旧仓库的 Secrets 不会随代码迁移：

| Secret | 内容 |
| --- | --- |
| `P12_BASE64` | 分发证书和匹配私钥组成的 P12 文件 Base64 |
| `P12_PASSWORD` | 对应 P12 密码 |
| `MOBILEPROVISION_BASE64` | Runner 的 App Store 描述文件 Base64 |
| `RECORDING_MOBILEPROVISION_BASE64` | 录音 Live Activity 扩展对应的描述文件 Base64 |
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_PRIVATE_KEY` | App Store Connect P8 私钥全文 |

工作流沿用现有团队、Bundle ID 和扩展签名逻辑。跨仓库沿用同一个 App 时，请填写高于已上传版本的 `build_number`，避免新仓库运行序号从头计数导致版本重复。

```bash
gh workflow run dart.yml --repo bandu111/Agenote-app --ref main -f upload_testflight=true -f build_number=你的新构建号
```

Apple 上传成功、处理成功和测试员可安装是不同状态。工作流会查询处理状态，但不会自动申请公开外部测试、邀请测试员或修改 App 商店描述。

## 仓库范围

保留 Flutter 工程、资产、测试、平台桥接、SDK 许可和构建必需脚本。原型 ZIP、个人笔记、Agent 交接文档、日志、构建产物、签名材料、真实用户录音和服务器凭据不进入本仓库。不要提交 `.env`、私钥或签名证书。
