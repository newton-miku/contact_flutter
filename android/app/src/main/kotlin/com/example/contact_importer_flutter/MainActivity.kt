package com.example.contact_importer_flutter

import android.Manifest
import android.content.ContentProviderOperation
import android.content.pm.PackageManager
import android.os.Build
import android.provider.ContactsContract
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "com.example.contact_importer_flutter/contacts"
        const val CALLER_ID_CHANNEL = "com.example.contact_importer_flutter/caller_id"
        private const val PERMISSION_REQ = 4101
    }

    // 来电显示运行时权限请求的回调（requestPermissions 是异步的）
    private var callerIdPermissionResult: MethodChannel.Result? = null

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
                    result.success(on)
                }
                "isEnabled" -> result.success(CallerId.isEnabled(this))
                "permissions" -> result.success(callerIdPermissions())
                "requestPermissions" -> {
                    callerIdPermissionResult = result
                    val perms = ArrayList<String>().apply {
                        add(Manifest.permission.READ_PHONE_STATE)
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
                else -> result.notImplemented()
            }
        }
    }

    private fun callerIdPermissions(): Map<String, Boolean> = mapOf(
        "readPhoneState" to CallerId.granted(this, Manifest.permission.READ_PHONE_STATE),
        "readCallLog" to CallerId.granted(this, Manifest.permission.READ_CALL_LOG),
        "notifications" to CallerId.canPostNotifications(this),
    )

    /**
     * 尝试读取本机号码（SIM/电话线路，line1）。
     * 说明：需 READ_PHONE_STATE；Android 上双卡/CDMA/部分运营商不返回号码属正常，
     * 取不到不代表设备有问题，仅供开发者联调排查。
     */
    private fun line1Number(): Map<String, Any?> {
        val granted = CallerId.granted(this, Manifest.permission.READ_PHONE_STATE)
        if (!granted) {
            return mapOf(
                "granted" to false,
                "number" to null,
                "note" to "未授予“电话”权限，无法读取（可先在此页申请）",
            )
        }
        return try {
            val tm = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            val n = tm.line1Number?.trim().orEmpty()
            mapOf(
                "granted" to true,
                "number" to (n.ifBlank { null }),
                "note" to if (n.isBlank())
                    "未返回号码：双卡/CDMA/部分运营商不写入 line1，属正常现象"
                else "",
            )
        } catch (e: Exception) {
            mapOf("granted" to true, "number" to null, "note" to "读取失败：${e.message}")
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
