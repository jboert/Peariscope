package com.peariscope

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Launches Peariscope on device boot if "Start on boot" is enabled in settings.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val prefs = context.getSharedPreferences("peariscope", Context.MODE_PRIVATE)
            if (prefs.getBoolean("autoStartOnBoot", false)) {
                Log.d("BootReceiver", "Auto-starting Peariscope on boot")
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(launchIntent)
            }
        }
    }
}
