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
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val channelName = "com.fctv33.fctv33/platform"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isAndroidTv()) {
            // TV is landscape-first; keep the leanback shell stable.
            requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            // System soft IME steals mouse/D-pad on TV emulators — hide it always.
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        }
        // After a successful self-update the process restarts with this flag set.
        UpdateApkCleanup.cleanupIfPending(this)
    }

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
                            result.success(appVersion())
                        } catch (e: Exception) {
                            result.error("version", e.message, null)
                        }
                    }
                    // AnisFlix-compatible internal updater (async download → system installer).
                    "installUpdate", "installApkFromUrl" -> result.success(
                        installUpdate(
                            call.argument<String>("url").orEmpty(),
                            call.argument<String>("sha256").orEmpty(),
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun appVersion(): Map<String, Any> {
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
        return mapOf(
            "versionCode" to code,
            "versionName" to (pInfo.versionName ?: ""),
        )
    }

    /**
     * Starts download on a background thread and returns immediately.
     * Status: started | settings | invalid_url
     */
    private fun installUpdate(url: String, expectedSha256: String): String {
        if (!url.startsWith("https://")) return "invalid_url"
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
            return "settings"
        }

        Thread {
            try {
                UpdateApkCleanup.updateDirectory(this).mkdirs()
                val apk = UpdateApkCleanup.updateApk(this)
                if (apk.exists()) apk.delete()
                // GitHub release assets 302 to release-assets.githubusercontent.com.
                // HttpURLConnection auto-redirect often surfaces that as a 404 on Fire TV.
                downloadFollowingRedirects(url, apk)

                if (!apk.exists() || apk.length() < 1024) {
                    throw IllegalStateException("APK download incomplete")
                }

                if (expectedSha256.isNotBlank()) {
                    val digest = MessageDigest.getInstance("SHA-256")
                    apk.inputStream().buffered().use { input ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            digest.update(buffer, 0, count)
                        }
                    }
                    val actual = digest.digest().joinToString("") { "%02x".format(it) }
                    if (!actual.equals(expectedSha256.trim(), ignoreCase = true)) {
                        UpdateApkCleanup.deleteCachedApk(this)
                        throw IllegalStateException("SHA-256 mismatch")
                    }
                }

                // Remember to wipe the APK once the new package is running.
                UpdateApkCleanup.markPendingCleanup(this)
                runOnUiThread { openInstaller(apk) }
            } catch (error: Exception) {
                runOnUiThread {
                    Toast.makeText(
                        this,
                        "Update failed: ${error.message ?: "download"}",
                        Toast.LENGTH_LONG,
                    ).show()
                    // Last resort: open the release URL in the browser / downloader.
                    try {
                        startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK,
                            ),
                        )
                    } catch (_: Exception) {
                    }
                }
            }
        }.start()
        return "started"
    }

    /** Follows cross-host HTTPS redirects manually (GitHub → CDN). */
    private fun downloadFollowingRedirects(url: String, target: File) {
        var current = url
        repeat(8) {
            val connection = (URL(current).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = 30_000
                readTimeout = 300_000
                requestMethod = "GET"
                setRequestProperty("User-Agent", "FCTV33-Updater")
                setRequestProperty("Accept", "*/*")
            }
            try {
                val code = connection.responseCode
                when {
                    code in 300..399 -> {
                        val location = connection.getHeaderField("Location")
                            ?: throw IOException("HTTP $code without Location")
                        current = URI(current).resolve(location).toString()
                    }
                    code == HttpURLConnection.HTTP_OK -> {
                        connection.inputStream.use { input ->
                            target.outputStream().buffered().use { output ->
                                input.copyTo(output)
                            }
                        }
                        return
                    }
                    else -> throw IOException("HTTP $code")
                }
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("Too many redirects")
    }

    private fun openInstaller(apk: File) {
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk,
        )
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    private fun isAndroidTv(): Boolean {
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        // Fire TV Stick / Cube (Amazon Fire OS) — leanback is not always reported.
        if (packageManager.hasSystemFeature("amazon.hardware.fire_tv")) return true
        if (packageManager.hasSystemFeature("android.software.leanback")) return true
        val manufacturer = Build.MANUFACTURER.lowercase()
        val model = Build.MODEL.lowercase()
        // Fire TV devices use AFT* model codes (AFTSS, AFTMMM, …).
        if (manufacturer.contains("amazon") && model.startsWith("aft")) return true
        return false
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
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
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
