package com.example.contact_importer_flutter

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
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 被杀后尽量由系统重建，继续保活。
        return START_STICKY
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
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pi = PendingIntent.getActivity(
            this, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_call)
            .setContentTitle("来电名片运行中")
            .setContentText("保持后台常驻，来电时才能及时弹出名片（可在来电显示设置中关闭）")
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pi)
            .build()
    }
}
