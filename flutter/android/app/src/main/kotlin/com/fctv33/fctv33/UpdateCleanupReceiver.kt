package com.fctv33.fctv33

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Fired after this package is replaced by a newer APK — drop the cached installer file. */
class UpdateCleanupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            UpdateApkCleanup.deleteCachedApk(context.applicationContext)
        }
    }
}
