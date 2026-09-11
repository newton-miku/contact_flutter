package com.newtonmiku.contact_flutter

import android.telecom.Call
import android.telecom.CallScreeningService

/**
 * 来电筛选服务：**只为了在响铃第一时间拿到来电号码**（不拦截、不处理通话）。
 *
 * 为什么需要它：Android 10+ 的响铃广播经常不带号码，通话记录又要等系统写库（实测可达
 * 约 10 秒），名片因此弹得很晚。取得「来电筛选」角色后，系统会在来电建立的瞬间回调这里，
 * [Call.Details] 直接带着来电号码 —— 名片可以近乎即时弹出。
 *
 * 授权方式：系统设置 → 应用 → 默认应用 → 来电筛选（应用内提供一键跳转）。
 * 该角色全机只能一个应用持有；未取得时不影响原有「广播 + 通话记录补号」链路。
 */
class CallerIdScreeningService : CallScreeningService() {

    override fun onScreenCall(callDetails: Call.Details) {
        // 一律放行：本应用只做展示，绝不拦截或静音任何来电。
        // 无论后面出什么岔子，都必须先把「放行」应答出去，否则会被系统判为不响应。
        runCatching { respondToCall(callDetails, CallResponse.Builder().build()) }

        // 真机（如荣耀 MagicOS）上这里可能抛出厂商特有的运行时异常；
        // 整段兜住，绝不能让它升级成进程崩溃。
        try {
            handleIncoming(callDetails)
        } catch (e: Throwable) {
            android.util.Log.w("CallerId", "来电筛选处理异常（已忽略）", e)
        }
    }

    private fun handleIncoming(callDetails: Call.Details) {
        if (callDetails.callDirection != Call.Details.DIRECTION_INCOMING) return
        val number = runCatching {
            callDetails.handle?.schemeSpecificPart?.trim().orEmpty()
        }.getOrDefault("")
        if (number.isEmpty()) {
            android.util.Log.i("CallerId", "来电筛选回调：未取到号码")
            return
        }
        if (!CallerId.isEnabled(this)) {
            android.util.Log.i("CallerId", "来电筛选回调：号码=$number（来电显示开关未开，忽略）")
            return
        }

        val t0 = android.os.SystemClock.elapsedRealtime()
        val decision = CallerId.showIfKnownFromScreening(this, number)
        CallerId.recordPhoneEvent(this, "SCREENING", number, decision)
        android.util.Log.i("CallerId",
            "来电筛选处理完成：$decision（耗时 ${android.os.SystemClock.elapsedRealtime() - t0}ms）")
    }
}
