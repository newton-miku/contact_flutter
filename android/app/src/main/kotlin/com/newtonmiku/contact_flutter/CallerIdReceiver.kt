package com.newtonmiku.contact_flutter

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
        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)

        // 无论开关是否开启都先落一条记录：区分「没收到广播」和「收到但开关没开」。
        // （模拟测试不走这条路径，所以此前开关关闭时“模拟能弹、真来电无记录”。）
        if (!CallerId.isEnabled(context)) {
            val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.trim().orEmpty()
            CallerId.recordPhoneEvent(
                context, state ?: "?", number,
                "「开启来电显示」开关未打开，已忽略（打开后才有名片）"
            )
            return
        }

        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> handleRinging(context, intent)
            TelephonyManager.EXTRA_STATE_OFFHOOK,
            TelephonyManager.EXTRA_STATE_IDLE -> {
                CallerId.dismiss(context)
                // 记录一次事件：证明 receiver 被系统唤醒了（诊断“开了没反应”的关键证据）。
                // 若刚记录过本通响铃的结论（命中/陌生/取号失败），不覆盖它，方便事后查看。
                val lastAt = CallerId.lastPhoneEvent(context)?.get("at") as? Long ?: 0L
                if (System.currentTimeMillis() - lastAt > 180_000L) {
                    CallerId.recordPhoneEvent(context, state, "", "已接通/挂断，名片收起")
                }
            }
        }
    }

    /** 返回给“来电事件记录”的结论文案，说明这一通为什么弹/为什么不弹。 */
    private fun handleRinging(context: Context, intent: Intent) {
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.trim().orEmpty()
        if (number.isNotEmpty()) {
            CallerId.recordPhoneEvent(context, "RINGING", number, showIfKnown(context, number))
            return
        }

        // 广播没带号（Android 9+/座机来电常见）：响铃期间持续轮询通话记录补显。
        // 通话记录往往在响铃开始片刻后才落库，单次读取容易落空，故轮询最多约 8s。
        if (CallerId.granted(context, Manifest.permission.READ_CALL_LOG)) {
            val pending = goAsync() // 延长进程存活，保证后台线程完成
            Thread {
                val deadline = System.currentTimeMillis() + 8000
                var resolved = false
                while (!resolved && System.currentTimeMillis() < deadline) {
                    val n = latestIncomingNumber(context)
                    if (!n.isNullOrEmpty()) {
                        val decision = showIfKnown(context, n)
                        CallerId.recordPhoneEvent(context, "RINGING", n, decision)
                        resolved = true
                    } else {
                        try {
                            Thread.sleep(600)
                        } catch (_: InterruptedException) {
                            break
                        }
                    }
                }
                if (!resolved) {
                    CallerId.recordPhoneEvent(
                        context, "RINGING", "",
                        "广播未带号码，响铃期间通话记录也未取到（号码未知或被拦截）"
                    )
                }
                pending.finish()
            }.start()
            return
        }
        CallerId.recordPhoneEvent(
            context, "RINGING", "",
            "广播未带号码，且未授予“电话/通话记录”权限，无法取号"
        )
    }

    /** 命中才显示；陌生号码不发任何东西。返回是否已弹名片的说明文字。 */
    private fun showIfKnown(context: Context, number: String): String {
        if (!CallerId.canPostNotifications(context)) {
            return "通知未开启，名片无法弹出"
        }
        val hit = CallerId.match(context, number) ?: return "陌生号码（号码库未命中），按设计不显示"
        CallerId.showIncoming(context, number, hit)
        return "命中「${hit.name}」，已弹全屏名片"
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
