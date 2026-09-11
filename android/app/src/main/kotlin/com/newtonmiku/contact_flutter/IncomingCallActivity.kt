package com.newtonmiku.contact_flutter

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.telephony.TelephonyManager
import android.view.WindowManager
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * 全屏来电名片（由 setFullScreenIntent 拉起，锁屏也能整屏显示）。
 * 展示命中联系人的 姓名/单位·职务/号码，并提供 回拨/短信/复制/关闭。
 * 关闭时机：①自己监听到接通/挂断；②主接收器来电结束时广播的关闭信号。
 */
class IncomingCallActivity : Activity() {

    companion object {
        const val EXTRA_NAME = "name"
        const val EXTRA_ORG = "org"
        const val EXTRA_PHONE = "phone"

        /// 弹出后的收尾宽限期：此期间内的 OFFHOOK/IDLE/关闭广播一律忽略。
        /// 原因：部分机型会在全屏卡片拉起的瞬间补发/重发一次接通或挂断广播，
        /// 若照单收下卡片会“闪一下即消失”。真正的接通/挂断不会发生在弹出瞬间。
        private const val DISMISS_GRACE_MS = 2000L
    }

    /// 页面创建时刻（单调时钟），用于计算宽限期。
    private val startedAt = SystemClock.elapsedRealtime()

    private val phoneStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
            val isEndSignal =
                intent.action == CallerId.ACTION_DISMISS_CARD ||
                    state == TelephonyManager.EXTRA_STATE_OFFHOOK ||
                    state == TelephonyManager.EXTRA_STATE_IDLE
            if (!isEndSignal) return
            // 刚弹出前 2 秒内的收尾事件可能是机型补发的重复广播，忽略防“闪退”。
            if (SystemClock.elapsedRealtime() - startedAt < DISMISS_GRACE_MS) return
            // 已接通或已挂断（或被主接收器通知收尾）→ 名片使命完成，让出屏幕
            if (!isFinishing) finish()
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
        // 关键：不能按惯例在 onStop 注销。名片被系统来电界面盖到后台时会先走 onStop，
        // 若此刻注销就再也收不到「接通/挂断」，卡片会残留。故监听保持到 onDestroy 才解绑。
        val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
        filter.addAction(CallerId.ACTION_DISMISS_CARD)
        // Android 14(API 34)+ 起：过滤器里含「非系统广播」（ACTION_DISMISS_CARD 是本应用自定义的）
        // 时，注册必须显式声明导出性，否则抛 SecurityException，页面刚起来就崩（表现为名片闪退）。
        // 这里用 NOT_EXPORTED：关闭广播只由本应用（setPackage 指定自己）与系统投递。
        // 注册失败也不让名片崩掉（退化为需手动关闭，总好过闪退）。
        runCatching {
            ContextCompat.registerReceiver(
                this, phoneStateReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED
            )
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(phoneStateReceiver) }
        // 页面收尾时把可能残留的全屏通知一并移除（取消通知并不会自动关掉页面，这里补上）。
        runCatching { NotificationManagerCompat.from(this).cancel(CallerId.NOTIFICATION_ID) }
        super.onDestroy()
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
