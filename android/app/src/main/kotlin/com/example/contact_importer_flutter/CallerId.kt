package com.example.contact_importer_flutter

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.LinkedHashSet

/**
 * 来电显示名片：开关、号码匹配、全屏通知。
 *
 * 数据流：Flutter 每次拿到联系人快照后经 MethodChannel 把精简字段推到
 * [writeContacts]，写成本地 JSON 文件；来电响铃时原生 [CallerIdReceiver] 直接读该文件
 * 匹配（不拉起 Flutter engine），命中则发 setFullScreenIntent 通知 → 全屏名片 Activity。
 */
object CallerId {
    const val CHANNEL_ID = "incoming_calls"
    const val NOTIFICATION_ID = 0xC011 // "call-id"
    const val ACTION_DISMISS_CARD = "com.example.contact_importer_flutter.ACTION_DISMISS_CARD"
    private const val PREFS = "caller_id_prefs"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_KEEP_ALIVE = "keep_alive"
    private const val KEY_EVENT_AT = "last_event_at"
    private const val KEY_EVENT_STATE = "last_event_state"
    private const val KEY_EVENT_NUMBER = "last_event_number"
    private const val KEY_EVENT_DECISION = "last_event_decision"
    private const val LOOKUP_FILE = "contacts_lookup.json"

    /** 命中结果：姓名/单位/职务 + 库里存的号码原文。 */
    data class Hit(val name: String, val phone: String, val unit: String, val jobTitle: String) {
        val orgLine: String
            get() = listOf(unit.trim(), jobTitle.trim()).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    // ---------- 开关（原生 SharedPreferences：进程被杀后广播仍能读到） ----------

    fun isEnabled(c: Context): Boolean =
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

