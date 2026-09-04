package com.example.contact_importer_flutter

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telephony.TelephonyManager
import android.view.WindowManager
import android.widget.TextView
import android.widget.Toast

/**
 * 全屏来电名片（由 setFullScreenIntent 拉起，锁屏也能整屏显示）。
 * 展示命中联系人的 姓名/单位·职务/号码，并提供 回拨/短信/复制/关闭。
 * 监听通话状态：接通或挂断后自动关闭本页。
 */
class IncomingCallActivity : Activity() {

    companion object {
        const val EXTRA_NAME = "name"
        const val EXTRA_ORG = "org"
        const val EXTRA_PHONE = "phone"
    }

    private val phoneStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
            if (state == TelephonyManager.EXTRA_STATE_OFFHOOK ||
                state == TelephonyManager.EXTRA_STATE_IDLE
            ) {
                // 已接通或已挂断 → 名片使命完成，让出屏幕
                if (!isFinishing) finish()
            }
        }
    }

    private lateinit var phoneNumber: String

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        phoneNumber = intent.getStringExtra(EXTRA_PHONE).orEmpty()
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty()
        val org = intent.getStringExtra(EXTRA_ORG).orEmpty()

        // 锁屏/息屏也要能整屏亮起显示（API 27+ 新接口；更早用旧 window flag 兜底）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT

        setContentView(R.layout.activity_incoming_call)

        findViewById<TextView>(R.id.tv_badge).text =
            name.trim().firstOrNull()?.toString() ?: "?"
        findViewById<TextView>(R.id.tv_name).text = name
        findViewById<TextView>(R.id.tv_org).text = org.ifEmpty { phoneNumber }
        findViewById<TextView>(R.id.tv_phone).text = phoneNumber

        findViewById<TextView>(R.id.btn_call).setOnClickListener {
            dial()
        }
        findViewById<TextView>(R.id.btn_sms).setOnClickListener {
            openSms()
        }
        findViewById<TextView>(R.id.btn_copy).setOnClickListener {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("phone", phoneNumber))
            Toast.makeText(this, "已复制号码", Toast.LENGTH_SHORT).show()
        }
        findViewById<TextView>(R.id.btn_close).setOnClickListener {
            finish()
        }
    }

    override fun onStart() {
        super.onStart()
        registerReceiver(
            phoneStateReceiver,
            IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
        )
    }

    override fun onStop() {
        super.onStop()
        runCatching { unregisterReceiver(phoneStateReceiver) }
    }

    private fun dial() {
        // ACTION_DIAL 只打开拨号界面，无需 CALL_PHONE 权限
        runCatching {
            startActivity(
                Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(phoneNumber)))
            )
        }.onFailure { toast("无法打开拨号界面") }
    }

    private fun openSms() {
        runCatching {
            startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(phoneNumber))))
        }.onFailure { toast("无法打开短信") }
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }
}
