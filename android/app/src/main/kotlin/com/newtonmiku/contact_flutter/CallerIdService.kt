package com.newtonmiku.contact_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 来电名片常驻前台服务：**只为保活**——让进程在用户从最近任务划掉后仍尽量存活，
 * 从而保证 [PhonebookApp] 里动态注册的响铃接收器不被系统冻结/回收，来电时能及时弹名片。
 *
 * 不承载任何业务逻辑（匹配、通知仍由 [CallerIdReceiver]/[CallerId] 负责）。
 * 用户可在「来电显示」设置页关闭（默认开启），关闭后即停止本服务。
 */
class CallerIdService : Service() {

    companion object {
        private const val CHANNEL_ID = "caller_id_keepalive"
        private const val NOTIFICATION_ID = 0xC012

        /** 启动常驻服务（已在运行则幂等）。后台启动受系统限制，调用方需自行捕获异常。 */
        fun start(c: Context) {
            val intent = Intent(c, CallerIdService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                c.startForegroundService(intent)
            } else {
                c.startService(intent)
            }
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, CallerIdService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        // 后台启动前台服务在 Android 12+ 可能不被允许（ForegroundServiceStartNotAllowedException）。
        // 这里必须兜住：否则异常会让「服务创建失败」升级成主线程 FATAL、整个进程崩溃，
        // 再叠加 START_STICKY 被系统反复拉起，就变成“屡次闪退”的循环。
        try {
            ensureChannel()
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            // 不允许就安静退出；需要时常驻会由 MainActivity.onResume 在前台重新拉起。
            runCatching { stopSelf() }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 不用 START_STICKY：系统会在后台重建服务，而那时不允许 startForeground，
        // 会反复触发上面的异常路径。改为需要时由 App 在前台（onResume）自行拉起。
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "来电名片常驻",
                NotificationManager.IMPORTANCE_LOW // 静默、不出横幅
            ).apply {
                description = "保持来电名片在后台运行，来电时才能及时弹出"
                setShowBadge(false)
            }
        )
    }

    private fun buildNotification(): Notification {
        // 点击通知：直接打开「来电显示」设置页（关常驻的开关就在那一页），而不是只回首页。
        val open = Intent(this, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_ROUTE, MainActivity.ROUTE_CALLER_ID_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pi = PendingIntent.getActivity(
            this, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // 通知上的「关闭常驻」按钮：一键停服务并关掉开关（显式广播给本应用的接收器）。
        val stop = PendingIntent.getBroadcast(
            this, 1,
            Intent(this, CallerIdReceiver::class.java)
                .setAction(CallerId.ACTION_STOP_KEEPALIVE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_call)
            .setContentTitle("来电名片运行中")
            .setContentText("点击可打开「来电显示」设置关闭本常驻通知")
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pi)
            .addAction(0, "关闭常驻", stop)
            .build()
    }
}
