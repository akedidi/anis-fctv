package com.fctv33.fctv33

import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Intent
import android.content.ClipData
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
    private var platformBridge: MethodChannel? = null
    @Volatile private var updateInFlight = false
    @Volatile private var lastProgressEmitMs = 0L
    private var pendingUpdateUrl: String? = null
    private var pendingUpdateSha256: String? = null

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

    override fun onResume() {
        super.onResume()
        resumePendingUpdateIfReady()
    }

    override fun onDestroy() {
        platformBridge = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platformBridge = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        platformBridge!!.setMethodCallHandler { call, result ->
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

    private fun emitUpdateProgress(
        phase: String,
        received: Long = 0L,
        total: Long = 0L,
        attempt: Int = 1,
        maxAttempts: Int = 3,
        error: String? = null,
    ) {
        val payload = HashMap<String, Any?>().apply {
            put("phase", phase)
            put("received", received)
            put("total", total)
            put("attempt", attempt)
            put("maxAttempts", maxAttempts)
            if (error != null) put("error", error)
        }
        runOnUiThread {
            platformBridge?.invokeMethod("updateInstallProgress", payload)
        }
    }

    private fun installUpdate(url: String, expectedSha256: String): String {
        if (!url.startsWith("https://")) return "invalid_url"
        if (updateInFlight) return "busy"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            // Remember the request so returning from Settings starts the download
            // without needing a 2nd click.
            pendingUpdateUrl = url
            pendingUpdateSha256 = expectedSha256
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return "settings"
        }

        pendingUpdateUrl = null
        pendingUpdateSha256 = null
        beginUpdateDownload(url, expectedSha256)
        return "started"
    }

    private fun resumePendingUpdateIfReady() {
        val url = pendingUpdateUrl ?: return
        if (updateInFlight) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            return
        }
        val sha = pendingUpdateSha256.orEmpty()
        pendingUpdateUrl = null
        pendingUpdateSha256 = null
        installUpdate(url, sha)
    }

    private fun beginUpdateDownload(url: String, expectedSha256: String) {
        if (updateInFlight) return
        updateInFlight = true
        val maxAttempts = 3
        Thread {
            val apk = UpdateApkCleanup.updateApk(this)
            var lastError: Exception? = null
            try {
                UpdateApkCleanup.updateDirectory(this).mkdirs()
                // If a previous attempt left a valid APK, skip straight to install
                // (this is what the user experienced as needing a "2nd click").
                if (apk.exists() &&
                    expectedSha256.isNotBlank() &&
                    sha256Of(apk).equals(expectedSha256.trim(), ignoreCase = true)
                ) {
                    try {
                        emitUpdateProgress(
                            phase = "installing",
                            received = apk.length(),
                            total = apk.length(),
                        )
                        UpdateApkCleanup.markPendingCleanup(this)
                        openInstaller(apk)
                        emitUpdateProgress(
                            phase = "awaiting_user",
                            received = apk.length(),
                            total = apk.length(),
                        )
                        return@Thread
                    } catch (error: Exception) {
                        lastError = error
                    }
                }
                for (attempt in 1..maxAttempts) {
                    try {
                        if (apk.exists()) apk.delete()
                        emitUpdateProgress(
                            phase = if (attempt == 1) "downloading" else "retrying",
                            attempt = attempt,
                            maxAttempts = maxAttempts,
                        )
                        // Always cache-bust — TV CDNs often serve a bad body on
                        // the first pristine URL hit.
                        val downloadUrl = Uri.parse(url).buildUpon()
                            .appendQueryParameter("t", System.currentTimeMillis().toString())
                            .appendQueryParameter("attempt", attempt.toString())
                            .build()
                            .toString()
                        downloadFollowingRedirects(downloadUrl, apk, attempt, maxAttempts)

                        if (expectedSha256.isNotBlank()) {
                            emitUpdateProgress(
                                phase = "verifying",
                                received = apk.length(),
                                total = apk.length(),
                                attempt = attempt,
                                maxAttempts = maxAttempts,
                            )
                            val digest = MessageDigest.getInstance("SHA-256")
                            apk.inputStream().buffered().use { input ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    digest.update(buffer, 0, count)
                                }
                            }
                            val actual = digest.digest().joinToString("") {
                                "%02x".format(it)
                            }
                            if (!actual.equals(expectedSha256.trim(), ignoreCase = true)) {
                                UpdateApkCleanup.deleteCachedApk(this)
                                throw IllegalStateException("SHA-256 mismatch")
                            }
                        }

                        emitUpdateProgress(
                            phase = "installing",
                            received = apk.length(),
                            total = apk.length(),
                            attempt = attempt,
                            maxAttempts = maxAttempts,
                        )
                        // Remember to wipe the APK once the new package is running.
                        UpdateApkCleanup.markPendingCleanup(this)
                        // Brief settle so TV FS sees the fully synced APK.
                        try {
                            Thread.sleep(400)
                        } catch (_: InterruptedException) {
                        }
                        openInstaller(apk)
                        emitUpdateProgress(
                            phase = "awaiting_user",
                            received = apk.length(),
                            total = apk.length(),
                            attempt = attempt,
                            maxAttempts = maxAttempts,
                        )
                        return@Thread
                    } catch (error: Exception) {
                        lastError = error
                        // Keep a verified APK when only the installer UI failed —
                        // deleting forced a full 2nd download for the user.
                        val installerOnly = error.message?.contains("Installateur") == true ||
                            error is android.content.ActivityNotFoundException
                        if (!installerOnly) {
                            UpdateApkCleanup.deleteCachedApk(this)
                        }
                        if (attempt < maxAttempts) {
                            emitUpdateProgress(
                                phase = "retrying",
                                attempt = attempt + 1,
                                maxAttempts = maxAttempts,
                                error = error.message,
                            )
                            try {
                                Thread.sleep(1_200L * attempt)
                            } catch (_: InterruptedException) {
                            }
                        }
                    }
                }
                val message = lastError?.message ?: "téléchargement"
                emitUpdateProgress(
                    phase = "failed",
                    attempt = maxAttempts,
                    maxAttempts = maxAttempts,
                    error = message,
                )
                runOnUiThread {
                    Toast.makeText(
                        this,
                        "Échec MAJ: $message",
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
            } finally {
                updateInFlight = false
            }
        }.start()
    }

    /** Follows cross-host HTTPS redirects manually (GitHub → CDN). */
    private fun downloadFollowingRedirects(
        url: String,
        target: File,
        attempt: Int,
        maxAttempts: Int,
    ) {
        var current = url
        repeat(8) {
            val connection = (URL(current).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = 30_000
                readTimeout = 300_000
                setRequestProperty("User-Agent", "FCTV33-Android-Updater")
                setRequestProperty("Accept", "*/*")
                setRequestProperty("Cache-Control", "no-cache")
                setRequestProperty("Pragma", "no-cache")
            }
            try {
                val code = connection.responseCode
                when {
                    code in 300..399 -> {
                        val location = connection.getHeaderField("Location")
                            ?: throw IOException("HTTP $code sans Location")
                        val next = URI(current).resolve(location)
                        if (!next.scheme.equals("https", ignoreCase = true)) {
                            throw IOException("Redirection non HTTPS")
                        }
                        current = next.toString()
                    }
                    code == HttpURLConnection.HTTP_OK -> {
                        val total = connection.contentLengthLong.coerceAtLeast(0L)
                        var received = 0L
                        lastProgressEmitMs = 0L
                        connection.inputStream.use { input ->
                            FileOutputStream(target).use { fileOut ->
                                fileOut.channel.truncate(0)
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    fileOut.write(buffer, 0, count)
                                    received += count
                                    val now = System.currentTimeMillis()
                                    if (now - lastProgressEmitMs >= 250L ||
                                        (total > 0L && received >= total)
                                    ) {
                                        lastProgressEmitMs = now
                                        emitUpdateProgress(
                                            phase = "downloading",
                                            received = received,
                                            total = total,
                                            attempt = attempt,
                                            maxAttempts = maxAttempts,
                                        )
                                    }
                                }
                                fileOut.flush()
                                fileOut.fd.sync()
                            }
                        }
                        if (received <= 0L) {
                            throw IOException("Fichier vide")
                        }
                        if (total > 0L && received < total) {
                            throw IOException("Téléchargement incomplet ($received/$total)")
                        }
                        emitUpdateProgress(
                            phase = "downloading",
                            received = received,
                            total = if (total > 0L) total else received,
                            attempt = attempt,
                            maxAttempts = maxAttempts,
                        )
                        return
                    }
                    else -> throw IOException("HTTP $code")
                }
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("Trop de redirections")
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Open the complete system APK installer, including its Open/Done result
     * screen. Session confirmation alone closes automatically after installing.
     * Safe to call from a background thread (intent launch hops to the UI).
     */
    private fun openInstaller(apk: File) {
        if (!apk.exists() || apk.length() <= 0L) {
            throw IOException("APK manquant")
        }
        var lastError: Exception? = null
        // Retry only if Android could not launch the installer at all.
        repeat(3) { index ->
            try {
                openInstallerWithIntentOnUiThread(apk)
                return
            } catch (error: Exception) {
                lastError = error
                if (index < 2) {
                    try {
                        Thread.sleep(700L * (index + 1))
                    } catch (_: InterruptedException) {
                    }
                }
            }
        }
        throw lastError ?: IOException("Installateur non ouvert")
    }

    private fun openInstallerWithIntentOnUiThread(apk: File) {
        val opened = AtomicBoolean(false)
        val errorRef = AtomicReference<Exception?>(null)
        val latch = CountDownLatch(1)
        runOnUiThread {
            try {
                openInstallerWithIntent(apk)
                opened.set(true)
            } catch (error: Exception) {
                errorRef.set(error)
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(8, TimeUnit.SECONDS) || !opened.get()) {
            throw errorRef.get() ?: IOException("Installateur non ouvert")
        }
    }

    private fun openInstallerWithIntent(apk: File) {
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk,
        )
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            clipData = ClipData.newRawUri("FCTV33 update", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }
        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            data = uri
            clipData = ClipData.newRawUri("FCTV33 update", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }
        @Suppress("DEPRECATION")
        val candidates = listOf(viewIntent, installIntent)
        var launched = false
        for (intent in candidates) {
            val resolved = packageManager.queryIntentActivities(intent, 0)
            for (info in resolved) {
                grantUriPermission(
                    info.activityInfo.packageName,
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                launched = true
                break
            }
        }
        if (!launched) {
            startActivity(viewIntent)
        }
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
