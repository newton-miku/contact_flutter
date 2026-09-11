package com.newtonmiku.contact_flutter

import android.Manifest
import android.content.ContentProviderOperation
import android.content.pm.PackageManager
import android.os.Build
import android.provider.ContactsContract
import android.telephony.TelephonyManager
import android.telephony.SubscriptionManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private companion object {
        const val CHANNEL = "com.newtonmiku.contact_flutter/contacts"
        const val CALLER_ID_CHANNEL = "com.newtonmiku.contact_flutter/caller_id"
        private const val PERMISSION_REQ = 4101
        private const val PERMISSION_REQ_NUMBER = 4102
    }

    // 来电显示运行时权限请求的回调（requestPermissions 是异步的）
    private var callerIdPermissionResult: MethodChannel.Result? = null
    // 「读取本机号码」权限请求回调（激活页自动填号用）
    private var numberPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "insertContacts") {
                @Suppress("UNCHECKED_CAST")
                val contacts = call.argument<List<Map<String, String>>>("contacts")
                if (contacts == null) {
                    result.error("INVALID_ARG", "contacts is null", null)
                    return@setMethodCallHandler
                }
                result.success(insertContacts(contacts))
            } else {
                result.notImplemented()
            }
        }

        // 来电显示：Flutter 推联系人快照；原生在响铃时直读文件匹配。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALLER_ID_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "replaceContacts" -> {
                    @Suppress("UNCHECKED_CAST")
                    val contacts = call.argument<List<Map<String, Any?>>>("contacts")
                    if (contacts == null) {
                        result.error("INVALID_ARG", "contacts is null", null)
                    } else {
                        CallerId.writeContacts(this, contacts)
                        result.success(true)
                    }
                }
                "setEnabled" -> {
                    val on = call.argument<Boolean>("enabled") ?: false
                    CallerId.setEnabled(this, on)
                    // 功能开关联动保活服务：开启且允许常驻则拉起，关闭则停掉。
                    runCatching {
                        if (on && CallerId.isKeepAlive(this)) {
                            CallerIdService.start(this)
                        } else if (!on) {
                            CallerIdService.stop(this)
                        }
                    }
                    result.success(on)
                }
                "isEnabled" -> result.success(CallerId.isEnabled(this))
                "isKeepAlive" -> result.success(CallerId.isKeepAlive(this))
                "setKeepAlive" -> {
                    val on = call.argument<Boolean>("enabled") ?: false
                    CallerId.setKeepAlive(this, on)
                    runCatching {
                        if (on && CallerId.isEnabled(this)) {
                            CallerIdService.start(this)
                        } else {
                            CallerIdService.stop(this)
                        }
                    }
                    result.success(on)
                }
                "permissions" -> result.success(callerIdPermissions())
                "requestPermissions" -> {
                    callerIdPermissionResult = result
                    val perms = ArrayList<String>().apply {
                        add(Manifest.permission.READ_PHONE_STATE)
                        if (Build.VERSION.SDK_INT >= 26) {
                            add(Manifest.permission.READ_PHONE_NUMBERS)
                        }
                        add(Manifest.permission.READ_CALL_LOG)
                        if (Build.VERSION.SDK_INT >= 33) {
                            add(Manifest.permission.POST_NOTIFICATIONS)
                        }
                    }
                    requestPermissions(perms.toTypedArray(), PERMISSION_REQ)
                }
                "canUseFullScreen" -> result.success(CallerId.canUseFullScreen(this))
                "openFullScreenSettings" -> {
                    CallerId.openFullScreenSettings(this)
                    result.success(true)
                }
                "openSettings" -> {
                    CallerId.openSystemSettings(this, call.argument<String>("target").orEmpty())
                    result.success(true)
                }
                "status" -> result.success(CallerId.status(this))
                "simulateIncoming" -> {
                    val number = call.argument<String>("number").orEmpty()
                    result.success(CallerId.simulateIncoming(this, number))
                }
                "previewIncoming" -> {
                    CallerId.previewIncoming(
                        this,
                        call.argument<String>("name").orEmpty(),
                        call.argument<String>("org").orEmpty(),
                        call.argument<String>("phone").orEmpty(),
                    )
                    result.success(true)
                }
                "line1Number" -> result.success(line1Number())
                "requestNumberPermission" -> {
                    numberPermissionResult = result
                    val perms = ArrayList<String>().apply {
                        add(Manifest.permission.READ_PHONE_STATE)
                        if (Build.VERSION.SDK_INT >= 26) {
                            add(Manifest.permission.READ_PHONE_NUMBERS)
                        }
                    }
                    requestPermissions(perms.toTypedArray(), PERMISSION_REQ_NUMBER)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun callerIdPermissions(): Map<String, Boolean> = mapOf(
        "readPhoneState" to CallerId.granted(this, Manifest.permission.READ_PHONE_STATE),
        "readPhoneNumbers" to (Build.VERSION.SDK_INT < 26 || CallerId.granted(this, Manifest.permission.READ_PHONE_NUMBERS)),
        "readCallLog" to CallerId.granted(this, Manifest.permission.READ_CALL_LOG),
        "notifications" to CallerId.canPostNotifications(this),
    )

    /**
     * 尝试读取本机号码（SIM/电话线路，line1）。
     * 说明：需 READ_PHONE_STATE；Android 上双卡/CDMA/部分运营商不返回号码属正常，
     * 取不到不代表设备有问题，仅供开发者联调排查。
     */
    private fun line1Number(): Map<String, Any?> {
        val hasPhoneState = CallerId.granted(this, Manifest.permission.READ_PHONE_STATE)
        val hasPhoneNumbers = Build.VERSION.SDK_INT < 26 ||
            CallerId.granted(this, Manifest.permission.READ_PHONE_NUMBERS)
        if (!hasPhoneState && !hasPhoneNumbers) {
            return mapOf(
                "granted" to false,
                "number" to null,
                "sims" to emptyList<Map<String, Any?>>(),
                "note" to "未授予“电话/读取本机号码”权限，无法读取（可先在此页申请）",
            )
        }
        return try {
            val sims = phoneSimNumbers()
            val found = sims.mapNotNull { it["number"] as? String }
            val blank = sims.isNotEmpty() && found.isEmpty()
            mapOf(
                "granted" to true,
                "number" to found.firstOrNull(),
                "sims" to sims,
                "note" to when {
                    sims.isEmpty() -> "未检测到 SIM 卡"
                    blank -> "两张卡都未写入号码：双卡/CDMA/部分运营商不提供 line1，属正常现象"
                    else -> ""
                },
            )
        } catch (e: Exception) {
            mapOf(
                "granted" to true,
                "number" to null,
                "sims" to emptyList<Map<String, Any?>>(),
                "note" to "读取失败：${e.message}",
            )
        }
    }

    /** 逐张激活 SIM 读取卡号；卡无号码或运营商未写入则为 null。 */
    private fun phoneSimNumbers(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < 22) {
            val tm = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            val n = tm.line1Number?.trim().orEmpty()
            return listOf(
                mapOf(
                    "slot" to 1,
                    "name" to null,
                    "number" to (n.ifBlank { null }),
                ),
            )
        }
        val sm = getSystemService(TELEPHONY_SUBSCRIPTION_SERVICE) as SubscriptionManager
        val infos = sm.activeSubscriptionInfoList
        if (infos.isNullOrEmpty()) return emptyList()
        return infos.map { info ->
            val n = info.number?.trim().orEmpty()
            mapOf(
                "slot" to (info.simSlotIndex + 1),
                "name" to info.displayName?.toString(),
                "number" to (n.ifBlank { null }),
            )
        }
    }

    override fun onResume() {
        super.onResume()
        // 回到前台时若开着来电显示且允许常驻，补拉一次保活服务（系统重启/被杀后可恢复）。
        if (CallerId.isEnabled(this) && CallerId.isKeepAlive(this)) {
            runCatching { CallerIdService.start(this) }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == PERMISSION_REQ) {
            callerIdPermissionResult?.success(callerIdPermissions())
            callerIdPermissionResult = null
            return
        }
        if (requestCode == PERMISSION_REQ_NUMBER) {
            val ok = CallerId.granted(this, Manifest.permission.READ_PHONE_STATE) ||
                (Build.VERSION.SDK_INT < 26 ||
                    CallerId.granted(this, Manifest.permission.READ_PHONE_NUMBERS))
            numberPermissionResult?.success(ok)
            numberPermissionResult = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun insertContacts(contacts: List<Map<String, String>>): Map<String, Int> {
        var success = 0
        var failure = 0
        val resolver = contentResolver

        for (c in contacts) {
            try {
                val ops = ArrayList<ContentProviderOperation>()

                // 1. 插入 RawContact
                val rawContactIdx = ops.size
                ops.add(
                    ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
                        .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
                        .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
                        .build()
                )

                // 2. 姓名
                val displayName = c["displayName"]
                if (!displayName.isNullOrEmpty()) {
                    ops.add(
                        ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                            .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, rawContactIdx)
                            .withValue(
                                ContactsContract.Data.MIMETYPE,
                                ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE
                            )
                            .withValue(
                                ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME,
                                displayName
                            )
                            .build()
                    )
                }

                // 3. 电话号码：同一人可有 手机/座机/传真 多个号码，按类型分别写入。
                val seenNumbers = HashSet<String>()
                fun isMobileLike(n: String): Boolean {
                    val d = n.filter { it.isDigit() }
                    return d.length == 11 && d.startsWith("1")
                }
                fun pushPhone(n: String?, type: Int) {
                    if (n.isNullOrEmpty()) return
                    val d = n.filter { it.isDigit() }
                    if (d.isEmpty() || !seenNumbers.add(d)) return
                    ops.add(
                        ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                            .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, rawContactIdx)
                            .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                            .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, n)
                            .withValue(ContactsContract.CommonDataKinds.Phone.TYPE, type)
                            .build()
                    )
                }
                c["phoneNumber"]?.let {
                    pushPhone(
                        it,
                        if (isMobileLike(it)) ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE
                        else ContactsContract.CommonDataKinds.Phone.TYPE_MAIN
                    )
                }
                c["mobile2"]?.let {
                    pushPhone(
                        it,
                        if (isMobileLike(it)) ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE
                        else ContactsContract.CommonDataKinds.Phone.TYPE_MAIN
                    )
                }
                c["landline"]?.let { pushPhone(it, ContactsContract.CommonDataKinds.Phone.TYPE_MAIN) }
                c["fax"]?.let { pushPhone(it, ContactsContract.CommonDataKinds.Phone.TYPE_FAX_WORK) }

                // 4. 邮箱
                val email = c["email"]
                if (!email.isNullOrEmpty()) {
                    ops.add(
                        ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                            .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, rawContactIdx)
                            .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                            .withValue(ContactsContract.CommonDataKinds.Email.ADDRESS, email)
                            .withValue(ContactsContract.CommonDataKinds.Email.TYPE, ContactsContract.CommonDataKinds.Email.TYPE_WORK)
                            .build()
                    )
                }

                // 5. 单位 / 职务（单位名写入系统“公司”栏，职务写入“职位”栏）
                val org = c["org"] ?: ""
                val jobTitle = c["jobTitle"] ?: ""
                if (org.isNotEmpty() || jobTitle.isNotEmpty()) {
                    ops.add(
                        ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                            .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, rawContactIdx)
                            .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
                            .withValue(ContactsContract.CommonDataKinds.Organization.COMPANY, org)
                            .withValue(ContactsContract.CommonDataKinds.Organization.TITLE, jobTitle)
                            .withValue(ContactsContract.CommonDataKinds.Organization.TYPE, ContactsContract.CommonDataKinds.Organization.TYPE_WORK)
                            .build()
                    )
                }

                resolver.applyBatch(ContactsContract.AUTHORITY, ops)
                success++
            } catch (e: Exception) {
                android.util.Log.e("ContactImporter", "Failed to insert contact", e)
                failure++
            }
        }

        return mapOf("success" to success, "failure" to failure)
    }
}
