package at.antcolony.manager

import android.content.Intent
import android.net.Uri
import android.nfc.NfcAdapter
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        asDeepLink(intent)
        super.onCreate(savedInstanceState)
    }

    /**
     * System settings the notification diagnostics link to: app notification
     * settings, app info (battery, autostart) and whether battery optimisation
     * may delay the background checks.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "acm/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "batteryUnrestricted" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "manufacturer" -> result.success(Build.MANUFACTURER)
                // the way back after sign-in with SSO: <app id>://acm/sso
                "packageName" -> result.success(packageName)
                "openNotificationSettings" -> {
                    open(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                    result.success(null)
                }
                "openAppSettings" -> {
                    open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(intent: Intent) {
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }
    }

    override fun onNewIntent(intent: Intent) {
        asDeepLink(intent)
        super.onNewIntent(intent)
    }

    /**
     * A tapped NFC tag arrives as NDEF_DISCOVERED with the tag's link as data.
     * Flutter's deep linking only routes ACTION_VIEW intents, so present it as
     * one – the router then opens /c/<code> like any other colony link.
     */
    private fun asDeepLink(intent: Intent?) {
        if (intent?.action == NfcAdapter.ACTION_NDEF_DISCOVERED && intent.data != null) {
            intent.action = Intent.ACTION_VIEW
        }
    }
}
