# linux-uos 编译说明

本包是 **contact_flutter 的 `linux-uos` 分支快照**（提交号见压缩包文件名
`contact_flutter-linux-uos-<sha>.zip`），用于在
**UOS Desktop 20 Professional** 上打 Linux `.deb`。

包内是**完整源码**，不需要 git 也能直接编译。

---

## 为什么单独一条线

Flutter 的 Linux 桌面引擎是**预编译产物**，它自己链的 glibc 决定了产物能跑在哪。

```
Flutter 3.10.x 之前 / 含 3.10.x  →  glibc 2.28 可跑
Flutter 3.10.x 之后              →  要求 glibc ≥ 2.31
UOS Desktop 20（Debian 10 底子）  →  glibc 2.28
```

所以这条线固定在 **Flutter 3.10.6**（自带 **Dart 3.0.6**）。

> ⚠️ **本包的 `pubspec.yaml` 与 `pubspec.lock` 是降级版，不要与主线互相照抄。**
> `pubspec.yaml` 里写了 `flutter: ">=3.10.0 <3.11.0"`，用更新的 SDK 会在
> `pub get` 阶段就被拦下——这是故意的，免得编出装不上的包。

---

## 一、装 Flutter 3.10.6

```bash
cd ~
curl -LO https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_3.10.6-stable.tar.xz
tar xf flutter_linux_3.10.6-stable.tar.xz        # 解出 ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter --version                                 # 必须显示 3.10.6
```

国内网络建议加上镜像（Flutter 首次运行要下引擎产物）：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

---

## 二、拉依赖

```bash
cd contact_flutter
flutter pub get
```

应当输出 `Got dependencies!`。这一步会顺带校验 Flutter 版本是否落在 3.10.x。

---

## 三、打 deb

```bash
# arm64 机器（例如你这台 aarch64 的 UOS）：
TAG=v1.0.1 API_BASE_URL=https://pb.ddxnb.cn bash tool/build_deb.sh

# 也可以显式指定架构（必须与宿主一致，否则脚本直接报错）：
TAG=v1.0.1 API_BASE_URL=https://pb.ddxnb.cn bash tool/build_deb.sh --arch arm64
```

产物落在 **上一级目录** 的 `_release/`：
`../_release/contact_flutter_<版本名>_<架构>.deb`

### 脚本会自己拦三种情况（不满足直接拒绝）

| 检查 | 为什么 |
|---|---|
| Flutter 必须是 3.10.x | 更新的引擎要求 glibc ≥ 2.31，UOS 20 装不起来 |
| 不能有 `android/ ios/ macos/ windows/` 残留目录 | 见「常见问题」第 2 条 |
| `--arch` 必须与宿主一致 | Flutter 的 Linux 桌面版**不支持跨架构编译** |

---

## 四、安装与卸载

```bash
sudo dpkg -i contact_flutter_1.0.1_arm64.deb || sudo apt-get -f install
sudo dpkg -r contact-flutter          # 卸载（包名是 contact-flutter，不是文件名）
```

应用装到 `/opt/contact_flutter/`（自包含，Flutter 引擎与资源随包分发，
只依赖系统的 GTK3 运行库），命令入口软链到 `/usr/bin/contact_flutter`，
桌面条目在 `/usr/share/applications/contact_flutter.desktop`。

装完想确认到底落了哪些文件：

```bash
dpkg -L contact-flutter | grep -E 'bin/|applications|icons'
which contact_flutter                 # 应输出 /usr/bin/contact_flutter
contact_flutter                       # 命令行直接起，能起来说明包本身没问题
```

启动器里看不到图标时，先手动刷新一次缓存（`postinst` 里已做，但某些桌面
环境只在下次登录才重读）：

```bash
sudo update-desktop-database -q /usr/share/applications
sudo gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor
```

---

## 本快照相对主线改了哪些地方

全都是为了让 3.10 编得过、跑得起来，**不要把这些改动反向同步回主线**。

