package com.pedrocesar.comboio

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "comboio/native"
        private const val PERMISSION_REQUEST = 4210
    }

    private var channel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var networkHelper: NetworkHelper? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        networkHelper = NetworkHelper(applicationContext)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result -> onMethodCall(call, result) }
        channel = ch
        IntercomService.actionListener = { action ->
            runOnUiThread { channel?.invokeMethod("notificationAction", action) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        IntercomService.actionListener = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestPermissions" -> requestAppPermissions(result)
                "permissionStatus" -> result.success(permissionStatus())
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(null)
                }
                "openHotspotSettings" -> {
                    openHotspotSettings()
                    result.success(null)
                }
                "startService" -> {
                    result.success(
                        startIntercomService(
                            call.argument<String>("title") ?: "Comboio",
                            call.argument<String>("text") ?: "",
                            call.argument<Boolean>("muted") ?: false,
                        )
                    )
                }
                "updateService" -> {
                    IntercomService.instance?.update(
                        call.argument<String>("title") ?: "Comboio",
                        call.argument<String>("text") ?: "",
                        call.argument<Boolean>("muted") ?: false,
                    )
                    result.success(null)
                }
                "stopService" -> {
                    stopService(Intent(this, IntercomService::class.java))
                    result.success(null)
                }
                "networkInfo" -> result.success(networkHelper?.info())
                "bindToWifi" -> result.success(networkHelper?.bindToWifi())
                "unbindNetwork" -> {
                    networkHelper?.unbind()
                    result.success(null)
                }
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    // ------------------------------------------------------------ permissões

    private fun neededPermissions(): List<String> {
        val list = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return list
    }

    private fun isGranted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun requestAppPermissions(result: MethodChannel.Result) {
        val missing = neededPermissions().filter { !isGranted(it) }
        if (missing.isEmpty()) {
            result.success(permissionStatus())
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "Já existe um pedido de permissão aberto", null)
            return
        }
        pendingPermissionResult = result
        requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            val pending = pendingPermissionResult
            pendingPermissionResult = null
            pending?.success(permissionStatus())
        }
    }

    private fun permissionStatus(): Map<String, Any> {
        val bluetooth = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            isGranted(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            true
        }
        val notifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            isGranted(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            true
        }
        return mapOf(
            "microphone" to isGranted(Manifest.permission.RECORD_AUDIO),
            "bluetooth" to bluetooth,
            "notifications" to notifications,
        )
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        intent.data = Uri.fromParts("package", packageName, null)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun openHotspotSettings() {
        val candidates = listOf(
            Intent().setComponent(
                ComponentName("com.android.settings", "com.android.settings.TetherSettings")
            ),
            Intent().setComponent(
                ComponentName(
                    "com.android.settings",
                    "com.android.settings.Settings\$TetherSettingsActivity"
                )
            ),
            Intent(Settings.ACTION_WIRELESS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return
            } catch (ignored: Exception) {
                // tenta o próximo
            }
        }
    }

    // --------------------------------------------------- serviço em 1º plano

    private fun startIntercomService(title: String, text: String, muted: Boolean): Boolean {
        if (!isGranted(Manifest.permission.RECORD_AUDIO)) return false
        val intent = Intent(this, IntercomService::class.java).apply {
            action = IntercomService.ACTION_START
            putExtra("title", title)
            putExtra("text", text)
            putExtra("muted", muted)
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------------------- bateria

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (ignored: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (alsoIgnored: Exception) {
            }
        }
    }
}
