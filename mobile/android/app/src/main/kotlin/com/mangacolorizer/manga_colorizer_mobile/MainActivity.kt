package com.mangacolorizer.manga_colorizer_mobile

import android.app.ActivityManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 唯一的自定义平台通道 manga_colorizer/device：Dart 侧 ResourceTier.detect()
// 经它读 ActivityManager.MemoryInfo，按设备内存定资源档位（选图上限/推理线程）。
// 通道名与 mobile/lib/resource_tier.dart 的 MethodChannel 字面量必须一致。
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
    }
}
