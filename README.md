# contact_flutter — 通讯录客户端

县域单位通讯录的 Flutter 客户端（Android 手机端 + Windows 桌面端）。
功能：按单位分组浏览 / 拼音搜索 / 一键呼叫与短信 / 导出到系统通讯录 / **安卓来电显示名片** /
应用锁 / 设备激活（一次性激活码）与桌面端账号密码登录。

配套后端：`phonebook-server`（Go + SQLite，含 Vue 管理页）。
**服务器地址不入库**：构建时由 `API_BASE_URL` 注入（CI 用 Secret，见「持续集成」）。

## 本地构建

```bash
flutter pub get
```

### Android APK

用 `tool/build_apk.sh`：自动注入版本号与构建时间，按 ABI 拆包，产物落到 `../_release/`。

```bash
# 默认包：armeabi-v7a + arm64-v8a —— 手机装这个
API_BASE_URL=https://你的服务器 bash tool/build_apk.sh

# 顺带再出一个 x86_64 包（模拟器用，文件名带 _x86_64 后缀）
API_BASE_URL=https://你的服务器 bash tool/build_apk.sh --x86
```

| 产物 | 含 ABI | 用途 |
|---|---|---|
| `_release/contact_flutter.apk` | armeabi-v7a + arm64-v8a | 手机分发（默认包） |
| `_release/contact_flutter_x86_64.apk` | x86_64 | 模拟器（加 `--x86` 才有） |

等价的手写命令：

```bash
flutter build apk --release --target-platform android-arm,android-arm64 \
  --dart-define=API_BASE_URL=https://你的服务器 \
  --dart-define=APP_VERSION=$(git rev-parse --short HEAD) \
  --dart-define=BUILD_TIME=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# 只含 x86_64 的包（产物同名 app-release.apk，自己拷出来改名）
flutter build apk --release --target-platform android-x64 \
  --dart-define=API_BASE_URL=https://你的服务器
```

> ABI 由 `--target-platform` 决定：`android/app/build.gradle.kts` 据此设置 `abiFilters`，
> 默认包里不会混进第三方插件（ML Kit 等）的 x86_64 原生库。

### Windows 桌面端

```bash
flutter build windows --release --dart-define=API_BASE_URL=https://你的服务器
```

产物：`build/windows/x64/runner/Release/`。

## 安装身份（applicationId）

安装身份为 `com.newtonmiku.contact_flutter`，可用环境变量 `APP_ID_SUFFIX` 追加后缀（构建时注入）：

```bash
APP_ID_SUFFIX=_demo flutter build apk --release ...   # → com.newtonmiku.contact_flutter_demo
```

- 代码里的 Kotlin 包名 / `namespace` / MethodChannel 名固定为 `com.newtonmiku.contact_flutter`，不随后缀变化；
- **后缀不同 = 设备上视为两个 App**：不能互相覆盖安装，激活状态、应用锁、本地缓存都不通用；
- 核对产物的安装身份：`aapt dump badging <apk> | grep ^package`。

## 发布签名

正式包用**固定的发布密钥**签名（不是 Flutter 默认的 debug 测试签名），
因此同一个 `applicationId` 的新版本可以直接**覆盖安装**，不丢激活状态与本地数据。

| 文件 | 位置 | 是否入库 |
|---|---|---|
| 密钥库 | `android/release.jks` | ❌ 已 gitignore |
| 签名配置 | `android/key.properties`（storeFile / storePassword / keyAlias / keyPassword） | ❌ 已 gitignore |

- 本机打包自动读取 `android/key.properties` → 用发布密钥签名；
- CI 用**单个 Secret** `SIGNING_BUNDLE_BASE64` 还原出这两个文件，本地用 `bash tool/pack_signing.sh` 生成；
- **未配置时 release 打包会直接失败并提示**，绝不静默退回测试签名（debug 构建不受影响）。

> ⚠️ 密钥与两个密码务必离线备份：一旦丢失，所有已装设备都无法再收到升级包。

## 持续集成

`.github/workflows/build.yml`：push 到 `main` 或手动触发时，先跑 `analyze` + `test`，
再出 Android APK 与 Windows x64 包，产物在 Actions 运行页下载。

| artifact | 内容 |
|---|---|
| `contact_flutter_apk_arm` | `contact_flutter.apk`（armeabi-v7a + arm64-v8a） |
| `contact_flutter_apk_x86_64` | `contact_flutter_x86_64.apk`（x86_64，模拟器用） |
| `contact_flutter_windows_x64` | Windows x64 目录内容，解压即用 |

打 tag（如 `v1.0.0`）推送时会额外创建 Release：`contact_flutter_v1.0.0.apk`、
`contact_flutter_v1.0.0_x86_64.apk`、`contact_flutter_windows_x64_v1.0.0.zip`（均为单层，下载即用）。

仓库需配置（Settings → Secrets and variables → Actions）：

| 名称 | 类型 | 说明 |
|---|---|---|
| `API_BASE_URL` | **Secret** | 后端地址；未配置则构建失败 |
| `SIGNING_BUNDLE_BASE64` | **Secret** | 发布签名打包文件全文（`bash tool/pack_signing.sh` 生成） |
| `APP_ID_SUFFIX` | **Variable** | 可选，安装身份后缀；未配置 = 无后缀 |

Flutter 版本在 workflow 里钉定（`3.44.8`），升级时改那里并保持与本机一致。

## 客户端数据同步

- 启动 / 下拉刷新先展示**本地缓存**，再请求轻量接口 `GET /api/version`（几十字节）；
- 版本号一致 → 直接用缓存；不一致 → 拉 `GET /api/contacts` 全量（gzip）并写回缓存；
- 连不上服务器 → 回退本地缓存并在标题栏标注「离线」。
