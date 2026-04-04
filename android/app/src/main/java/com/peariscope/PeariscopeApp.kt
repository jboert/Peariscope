package com.peariscope

import android.app.Application
import android.util.Log

class PeariscopeApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Ignore SIGPIPE — BareKit IPC pipe breaks can send SIGPIPE
        try {
            // Android doesn't expose signal() directly, but the JVM already ignores SIGPIPE
            // for socket operations. This is here as documentation that we're aware of the issue.
            Log.d(TAG, "Peariscope application started")
        } catch (e: Exception) {
            Log.e(TAG, "Error during app init", e)
        }
    }

    companion object {
        const val TAG = "Peariscope"
    }
}
