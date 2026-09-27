package at.antcolony.manager

import android.content.Intent
import android.nfc.NfcAdapter
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        asDeepLink(intent)
        super.onCreate(savedInstanceState)
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
