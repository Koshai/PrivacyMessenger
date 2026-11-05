package com.privatemessenger.private_messenger

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "incoming" -> {
                        startCallService(incoming = true)
                        result.success(null)
                    }
                    "ongoing" -> {
                        startCallService(incoming = false)
                        result.success(null)
                    }
                    "ended" -> {
                        val stop = Intent(this, CallForegroundService::class.java)
                            .setAction(CallForegroundService.ACTION_STOP)
                        startService(stop)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startCallService(incoming: Boolean) {
        val intent = Intent(this, CallForegroundService::class.java)
            .putExtra(CallForegroundService.EXTRA_INCOMING, incoming)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    companion object {
        private const val CHANNEL = "private_messenger/calls"
    }
}
