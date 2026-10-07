package com.mangacolorizer.manga_colorizer_mobile

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 两条自定义平台通道：
//   manga_colorizer/device   —— Dart 侧 ResourceTier.detect() 读
//     ActivityManager.MemoryInfo，按设备内存定资源档位（选图上限/推理线程）。
//   manga_colorizer/inference —— Dart 侧 socket_worker.dart 起/停 :inference
//     独立推理进程的 InferenceService（start 同时请求通知权限；拒绝不阻塞，
//     FGS 照常运行、只是通知不展示）。
// 通道名与 Dart 侧字面量必须一致（resource_tier.dart / socket_worker.dart）。
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manga_colorizer/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "memoryInfo" -> {
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val mem = ActivityManager.MemoryInfo()
                        am.getMemoryInfo(mem)
                        result.success(
                            mapOf(
                                "totalMem" to mem.totalMem,
                                "lowRam" to am.isLowRamDevice,
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manga_colorizer/inference")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        requestNotificationPermissionIfNeeded()
                        val intent = Intent(this, InferenceService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this, InferenceService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4101)
        }
    }
}