| 位置 | 改动 | 原因 |
|---|---|---|
| `pubspec.yaml` / `pubspec.lock` | 依赖整体降到 2023 年中的版本 | 主线钉的普遍要求 Dart ≥3.9，而 3.10.6 只有 3.0.6 |
| `pubspec.yaml` | 加 `flutter: ">=3.10.0 <3.11.0"` | 钉死 SDK |
| 若干 `lib/**.dart` | `withValues`→`withOpacity`；`surfaceContainerHighest/Lowest`→`surfaceVariant`/`surface`；`CardThemeData`→`CardTheme`；`LinearProgressIndicator.borderRadius`→外包 `ClipRRect`；`?x`（null-aware 元素）→`if (x != null) x` | 这些都是 3.10 之后才有的 API / 语法 |
| `linux/runner/my_application.cc` | 去掉 `"first-frame"` 信号与 `fl_view_set_background_color()`，窗口直接 `gtk_widget_show` | 3.10 两者都没有 |
| `linux/CMakeLists.txt` | 删掉 native assets 安装块 | 3.10 不产出 `build/native_assets/linux/`，`install(DIRECTORY)` 会在最后一步报 `cannot find` |
| `tool/build_deb.sh` | 产物路径改用 `arm64` / `x64`；加 Flutter 版本闸门与平台残留检查 | 见「常见问题」第 1、2 条 |
| `tool/build_deb.sh` | 图标改从 `packaging/linux/contact_flutter.png` 取；新增 `/usr/bin/contact_flutter` 软链 | 本分支没有 `android/`，原来只在 Android 的 `mipmap-*` 里找图标，必然找不到；应用装在 `/opt` 下而 `/opt` 不在 `PATH` 里，见「常见问题」第 7 条 |
| `packaging/linux/contact_flutter.desktop` | `Exec` 由 `contact_flutter` 改成绝对路径 `/opt/contact_flutter/contact_flutter` | 同上，`Exec` 里的命令找不到时，桌面环境会直接把整个条目藏起来 |
| `packaging/linux/contact_flutter.png` | 新增（256×256 应用图标） | 桌面条目 `Icon=contact_flutter` 的来源 |
| 平台目录 | 只保留 `linux/` | 3.10 的 `isUsingGradle` 只看 `build.gradle`、**不认 `.kts`**，留着 Android 工程会被误判成 v1 嵌入 |
| `.metadata` | 不再登记已删平台 | 免得 `flutter create/migrate` 去找不存在的平台 |

---

## 常见问题

### 1. `错误：未找到 build/linux/aarch64/release/bundle/contact_flutter`

本快照已修。根因有意思：**`uname` 与 Flutter 用的是两套架构命名**

```
uname -m          →  aarch64 / x86_64
Flutter 的目录名   →  arm64   / x64        ← build/linux/<这个>/
Debian 的架构字段  →  arm64   / amd64
```

脚本以前直接把 `uname -m` 拼进路径，两个架构都对不上。现在报错时还会列出
`build/linux/` 下实际有什么，并告诉你它期望的是哪个名字。

### 2. `requires your app to be migrated to the Android embedding v2`

**这不是 Android 问题**，本包根本没有 `android/` 工程。

原因：Flutter 3.10 的 `isUsingGradle` 只看 `android/build.gradle`（**不认 `.kts`**）。
磁盘上存在 `android/` 目录却没有那个文件时，它会判定"没用 Gradle"，
转去读 `android/AndroidManifest.xml`——文件不存在 → 判成 v1 嵌入 → 报上面那句。

处理：

```bash
rm -rf android ios macos windows
```

> 只有在"曾经在主线工作过、又切到这条线"的机器上才会遇到（那些目录里未跟踪的
> 残留会留下）。**全新解压本包不会有这个问题。**
> 若 `android/` 里有你自己的签名配置（`key.properties` / `release.jks`），删前先备份。

### 3. `use of undeclared identifier 'fl_view_set_background_color'`

本快照已修。根因见上表。

### 4. `file INSTALL cannot find ".../native_assets/linux/"`

本快照已修。根因见上表。

### 5. `Because contact_flutter requires SDK version ^3.12.2, version solving failed`

用成主线的 `pubspec.yaml` 了。本包内的是降级版，不要覆盖。

### 6. 编译时报缺少 GTK 开发包

```bash
sudo apt-get install -y libgtk-3-dev pkg-config clang cmake ninja-build
```

### 7. 装完以后启动器/菜单里找不到应用（连图标都没有）

`dpkg -i` 成功、`/opt/contact_flutter/` 也在，但菜单里空空如也。两个原因叠在一起：

1. **`Exec` 指不到命令。** 原来写的是 `Exec=contact_flutter`，而应用在
   `/opt/contact_flutter/contact_flutter`，`/opt/...` 不在 `PATH` 里，也没有软链。
   桌面环境检查 `Exec` 找不到可执行文件时，**会把整条目当无效项丢掉**——
   于是既没有菜单项，也谈不上图标。
2. **图标根本没进包。** 脚本原来只在 `android/app/src/main/res/mipmap-*/`
   里找 `ic_launcher.png`，而本分支没有 `android/`，只会打印
   `警告：没找到图标 png`。

现在两者都修了：`Exec` 用绝对路径、包内自带 `packaging/linux/contact_flutter.png`、
并额外装一条 `/usr/bin/contact_flutter` 软链。重打一次 deb 再装即可。

如果重装后仍然看不到，按顺序排查：

```bash
dpkg -L contact-flutter | grep desktop          # 条目到底装上没有
cat /usr/share/applications/contact_flutter.desktop | grep '^Exec='
/opt/contact_flutter/contact_flutter            # 直接跑，看是不是程序自身起不来
```

---

## 与主线的维护关系

- `main`：现代 Flutter（3.44.8），Android + Windows，有 GitHub Actions CI
- `linux-uos`：Flutter 3.10.6，**仅 Linux**，无 CI

两边**不合并**。主线修复如需同步过来，用 cherry-pick，
并注意上面那张表里的 API 差异要一并换回旧写法。
