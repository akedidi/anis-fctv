package com.fctv33.fctv33

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log

/** Attempts to return once after a self-update; Android enforces launch policy. */
class UpdateCleanupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val app = context.applicationContext
        // Give the system installer time to finish closing its task. Starting
        // immediately from its success callback can be covered by the launcher
        // when the installer finishes. Keep the receiver alive for this delay.
        val result = goAsync()
        Log.i("FCTV33Update", "Package replaced; returning after installer finishes")
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                returnAfterSelfUpdate(app)
                UpdateApkCleanup.deleteCachedApk(app)
            } finally {
                result.finish()
            }
        }, 600L)
    }

    companion object {
        fun returnAfterSelfUpdate(context: Context) {
            if (!UpdateApkCleanup.consumePendingRelaunch(context)) {
                Log.i("FCTV33Update", "No pending self-update return")
                return
            }
            // Some TV/Fire OS installers allow the return through their own
            // foreground install flow. Do not preemptively reject those devices
            // just because the optional overlay permission is absent.
            val overlayAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                Settings.canDrawOverlays(context)
            Log.i("FCTV33Update", "Returning after self-update: sdk=${Build.VERSION.SDK_INT}, overlay=$overlayAllowed")
            try {
                val launch = context.packageManager.getLeanbackLaunchIntentForPackage(context.packageName)
                    ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
                    ?: Intent(context, MainActivity::class.java).apply {
                        action = Intent.ACTION_MAIN
                        addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
                    }
                context.startActivity(launch.apply {
                    action = Intent.ACTION_MAIN
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                })
            } catch (error: Exception) {
                Log.w("FCTV33Update", "Unable to return after update", error)
            }
        }
    }
}
