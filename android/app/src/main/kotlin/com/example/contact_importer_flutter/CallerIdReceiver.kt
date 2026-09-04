package com.example.contact_importer_flutter

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.CallLog
import android.telephony.TelephonyManager

/**
 * 来电监听（manifest 注册，进程未运行也能收到）。
 * - 响铃：取号 → 在本地通讯录缓存里匹配 → 命中才发全屏名片；
 *   只显示通讯录里的人，陌生号码不打扰。
 * - 接通/挂断：收起名片。
 *
 * 注意：Android 10+ 出于隐私，响铃广播默认不再携带号码；有 READ_CALL_LOG
 * 时先用广播里的号码（多数机型有该权限即可拿到），拿不到则稍候补读通话记录。
 */
class CallerIdReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        if (!CallerId.isEnabled(context)) return

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> handleRinging(context, intent)
            TelephonyManager.EXTRA_STATE_OFFHOOK,
            TelephonyManager.EXTRA_STATE_IDLE -> CallerId.dismiss(context)
        }
    }

    private fun handleRinging(context: Context, intent: Intent) {
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.trim().orEmpty()
        if (number.isNotEmpty()) {
            showIfKnown(context, number)
            return
        }

        // 广播没带号：延后约 1.2s 读一次通话记录再补显（行此刻多半已落库）。
        if (CallerId.granted(context, Manifest.permission.READ_CALL_LOG)) {
            val pending = goAsync() // 延长进程存活，保证后台线程完成
            Thread {
                try {
                    Thread.sleep(1200)
                } catch (_: InterruptedException) {
                }
                val n = latestIncomingNumber(context)
                if (!n.isNullOrEmpty()) showIfKnown(context, n)
                pending.finish()
            }.start()
        }
    }

    /** 命中才显示；陌生号码不发任何东西。 */
    private fun showIfKnown(context: Context, number: String) {
        if (!CallerId.canPostNotifications(context)) return
        val hit = CallerId.match(context, number) ?: return
        CallerId.showIncoming(context, number, hit)
    }

    /** 最近 60s 内、有号码、未接（RINGING 期间先落库的来电行）。 */
    private fun latestIncomingNumber(context: Context): String? {
        if (!CallerId.granted(context, Manifest.permission.READ_CALL_LOG)) return null
        val now = System.currentTimeMillis()
        val cursor = context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DATE),
            null,
            null,
            CallLog.Calls.DATE + " DESC"
        ) ?: return null
        cursor.use {
            while (it.moveToNext()) {
                val date = it.getLong(2)
                if (now - date > 60_000) break // 记录按时间倒序，更早的不用看了
                if (it.getInt(1) != CallLog.Calls.INCOMING_TYPE) continue
                val n = it.getString(0)?.trim().orEmpty()
                if (usableNumber(n)) return n
            }
        }
        return null
    }

    private fun usableNumber(n: String): Boolean {
        if (n.isEmpty()) return false
        if (n.filter(Char::isDigit).length < 3) return false
        val lower = n.lowercase()
        return lower != "unknown" && lower != "restricted" && lower != "private" &&
            lower != "-1" && lower != "0" && !lower.contains("anonymous")
    }
}
