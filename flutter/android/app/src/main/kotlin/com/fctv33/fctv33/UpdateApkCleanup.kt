package com.fctv33.fctv33

import android.content.Context
import android.os.Build
import java.io.File

/** Cached self-update APK under cacheDir/updates/ (AnisFlix-compatible). */
object UpdateApkCleanup {
    private const val PREFS = "fctv_updates"
    private const val KEY_PENDING_CLEANUP = "pending_update_apk_cleanup"
    private const val KEY_PRE_UPDATE_BUILD = "pre_update_build"
    private const val APK_NAME = "fctv33-update.apk"

    fun updateDirectory(context: Context): File =
        File(context.cacheDir, "updates")

    fun updateApk(context: Context): File =
        File(updateDirectory(context), APK_NAME)

    fun markPendingCleanup(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_PENDING_CLEANUP, true)
            .putLong(KEY_PRE_UPDATE_BUILD, currentBuild(context))
            .apply()
    }

    fun deleteCachedApk(context: Context) {
        val apk = updateApk(context)
        if (apk.exists()) apk.delete()
        val dir = updateDirectory(context)
        if (dir.isDirectory && dir.list().isNullOrEmpty()) {
            dir.delete()
        }
        // Also drop legacy flat-cache APKs from older updater builds.
        listOfNotNull(context.cacheDir, context.externalCacheDir).forEach { root ->
            root.listFiles()
                ?.filter { it.isFile && it.name.endsWith(".apk", ignoreCase = true) }
                ?.forEach { runCatching { it.delete() } }
        }
        clearPending(context)
    }

    /**
     * After a successful self-update the process restarts with a higher
     * versionCode — delete the cached APK. If the user cancelled the
     * installer, the build is unchanged: keep the file for retry.
     */
    fun cleanupIfPending(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_PENDING_CLEANUP, false)) return
        val before = prefs.getLong(KEY_PRE_UPDATE_BUILD, -1L)
        val now = currentBuild(context)
        if (before >= 0L && now > before) {
            deleteCachedApk(context)
        } else {
            // Same build → install dismissed; keep APK, drop the flag.
            clearPending(context)
        }
    }

    private fun clearPending(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_PENDING_CLEANUP, false)
            .remove(KEY_PRE_UPDATE_BUILD)
            .apply()
    }

    private fun currentBuild(context: Context): Long {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }
}
