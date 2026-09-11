# contact_flutter — 通讯录客户端

县域单位通讯录的 Flutter 客户端（Android 手机端 + Windows 桌面端）。
功能：按单位分组浏览 / 拼音搜索 / 一键呼叫与短信 / 导出到系统通讯录 / **安卓来电显示名片** /
应用锁 / 设备激活（一次性激活码）与桌面端账号密码登录。

配套后端：`phonebook-server`（Go + SQLite，含 Vue 管理页）。默认服务器 `https://你的服务器`。

## 应用包名与「发布线」

Android 的**安装身份**（`applicationId`）由「基础包名 + 可选后缀」拼成，后缀在**构建时**注入：

| 场景 | applicationId |
|---|---|
| 未设置后缀（默认线） | `com.newtonmiku.contact_flutter` |
| 设置 `APP_ID_SUFFIX=_demo`（自定义后缀） | `com.newtonmiku.contact_flutter_demo` |

- 代码里的 Kotlin 包名 / `namespace` / MethodChannel 名固定为 `com.newtonmiku.contact_flutter`，
  **不随后缀变化**（`namespace` 是编译期标识，与安装身份相互独立）。
- 后缀由环境变量 `APP_ID_SUFFIX` 提供，`android/app/build.gradle.kts` 读取：
  `applicationId = "com.newtonmiku.contact_flutter" + System.getenv("APP_ID_SUFFIX")`。

> ⚠️ **后缀不同 = 设备上视为两个不同的 App**：不能互相覆盖安装，激活状态、应用锁密码、
> 本地缓存都不通用。切换发布线时需要卸载重装，并重新用激活码激活。

## 本地构建

```bash
flutter pub get

# Android（自定义后缀，发布用）
APP_ID_SUFFIX=_demo flutter build apk --release \
  --dart-define=API_BASE_URL=https://你的服务器 \
  --dart-define=APP_VERSION=$(git rev-parse --short HEAD) \
  --dart-define=BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Android（默认线，不带后缀）
flutter build apk --release --dart-define=API_BASE_URL=https://你的服务器

# Windows 桌面端（包名后缀只影响 Android，桌面端无需该变量）
flutter build windows --release --dart-define=API_BASE_URL=https://你的服务器
```

产物：`build/app/outputs/flutter-apk/app-release.apk`、`build/windows/x64/runner/Release/`。

验证 APK 的安装身份：

```bash
aapt dump badging build/app/outputs/flutter-apk/app-release.apk | grep ^package
```

## 发布签名

Android 正式包使用**固定的发布密钥**签名（不再用 Flutter 默认的 debug 测试签名），
这样同一个 `applicationId` 的新版本可以直接**覆盖安装**，不会丢激活状态与本地数据。

| 文件 | 位置 | 是否入库 |
|---|---|---|
| 密钥库 | `android/release.jks`（PKCS12） | ❌ 已 gitignore |
| 签名配置 | `android/key.properties` | ❌ 已 gitignore |

`android/key.properties` 内容：

```properties
storeFile=release.jks
storePassword=******
keyAlias=phonebook
keyPassword=******
```

**规则**：

- 本机打包自动读取该文件 → 用发布密钥签名；
- CI 由 workflow 用**单个 Secret** `SIGNING_BUNDLE_BASE64` 还原出同样的两个文件；
- 打包成一个文件（离线备份 + 填 Secret 用）：

  ```bash
  bash tool/pack_signing.sh          # 生成 ../_private/contact_flutter-signing.bundle
  cat ../_private/contact_flutter-signing.bundle   # 全文本粘贴到 Secret
  ```

  该 bundle 就是密钥的全部：**把它和密码一起离线保存**（丢了就无法再发升级包）。
- **未配置时 release 打包会直接失败并提示**，绝不会静默退回测试签名（debug 构建不受影响）。

> ⚠️ **务必备份 `release.jks` 与两个密码**（建议存到密码管理器 + 离线副本）。
> 密钥一旦丢失，**所有已装设备都无法再收到升级包**（只能卸载重装，且激活要重新发码）。
> 证书指纹（SHA-256）：`4F:2C:68:5B:D9:DA:97:12:BB:26:61:DE:86:B1:F4:37:79:EC:91:3D:D9:3A:CA:9F:CF:4A:5C:D5:A6:66:D4:74`

### 换签名密钥的正确做法（将来如果要换）

不能直接换——签名不同 = 系统拒绝覆盖安装，必须卸载重装（丢数据）。
若确实要换，走 **Play 应用签名 / 密钥轮换** 或对存量设备做一次「卸载重装」的过渡。

### 首次安装与版本号

- 因为 `applicationId` 曾调整过，**旧包要先卸载一次**；此后同 `applicationId` + 同密钥即可一路覆盖升级；
- 每次发版建议递增 `pubspec.yaml` 的 `version`（`1.0.0+10000` 里的 `+10000` 即 versionCode，规则见文件注释）。

## 持续集成

`.github/workflows/build.yml`：push 到 `main` 或手动触发时，先跑 `analyze` + `test`，
再并行出 Android APK 与 Windows x64 包，产物在 Actions 运行页下载。

需要在仓库里配置（Settings → Secrets and variables → Actions）：

| 名称 | 类型 | 说明 |
|---|---|---|
| `API_BASE_URL` | **Secret** | 后端地址，如 `https://你的服务器`；未配置则构建失败 |
| `APP_ID_SUFFIX` | **Variable** | 包名后缀，如 `_demo`；**未配置 = 默认线（无后缀）** |
| `SIGNING_BUNDLE_BASE64` | **Secret** | 发布签名打包文件全文（`release.jks` + `key.properties` 的 tar.gz 再 base64），运行 `bash tool/pack_signing.sh` 生成 |

不同分支要出不同发布线时：给分支配置各自的变量/Environment，或手动触发时在
`app_id_suffix` 输入框里临时指定（该输入优先于仓库变量）。

## 相关

- 客户端本地存储：`shared_preferences`（设备令牌、应用锁、设置）+ 原生 `contacts_lookup.json`（来电匹配号码库）。
- 手机端登录：一次性激活码（扫码或手输）；桌面端登录：账号密码。
- 文档见上层目录 `docs/`；服务端与部署见 `../phonebook-server`、`../deploy`。
