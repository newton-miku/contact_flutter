package com.newtonmiku.contact_flutter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新：把已下载到应用私有目录的 APK 交给系统安装器。
 *
 * 为什么不直接把下载链接丢给浏览器：
 *   应用内下载能显示进度、失败可重试，体验更完整；浏览器跳转退化为兜底手段。
 *
 * 为什么用 FileProvider：
 *   Android 7+ 直接把 file:// 传给别的应用会抛 FileUriExposedException，
 *   必须走 content:// 并临时授权。
 */
object ApkInstaller {

    const val CHANNEL = "com.newtonmiku.contact_flutter/apk_installer"

    /** 下载目录名，需与 res/xml/file_paths.xml 中的声明一致。 */
    private const val DIR_NAME = "apk_downloads"

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "downloadDir" -> {
                val dir = downloadDir(context)
                if (dir == null) {
                    result.error("NO_DIR", "无法创建下载目录", null)
                } else {
                    result.success(dir.absolutePath)
                }
            }

            "install" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("BAD_ARGS", "缺少 path 参数", null)
                    return
                }
                try {
                    install(context, File(path))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_FAILED", e.message ?: "安装失败", null)
                }
            }

            // Android 8+ 允许安装未知来源应用是按「来源应用」授权的；
            // 未授权时系统安装器会直接拒绝，需要引导用户去开。
            "canRequestInstall" -> {
                val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.packageManager.canRequestPackageInstalls()
                } else {
                    true
                }
                result.success(ok)
            }

            "openInstallPermissionSettings" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        data = Uri.parse("package:${context.packageName}")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(intent)
                }
                result.success(true)
            }

            // 发布时会同时挂两个包：默认包（arm+arm64）与 x86_64 包（模拟器用）。
            // 给 x86 模拟器下发 arm 包会直接装不上，所以要按设备 ABI 挑。
            "supportedAbis" -> {
                result.success(Build.SUPPORTED_ABIS?.toList() ?: emptyList<String>())
            }

            else -> result.notImplemented()
        }
    }

    /** 应用专属外部目录，卸载时随应用一起清理，无需任何存储权限。 */
    private fun downloadDir(context: Context): File? {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        val dir = File(base, DIR_NAME)
        if (!dir.exists() && !dir.mkdirs()) return null
        return dir
    }

    private fun install(context: Context, apk: File) {
        require(apk.exists()) { "安装包不存在：${apk.name}" }
        val uri: Uri = FileProvider.getUriForFile(
            context, "${context.packageName}.fileprovider", apk
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // 部分 ROM 只有显式指定包名才愿意接管安装
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        context.startActivity(intent)
    }
}
