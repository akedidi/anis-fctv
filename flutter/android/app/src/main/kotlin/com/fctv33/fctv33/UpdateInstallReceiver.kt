package com.fctv33.fctv33

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import android.widget.Toast

/**
 * Handles [PackageInstaller] session results. On modern Android/TV the install
 * UI is not shown until we forward [PackageInstaller.STATUS_PENDING_USER_ACTION].
 */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        Log.i("FCTV33Update", "Installer result: status=$status")
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm != null) {
                    try {
                        confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(confirm)
                        MainActivity.emitUpdateProgressFromOutside(
                            phase = "awaiting_user",
                        )
                    } catch (error: Exception) {
                        UpdateApkCleanup.cancelPendingRelaunch(context)
                        Toast.makeText(
                            context,
                            "Installateur: ${error.message}",
                            Toast.LENGTH_LONG,
                        ).show()
                        MainActivity.emitUpdateProgressFromOutside(
                            phase = "failed",
                            error = error.message,
                        )
                    }
                } else {
                    UpdateApkCleanup.cancelPendingRelaunch(context)
                    MainActivity.emitUpdateProgressFromOutside(
                        phase = "failed",
                        error = "Confirmation installateur manquante",
                    )
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                MainActivity.emitUpdateProgressFromOutside(phase = "done")
                // MY_PACKAGE_REPLACED owns the return, after the installer's
                // task has closed. Do not consume its one-shot flag here.
            }
            else -> {
                UpdateApkCleanup.cancelPendingRelaunch(context)
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    ?: "status=$status"
                Toast.makeText(context, "Échec install: $message", Toast.LENGTH_LONG).show()
                MainActivity.emitUpdateProgressFromOutside(
                    phase = "failed",
                    error = message,
                )
            }
        }
    }
}
