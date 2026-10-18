package com.fctv33.fctv33

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "com.fctv33.fctv33/platform"
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAndroidTv" -> result.success(isAndroidTv())
                    "isAndroidEmulator" -> result.success(isAndroidEmulator())
                    "enterPictureInPicture" -> result.success(enterPip())
                    "setKeepScreenOn" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        setKeepScreenOn(enabled)
                        result.success(null)
                    }
                    "getAppVersion" -> {
                        try {
                            val pInfo = if (Build.VERSION.SDK_INT >= 33) {
                                packageManager.getPackageInfo(
                                    packageName,
                                    PackageManager.PackageInfoFlags.of(0),
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getPackageInfo(packageName, 0)
                            }
                            val code = if (Build.VERSION.SDK_INT >= 28) {
                                pInfo.longVersionCode.toInt()
                            } else {
                                @Suppress("DEPRECATION")
                                pInfo.versionCode
                            }
                            result.success(
                                mapOf(
                                    "versionCode" to code,
                                    "versionName" to (pInfo.versionName ?: ""),
                                ),
                            )
                        } catch (e: Exception) {
                            result.error("version", e.message, null)
                        }
                    }
                    "installApkFromUrl" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "fctv33-update.apk"
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url required", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            try {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            } catch (_: Exception) {
                            }
                            result.error(
                                "permission",
                                "Allow installs from this app, then tap Update again.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        io.execute {
                            try {
                                val apk = downloadApk(url, fileName)
                                runOnUiThread {
                                    try {
                                        launchInstaller(apk)
                                        result.success(null)
                                    } catch (e: Exception) {
                                        result.error("install", e.message, null)
                                    }
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("download", e.message ?: "Download failed", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun downloadApk(url: String, fileName: String): File {
        val dest = File(cacheDir, fileName)
        if (dest.exists()) dest.delete()
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = true
            connectTimeout = 30_000
            readTimeout = 120_000
            requestMethod = "GET"
            setRequestProperty("User-Agent", "FCTV33-Updater")
        }
        conn.inputStream.use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        }
        conn.disconnect()
        if (!dest.exists() || dest.length() < 1024) {
            throw IllegalStateException("APK download incomplete")
        }
        return dest
    }

    private fun launchInstaller(apk: File) {
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isAndroidTv()) {
            // TV is landscape-first; keep the leanback shell stable.
            requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            // System soft IME steals mouse/D-pad on TV emulators — hide it always.
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        }
        // After a successful sideload, the new process starts with a higher versionCode.
        // Drop leftover updater APKs from cache (installer does not delete them).
        maybeClearUpdateApkCache()
    }

    private fun currentVersionCode(): Int {
        return try {
            val pInfo = if (Build.VERSION.SDK_INT >= 33) {
                packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            if (Build.VERSION.SDK_INT >= 28) pInfo.longVersionCode.toInt()
            else {
                @Suppress("DEPRECATION")
                pInfo.versionCode
            }
        } catch (_: Exception) {
            0
        }
    }

    private fun maybeClearUpdateApkCache() {
        val prefs = getSharedPreferences("fctv_updater", MODE_PRIVATE)
        val current = currentVersionCode()
        if (current <= 0) return
        val previous = prefs.getInt("last_launched_version_code", 0)
        if (previous > 0 && current > previous) {
            clearUpdateApks()
        }
        if (current != previous) {
            prefs.edit().putInt("last_launched_version_code", current).apply()
        }
    }

    private fun clearUpdateApks() {
        val dirs = listOfNotNull(cacheDir, externalCacheDir)
        for (dir in dirs) {
            dir.listFiles()
                ?.filter { it.isFile && it.name.endsWith(".apk", ignoreCase = true) }
                ?.forEach { runCatching { it.delete() } }
        }
    }

    private fun isAndroidTv(): Boolean {
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return packageManager.hasSystemFeature("android.software.leanback")
    }

    private fun isAndroidEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT.lowercase()
        val model = Build.MODEL.lowercase()
        val product = Build.PRODUCT.lowercase()
        val hardware = Build.HARDWARE.lowercase()
        val manufacturer = Build.MANUFACTURER.lowercase()
        return fingerprint.contains("generic") ||
            fingerprint.contains("emulator") ||
            model.contains("google_sdk") ||
            model.contains("emulator") ||
            model.contains("android sdk") ||
            product.contains("sdk") ||
            product.contains("emulator") ||
            product.contains("vbox") ||
            hardware.contains("goldfish") ||
            hardware.contains("ranchu") ||
            manufacturer.contains("genymotion")
    }

    /**
     * Prevent Android TV screensaver / display sleep while a stream is active.
     * Without this, idle timeout blanks the TV even though video is playing
     * (remote inactivity is treated as user idle).
     */
    private fun setKeepScreenOn(enabled: Boolean) {
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    /** System PiP for phones only — not offered on Android TV. */
    private fun enterPip(): Boolean {
        if (isAndroidTv()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            return false
        }
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        } catch (_: Exception) {
            false
        }
    }
}
