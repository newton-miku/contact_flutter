package com.newtonmiku.contact_flutter

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.app.role.RoleManager
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
    const val ACTION_DISMISS_CARD = "com.newtonmiku.contact_flutter.ACTION_DISMISS_CARD"

    /** 常驻通知上的「关闭常驻」按钮：停止前台服务并关闭开关。 */
    const val ACTION_STOP_KEEPALIVE = "com.newtonmiku.contact_flutter.ACTION_STOP_KEEPALIVE"
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

    /**
     * 直达系统设置页（权限引导用）：
     *   app          → 本应用详情页（权限、通知、后台等入口都在这）
     *   battery      → 电池优化白名单列表（厂商自启/后台限制多在此调整）
     *   notification → 本应用通知设置页
     * 不可用时回退到应用详情页，绝不抛异常。
     */
    fun openSystemSettings(c: Context, target: String) {
        val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", c.packageName, null))
        val intent = when (target) {
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            "notification" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, c.packageName)
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                .setData(Uri.fromParts("package", c.packageName, null))
            // 无电脑时授权「来电筛选」角色要用 adb：这里是「无线调试」页的入口。
            // Android 11+ 才有该页；打不开就回退到开发者选项（再不行回退应用详情页）。
            "wireless_debugging" -> Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            else -> appDetails
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (target == "wireless_debugging" && Build.VERSION.SDK_INT >= 30) {
            val wd = Intent("android.settings.WIRELESS_DEBUGGING_SETTINGS")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { c.startActivity(wd) }.isSuccess) return
        }
        val ok = runCatching { c.startActivity(intent) }.isSuccess
        if (!ok && target != "app") {
            runCatching { c.startActivity(appDetails.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }

    /**
     * 打开「全屏提醒」授权页。
     *
     * Android 14(API 34)+ 起 USE_FULL_SCREEN_INTENT 变成「特殊应用权限」，**默认不授予**；
     * 未授予时 setFullScreenIntent 会被系统静默降级成普通通知（来电只出通知、不弹全屏卡片）。
     * 该开关**不在**通知渠道设置里，而在：设置 → 应用 → 特殊应用权限 → 全屏通知
     * （即 ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT，需带 EXTRA_APP_PACKAGE）。
     * 老系统/该页不可用时回退到通知渠道设置页。
     */
    /** 是否已取得「来电筛选」角色（响铃瞬间即可拿到号码，名片最快）。 */
    fun hasScreeningRole(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        val rm = c.getSystemService(RoleManager::class.java) ?: return false
        return runCatching { rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING) }.getOrDefault(false)
    }

    /** 本机是否可申请「来电筛选」角色（被其它应用占用/ROM 限制时为 false）。 */
    fun screeningRoleAvailable(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        val rm = c.getSystemService(RoleManager::class.java) ?: return false
        return runCatching { rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING) }.getOrDefault(false)
    }

    /**
     * 「来电筛选」回调专用：命中通讯录就弹名片（复用同一套匹配/去重/展示逻辑），
     * 返回给诊断记录用的结论文案。
     */
    fun showIfKnownFromScreening(c: Context, number: String): String {
        if (!canPostNotifications(c)) return "通知未开启，名片无法弹出"
        val hit = match(c, number) ?: return "陌生号码（号码库未命中），按设计不显示"
        showIncoming(c, number, hit)
        return "命中「${hit.name}」，已弹全屏名片（来电筛选，响铃即时）"
    }

    /** 是否已授予「显示在其他应用上层」（悬浮窗）：授予后可在后台直接拉起名片页。 */
    fun canDrawOverlays(c: Context): Boolean = Settings.canDrawOverlays(c)

    /** 打开「显示在其他应用上层」授权页。 */
    fun openOverlaySettings(c: Context) {
        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
            .setData(Uri.fromParts("package", c.packageName, null))
        if (runCatching { c.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isFailure) {
            openSystemSettings(c, "app")
        }
    }

    fun openFullScreenSettings(c: Context) {
        val channel = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, c.packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
        if (Build.VERSION.SDK_INT >= 34) {
            val fsi = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                .setData(Uri.fromParts("package", c.packageName, null))
                .putExtra(Settings.EXTRA_APP_PACKAGE, c.packageName)
            if (runCatching { c.startActivity(fsi.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess) {
                return
            }
        }
        runCatching { c.startActivity(channel.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
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

    // 号码库解析结果的内存缓存：钥匙是「文件大小 + 最后修改时间」。
    // 每次来电都重新读文件+解析 JSON 会带来几十~上百毫秒的延迟，缓存后只解析一次。
    @Volatile
    private var cachedIndex: Map<String, Hit>? = null
    private var cachedKey: String = ""

    /** 一次读入文件并建索引（联系人量级为几百~几千，毫秒级；结果带缓存）。 */
    private fun loadIndex(c: Context): Map<String, Hit>? {
        val f = File(c.filesDir, LOOKUP_FILE)
        if (!f.exists()) {
            cachedIndex = null
            cachedKey = ""
            return null
        }
        val key = "${f.length()}:${f.lastModified()}"
        if (key == cachedKey) {
            cachedIndex?.let { return it }
        }
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
        cachedIndex = index
        cachedKey = key
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
        val t0 = android.os.SystemClock.elapsedRealtime()
        val digits = raw.filter(Char::isDigit)
        if (digits.length < 3) return null
        val index = loadIndex(c) ?: run {
            android.util.Log.i("CallerId", "号码库不存在，无法匹配")
            return null
        }
        for (v in numberVariants(digits)) index[v]?.let {
            android.util.Log.i("CallerId",
                "匹配命中「${it.name}」（库 ${index.size} 条，耗时 ${android.os.SystemClock.elapsedRealtime() - t0}ms）")
            return it
        }
        android.util.Log.i("CallerId",
            "未命中陌生号码（库 ${index.size} 条，耗时 ${android.os.SystemClock.elapsedRealtime() - t0}ms）")
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

        // 尽量不抛异常：不同 ROM 上通知渠道/PendingIntent 都可能抛非 SecurityException 的异常，
        // 而调用方（广播接收器/筛选服务）一旦抛出就会导致进程崩溃。
        try {
            showIncomingInner(c, number, hit)
        } catch (e: Throwable) {
            android.util.Log.w("CallerId", "展示名片失败（已忽略）", e)
        }
    }

    private fun showIncomingInner(c: Context, number: String, hit: Hit) {
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

        // 亮屏兜底：系统只把全屏意图用在「锁屏/息屏」；已授予「显示在其他应用上层」时
        // 改为直接拉起名片页（后台启动 Activity 因该权限被放行），亮屏使用中也能整屏弹出。
        val overlayOk = canDrawOverlays(c)
        if (overlayOk) {
            runCatching { c.startActivity(open) }
        }

        val builder = NotificationCompat.Builder(c, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_call)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentTitle(hit.name)
            .setContentText(if (hit.orgLine.isEmpty()) number else hit.orgLine)
            .setContentIntent(pi)
            .setOngoing(true)
            .setAutoCancel(false)
        // 有悬浮窗权限时页面已直接拉起，再带全屏意图会出现「横幅 + 卡片」重复，故只在无该权限时使用。
        if (!overlayOk) {
            builder.setFullScreenIntent(pi, true) // 主流来电名片做法：顶到系统来电界面
        }

        try {
            NotificationManagerCompat.from(c).notify(NOTIFICATION_ID, builder.build())
        } catch (e: Throwable) {
            // POST_NOTIFICATIONS 被系统收紧等，静默放弃本次展示
            android.util.Log.w("CallerId", "notify 失败（已忽略）", e)
        }
    }

    /** 最近 [withinMs] 毫秒内是否弹过名片（用于避免补号失败信息覆盖掉成功结论）。 */
    fun shownRecently(withinMs: Long): Boolean =
        lastShown.isNotEmpty() && System.currentTimeMillis() - lastShownAt < withinMs

    /**
     * 同一个号码是否刚弹过名片。补号线程据此去重：
     * 来电筛选（或带号广播）已经弹过之后，补号再补到同一个号时不能重复弹第二张卡片。
     */
    fun wasShownRecently(number: String, withinMs: Long = 30_000): Boolean =
        lastShown.isNotEmpty() && lastShown == number &&
            System.currentTimeMillis() - lastShownAt < withinMs

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
            "overlayOk" to canDrawOverlays(c),
            "screeningRoleHeld" to hasScreeningRole(c),
            "screeningRoleAvailable" to screeningRoleAvailable(c),
            "readContacts" to granted(c, Manifest.permission.READ_CONTACTS),
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
