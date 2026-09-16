import 'dart:io';

import 'package:flutter/foundation.dart';

import 'update_download.dart';

/// Windows 应用内更新：下载 zip → 解压 → 退出应用 → 脚本替换文件 → 重启。
///
/// 为什么非得借一个脚本：Windows 上**正在运行的 exe 无法被覆盖**。
/// 所以只能是"应用先退出，脚本再动手"；脚本第一件事是等本进程的 PID 消失。
///
/// 解压为什么放在 Dart 里（而不是也丢给脚本）：
/// 替换动作一旦开始，应用已经退出了——此时才发现压缩包是坏的，
/// 用户就只剩一个半残的安装目录。所以解压与内容校验必须在应用还活着时做完，
/// 出问题就当作"应用内更新失败"，正常回退浏览器下载。
///
/// 解压用系统的 PowerShell `Expand-Archive`，不额外引入 zip 依赖。
class WindowsInstaller {
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 更新暂存根目录：`%TEMP%\contact_flutter_update`
  static Directory get _root =>
      Directory('${Directory.systemTemp.path}${Platform.pathSeparator}contact_flutter_update');

  /// 当前安装目录（与 exe 同级）。
  static Directory get installDir => File(Platform.resolvedExecutable).parent;

  /// Windows 包里的主程序名（与 CMake 的 BINARY_NAME 一致）。
  static const _exeName = 'contact_flutter.exe';

  /// 下载并解压到暂存目录，返回解压后的目录。
  ///
  /// 失败一律抛 [UpdateException]，调用方据此回退浏览器下载。
  static Future<Directory> prepare(
    String url, {
    required String versionName,
    void Function(double? progress)? onProgress,
  }) async {
    if (!isSupported) throw const UpdateException('当前平台不支持应用内更新');
    _cleanRoot();

    final stage = Directory('${_root.path}${Platform.pathSeparator}$versionName');
    stage.createSync(recursive: true);

    final zip = File('${stage.path}${Platform.pathSeparator}update.zip');
    await UpdateDownload.download(url, zip, onProgress: onProgress);

    final out = Directory('${stage.path}${Platform.pathSeparator}extracted');
    await _extract(zip, out);

    // 解压结果必须真的是本应用：拿一个不相干的压缩包去覆盖安装目录是灾难性的
    if (!File('${out.path}${Platform.pathSeparator}$_exeName').existsSync()) {
      throw const UpdateException('更新包内容异常：里面没有 $_exeName');
    }
    return out;
  }

  /// 安装目录当前可写吗？
  ///
  /// 放在 Program Files 之类的受保护位置时自替换必然失败，而且失败发生在应用
  /// 已经退出之后——所以提前探一下，不可写就老实回退浏览器让用户手动解压。
  static void ensureWritable() {
    final probe = File('${installDir.path}${Platform.pathSeparator}.update_probe');
    try {
      probe.writeAsStringSync('probe');
      probe.deleteSync();
    } catch (_) {
      throw UpdateException(
        '安装目录不可写（${installDir.path}），请下载更新包后手动解压覆盖',
      );
    }
  }

  /// 生成更新脚本并【脱离】启动它。调用方随后应立即退出应用。
  ///
  /// 返回脚本路径，便于日志与排查。
  static Future<String> applyAndRestart(
    Directory extracted, {
    required String versionName,
  }) async {
    ensureWritable();
    final script = File('${_root.path}${Platform.pathSeparator}apply_$versionName.cmd');
    // 批处理必须是 CRLF：LF 结尾的 .bat/.cmd 在 goto/标签上会出诡异问题
    script.writeAsStringSync(
      _script(extracted).replaceAll('\n', '\r\n'),
      flush: true,
    );
    await Process.start(
      'cmd.exe',
      ['/c', script.path],
      mode: ProcessStartMode.detached,
    );
    return script.path;
  }

  /// 清理上一次留下的暂存文件（下次更新开始时调用）。
  static void _cleanRoot() {
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    } catch (_) {
      // 清不掉就复用，不影响本次更新
    }
    _root.createSync(recursive: true);
  }

  /// 解压 zip 到 [out]（PowerShell Expand-Archive）。
  static Future<void> _extract(File zip, Directory out) async {
    out.createSync(recursive: true);
    final cmd = 'Expand-Archive -LiteralPath ${_psQuote(zip.path)} '
        '-DestinationPath ${_psQuote(out.path)} -Force';
    final ProcessResult r;
    try {
      r = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
      );
    } catch (e) {
      throw UpdateException('解压失败：$e');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      throw UpdateException('解压失败${err.isEmpty ? '' : '：$err'}');
    }
  }

  /// PowerShell 单引号字面量：内部的 `'` 要写成 `''`。
  static String _psQuote(String p) => "'${p.replaceAll("'", "''")}'";

  /// 更新脚本正文。
  ///
  /// 流程：等本进程 PID 消失（最多 120 秒）→ robocopy 覆盖 → 重启 → 删暂存目录。
  /// 注意这里刻意不用 `if (...)` 括号块：cmd 在解析整个块时就会展开 `%N%`，
  /// 计数器会永远停在初始值，变成死循环。逐行的 `if ... goto` 才安全。
  static String _script(Directory extracted) {
    final dst = installDir.path;
    final exe = '$dst${Platform.pathSeparator}$_exeName';
    final stage = extracted.parent.path;
    return '''
@echo off
setlocal enableextensions
set "SRC=${extracted.path}"
set "DST=$dst"
set "EXE=$exe"
set "STAGE=$stage"
set "PID=$pid"
set /a N=0
:wait
tasklist /FI "PID eq %PID%" /NH 2>NUL | findstr /C:"%PID%" >NUL
if errorlevel 1 goto :copy
set /a N+=1
if %N% GEQ 120 goto :copy
timeout /t 1 /nobreak >NUL
goto :wait
:copy
robocopy "%SRC%" "%DST%" /E /IS /IT /R:3 /W:1 /NFL /NDL /NJH /NJS >NUL
cd /d "%DST%"
start "" "%EXE%"
rmdir /s /q "%STAGE%" 2>NUL
exit /b
''';
  }
}