    fun setEnabled(c: Context, on: Boolean) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, on).apply()
    }

    // ---------- 后台常驻（前台服务保活） ----------

    /** 是否启用后台常驻（默认开）：即使从最近任务划掉也尽量保持进程存活。 */
    fun isKeepAlive(c: Context): Boolean =
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_KEEP_ALIVE, true)

    fun setKeepAlive(c: Context, on: Boolean) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_KEEP_ALIVE, on).apply()
    }

    // ---------- 来电事件记录（诊断：receiver 是否被系统广播唤醒、是否取到号） ----------

    /** receiver 每次处理一次响铃/接通/挂断时落一条记录，设置页据此判断“开了却没反应”卡在哪一步。 */
    fun recordPhoneEvent(c: Context, state: String, number: String, decision: String) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_EVENT_AT, System.currentTimeMillis())
            .putString(KEY_EVENT_STATE, state)
            .putString(KEY_EVENT_NUMBER, number)
            .putString(KEY_EVENT_DECISION, decision)
            .apply()
    }

    /** 最近一条来电事件；无记录返回 null（= 系统从未把响铃广播交给本应用）。 */
    fun lastPhoneEvent(c: Context): Map<String, Any?>? {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val at = p.getLong(KEY_EVENT_AT, 0L)
        if (at == 0L) return null
        return mapOf(
            "at" to at,
            "state" to (p.getString(KEY_EVENT_STATE, "") ?: ""),
            "number" to (p.getString(KEY_EVENT_NUMBER, "") ?: ""),
            "decision" to (p.getString(KEY_EVENT_DECISION, "") ?: ""),
        )
    }

    // ---------- 权限 / 能力 ----------

    fun granted(c: Context, perm: String): Boolean =
        ContextCompat.checkSelfPermission(c, perm) == PackageManager.PERMISSION_GRANTED

    fun canPostNotifications(c: Context): Boolean =
        NotificationManagerCompat.from(c).areNotificationsEnabled()

    /** Android 14+ 才需要用户在系统设置里单独授予“全屏提醒”；更早一律允许。 */
    fun canUseFullScreen(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    fun openFullScreenSettings(c: Context) {
        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, c.packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        c.startActivity(intent)
    }

    // ---------- 查找缓存（Flutter 推送；原生响铃直读） ----------

    fun writeContacts(c: Context, items: List<Map<String, Any?>>) {
        val arr = JSONArray()
        for (m in items) {
            val phone = (m["phone"] as? String)?.trim().orEmpty()
            if (phone.isEmpty()) continue
            val o = JSONObject()
            o.put("p", phone)
            o.put("n", (m["name"] as? String).orEmpty())
            o.put("u", (m["unit"] as? String).orEmpty())
            o.put("j", (m["jobTitle"] as? String).orEmpty())
            arr.put(o)
        }
        val target = File(c.filesDir, LOOKUP_FILE)
        val tmp = File(c.filesDir, LOOKUP_FILE + ".tmp")
        try {
            tmp.writeText(arr.toString(), Charsets.UTF_8)
            if (target.exists()) target.delete()
            tmp.renameTo(target)
        } catch (_: Exception) {
            // 写失败不影响主流程，最多是这次来电不识别
        }
    }

    /** 一次读入文件并建索引（联系人量级为几百~几千，毫秒级）。 */
    private fun loadIndex(c: Context): Map<String, Hit>? {
        val f = File(c.filesDir, LOOKUP_FILE)
        if (!f.exists()) return null
        val text = try {
            f.readText(Charsets.UTF_8)
        } catch (_: Exception) {
            return null
        }
        val arr = try {
            JSONArray(text)
        } catch (_: Exception) {
            return null
        }
        val index = HashMap<String, Hit>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val digits = o.optString("p").filter(Char::isDigit)
            if (digits.length < 3) continue
            val hit = Hit(
                name = o.optString("n"),
                phone = o.optString("p"),
                unit = o.optString("u"),
                jobTitle = o.optString("j"),
            )
            for (v in numberVariants(digits)) index.putIfAbsent(v, hit)
        }
        return index
    }

    /**
     * 一个号码的匹配键集：裸数字；带/不带 +86 前缀的变体；0915 区号座机去掉区号的
     * 7 位短号变体（本县固话互拨、来电显示为短号时也能命中存的全号）。
     * 同时用于「入库建索引」与「来电建 probe」，两侧自动对称。
     */
    private fun numberVariants(d: String): Set<String> {
        val out = LinkedHashSet<String>()
        out.add(d)
        // 0915 区号座机：去掉区号 → 7 位短号（"6315368"）变体。
        if (d.startsWith("0915") && d.length > 8) out.add(d.substring(4))
        // 反向兜底：库里万一存在无区号短号（正常不会），补 0915 全号变体。
        if (d.length in 6..8 && !d.startsWith("0") && !d.startsWith("1")) out.add("0915$d")
        if (d.startsWith("86")) {
            // 全号已带 86：剥掉后若仍带 0915 区号，再按上规则补短号。
            if (d.length >= 12) {
                val core = d.substring(2)
                out.add(core)
                if (core.startsWith("0915") && core.length > 8) out.add(core.substring(4))
            }
        } else {
            out.add("86$d")
        }
        return out
    }

    /** 在本地通讯录缓存里找号码；未命中返回 null。 */
    fun match(c: Context, raw: String): Hit? {
        val digits = raw.filter(Char::isDigit)
        if (digits.length < 3) return null
        val index = loadIndex(c) ?: return null
        for (v in numberVariants(digits)) index[v]?.let { return it }
        return null
    }

    // ---------- 全屏通知 ----------

    /** 去重：同一通来电有时会重复广播响铃事件，8 秒内同号只弹一次。 */
    @Volatile
    private var lastShown = ""
    private var lastShownAt = 0L

    fun showIncoming(c: Context, number: String, hit: Hit, skipDedupe: Boolean = false) {
        if (!skipDedupe && lastShown == number && System.currentTimeMillis() - lastShownAt < 8000) return
        lastShown = number
        lastShownAt = System.currentTimeMillis()

        if (!canPostNotifications(c)) return
        ensureChannel(c)

        val open = Intent(c, IncomingCallActivity::class.java)
            .putExtra(IncomingCallActivity.EXTRA_NAME, hit.name)
            .putExtra(IncomingCallActivity.EXTRA_ORG, hit.orgLine)
            .putExtra(IncomingCallActivity.EXTRA_PHONE, number)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pi = PendingIntent.getActivity(
            c, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(c, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_call)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentTitle(hit.name)
            .setContentText(if (hit.orgLine.isEmpty()) number else hit.orgLine)
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true) // 主流来电名片做法：顶到系统来电界面
            .setOngoing(true)
            .setAutoCancel(false)

        try {
            NotificationManagerCompat.from(c).notify(NOTIFICATION_ID, builder.build())
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS 被系统收紧等，静默放弃本次展示
        }
    }

    /** 来电结束/接通时调用，收起名片（取消通知 + 通知仍在显示的名片页关闭）。 */
    fun dismiss(c: Context) {
        lastShown = "" // 允许同一号码快速再来电时再次显示
        try {
            NotificationManagerCompat.from(c).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
        // 取消通知只会收起“通知本身”，并不会关掉已被全屏拉起的名片 Activity。
        // 名片被系统来电界面盖到后台时收不到通话状态，这里显式广播一条关闭信号，
        // 让仍存活的 IncomingCallActivity 收到后主动 finish()（无该页则无副作用）。
        try {
            val i = Intent(ACTION_DISMISS_CARD).setPackage(c.packageName)
            c.sendBroadcast(i)
        } catch (_: Exception) {
        }
    }

    // ---------- 测试 / 预览（设置页调用；与真实来电走同一套“匹配 + 全屏通知”） ----------

    /**
     * 模拟一通往通讯录已同步号码的来电：走 [match] + [showIncoming] 完整链路
     * （等同真实响铃命中后的表现），让用户在设置页就能验证“能不能弹出来”。
     * 返回结果供 Flutter 给出明确提示，避免“静默失败”。
     */
    fun simulateIncoming(c: Context, number: String): Map<String, Any?> {
        if (!canPostNotifications(c)) {
            return mapOf("matched" to false, "reason" to "notifications")
        }
        val hit = match(c, number)
        if (hit == null) {
            return mapOf("matched" to false, "name" to null)
        }
        showIncoming(c, number, hit, skipDedupe = true)
        return mapOf(
            "matched" to true,
            "name" to hit.name,
            "org" to hit.orgLine,
            "phone" to number,
        )
    }

    /**
     * 纯界面预览：直接拉起名片 Activity（不走通知/全屏系统限制），
     * 无论权限是否齐全都能先看到名片长什么样。
     */
    fun previewIncoming(c: Context, name: String, org: String, phone: String) {
        val intent = Intent(c, IncomingCallActivity::class.java)
            .putExtra(IncomingCallActivity.EXTRA_NAME, name)
            .putExtra(IncomingCallActivity.EXTRA_ORG, org)
            .putExtra(IncomingCallActivity.EXTRA_PHONE, phone)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { c.startActivity(intent) }
    }

    /** 设置页“运行状态”一次性取回全部诊断数据。 */
    fun status(c: Context): Map<String, Any?> {
        val f = File(c.filesDir, LOOKUP_FILE)
        var count = 0
        if (f.exists()) {
            count = try {
                JSONArray(f.readText(Charsets.UTF_8)).length()
            } catch (_: Exception) {
                -1 // 文件损坏
            }
        }
        val ev = lastPhoneEvent(c)
        return mapOf(
            "enabled" to isEnabled(c),
            "readPhoneState" to granted(c, Manifest.permission.READ_PHONE_STATE),
            "readCallLog" to granted(c, Manifest.permission.READ_CALL_LOG),
            "notifications" to canPostNotifications(c),
            "fullScreenOk" to canUseFullScreen(c),
            "lookupExists" to f.exists(),
            "lookupCount" to count,
            "eventRecorded" to (ev != null),
            "lastEventAt" to (ev?.get("at") as? Long ?: 0L),
            "lastEventState" to (ev?.get("state") as? String ?: ""),
            "lastEventNumber" to (ev?.get("number") as? String ?: ""),
            "lastEventDecision" to (ev?.get("decision") as? String ?: ""),
        )
    }

    fun ensureChannel(c: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "来电名片", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "响铃时以全屏名片显示来电人的单位与职务"
                setShowBadge(false)
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
        )
    }
}
