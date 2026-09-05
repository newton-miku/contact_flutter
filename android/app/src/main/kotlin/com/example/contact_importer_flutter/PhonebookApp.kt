package com.example.contact_importer_flutter

import android.app.Application
import android.content.IntentFilter
import android.telephony.TelephonyManager

/**
 * 应用 Application：
 * 进程存活期间「动态注册」来电监听作为兜底。
 *
 * 为什么：Android 8+ 对 manifest(静态)注册的接收器收隐式广播有限制，
 * 且小米/OPPO/vivo 等厂商会拦后台自启动，静态接收器在后台经常收不到来电广播。
 * 动态注册（进程在跑即有效）不受此限制，能保证“刚用过 App、退到后台等来电”的场景必达。
 * 与 manifest 里的静态 [CallerIdReceiver] 并存：进程已死但系统允许拉起时仍靠静态那个，
 * 两者同时触发时由 CallerId.showIncoming 的 8s 去重避免重复弹名片。
 */
class PhonebookApp : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
            registerReceiver(CallerIdReceiver(), filter)
        } catch (_: Exception) {
            // 注册失败（极端情况）不阻塞启动，仍有 manifest 静态接收器可用
        }
    }
}
