package com.newtonmiku.contact_flutter

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
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

    private companion object {
        const val TAG = "CallerId"

        /** 补号线程是否在跑：部分 ROM 会重复投递响铃广播，避免叠加多个轮询线程。 */
        @Volatile
        private var polling = false
    }

    override fun onReceive(context: Context, intent: Intent) {
        val tRecv = android.os.SystemClock.elapsedRealtime()
        // 常驻通知上的「关闭常驻」：停服务并关闭开关（开关关了，onResume 也不会再拉起）。
        if (intent.action == CallerId.ACTION_STOP_KEEPALIVE) {
            CallerId.setKeepAlive(context, false)
            CallerIdService.stop(context)
            return
        }
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
            TelephonyManager.EXTRA_STATE_RINGING -> handleRinging(context, intent, tRecv)
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
    private fun handleRinging(context: Context, intent: Intent, tRecv: Long) {
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.trim().orEmpty()
        Log.i(TAG, "RINGING 到达，广播号码=${if (number.isEmpty()) "(未携带)" else number}")
        if (number.isNotEmpty()) {
            val decision = showIfKnown(context, number)
            CallerId.recordPhoneEvent(context, "RINGING", number, decision)
            Log.i(TAG, "处理完成：$decision（总耗时 ${android.os.SystemClock.elapsedRealtime() - tRecv}ms）")
            return
        }
        Log.i(TAG, "广播未带号码 → 转入通话记录补号（每 250ms 查一次，最长 20s）")

        // 广播没带号（Android 9+/座机来电常见）：响铃期间持续轮询通话记录补显。
        // 通话记录往往在响铃开始片刻后才落库，单次读取容易落空，故轮询最多约 8s。
        if (CallerId.granted(context, Manifest.permission.READ_CALL_LOG)) {
            if (polling) return // 已有补号线程在跑，直接复用它的结果
            polling = true
            val pending = goAsync() // 延长进程存活，保证后台线程完成
            Thread {
              // 整个补号过程都必须兜住异常：后台线程里未捕获的异常会直接杀掉进程。
              try {
                val start = System.currentTimeMillis()
                // 窗口放宽到 20s：部分 ROM 通话记录写得很晚；期间一旦挂断就提前结束。
                val deadline = start + 20_000
                var resolved = false
                val tm = runCatching {
                    context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
                }.getOrNull()

                // 是否仍在响铃（取不到状态时保守当作“仍在响铃”，避免误判导致不补号）。
                fun stillRinging(): Boolean = runCatching {
                    tm?.callState == TelephonyManager.CALL_STATE_RINGING
                }.getOrDefault(true)

                while (!resolved && System.currentTimeMillis() < deadline) {
                    val n = latestIncomingNumber(context)
                    if (!n.isNullOrEmpty()) {
                        Log.i(TAG, "补号成功：$n（距响铃广播 ${android.os.SystemClock.elapsedRealtime() - tRecv}ms）")
                        // 去重：本通若已由「来电筛选」或带号广播弹过名片，补号不再重复弹第二张。
                        // 只在仍响铃时弹：已接通/已挂断就别再打扰。
                        val decision = when {
                            CallerId.wasShownRecently(n) -> "名片已弹出（来访筛选/广播），补号跳过重复展示"
                            !stillRinging() -> "广播未带号码，补到号时通话已结束/已接通，未弹名片"
                            else -> showIfKnown(context, n)
                        }
                        CallerId.recordPhoneEvent(context, "RINGING", n, decision)
                        resolved = true
                        break
                    }
                    // 已挂断：不必再等（前 2 秒给足宽限，避免状态抖动误判）
                    if (System.currentTimeMillis() - start > 2000 && !stillRinging()) break
                    try {
                        Thread.sleep(250) // 间隔 250ms：记录一落库就取到号，尽量少让用户等
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                if (!resolved) {
                    // 若这通其实已由其它事件（例如第二次带号广播）弹过名片，就不再写“未取到”，
                    // 否则设置页「最近一次来电广播」会显示成失败，误导排查。
                    val msg = if (CallerId.shownRecently(30_000)) {
                        "广播未带号码，但名片已弹出（由后续广播/其它事件触发）"
                    } else {
                        "广播未带号码，响铃期间通话记录也未补到（号码未知/被拦截，或该通无需显示）"
                    }
                    CallerId.recordPhoneEvent(context, "RINGING", "", msg)
                }
              } catch (e: Exception) {
                CallerId.recordPhoneEvent(context, "RINGING", "",
                    "补号线程异常（已忽略，不影响其它功能）：${e.javaClass.simpleName}")
              } finally {
                polling = false
                pending.finish()
              }
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
        // 只取近 25s 的记录（selection 已把结果集限得很小）。
        // 注意：CallLogProvider 会校验 sortOrder，**不能**把 "LIMIT n" 拼进排序串，
        // 否则抛 IllegalArgumentException: Invalid token LIMIT（曾因此让轮询线程崩掉整个进程）。
        val cursor = runCatching {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DATE),
                CallLog.Calls.DATE + " >= ?",
                arrayOf((now - 25_000).toString()),
                CallLog.Calls.DATE + " DESC"
            )
        }.getOrNull() ?: return null
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
