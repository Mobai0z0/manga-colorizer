package com.mangacolorizer.manga_colorizer_mobile

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 三条自定义平台通道：
//   manga_colorizer/device   —— Dart 侧 ResourceTier.detect() 读
//     ActivityManager.MemoryInfo，按设备内存定资源档位（选图上限/推理线程）。
//   manga_colorizer/inference —— Dart 侧 socket_worker.dart 起/停 :inference
//     独立推理进程的 InferenceService（start 同时请求通知权限；拒绝不阻塞，
//     FGS 照常运行、只是通知不展示）；exitReason 查询该进程上次的系统退出
//     原因（ApplicationExitInfo），worker 死亡日志据此从「进程退出或被杀」
//     升级为可行动的根因（LMK / 原生崩溃 / ANR）。
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
                    "exitReason" -> result.success(lastInferenceExitReason())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * :inference 进程最近一次退出的系统记录（API 30+；getHistoricalProcessExitReasons
     * 只查本包进程，无需额外权限）。只认 10 分钟内的新鲜记录：进程若仍存活，历史
     * 缓冲里最新的条目属于更早的退出（例如我方停服），拿来解释本次断连反而误导。
     * 命中新鲜记录时附带次新一条作上下文（区分「本次死亡」与「上次停服残留」）。
     * 无记录/过期/低版本一律返回 null，Dart 侧重试后归入「无退出记录」表述。
     */
    private fun lastInferenceExitReason(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        // v0.5.14 取证加固：部分 ROM 的 ApplicationExitInfo 实现有怪癖（安全
        // 异常、parcel 异常等），异常一旦抛回 Dart 会被当作「通道不可用」吞掉，
        // 取证链断在通道层——改为异常转诊断文字透传，证据不丢。
        return try {
            queryInferenceExitReason()
        } catch (t: Throwable) {
            "退出记录查询异常: ${t.javaClass.simpleName}: ${t.message}"
        }
    }

    private fun queryInferenceExitReason(): String? {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val records = am.getHistoricalProcessExitReasons("$packageName:inference", 0, 2)
        if (records.isEmpty()) return null
        val newest = records[0]
        val ageMs = System.currentTimeMillis() - newest.timestamp
        if (ageMs < 0 || ageMs > EXIT_REASON_FRESH_MS) return null
        var text = "${describeExitReason(newest)}（${ageMs / 1000}s 前）"
        if (records.size > 1) {
            val olderAgeMs = System.currentTimeMillis() - records[1].timestamp
            if (olderAgeMs in 0..EXIT_REASON_FRESH_MS) {
                text += "；更早：${describeExitReason(records[1])}（${olderAgeMs / 1000}s 前）"
            }
        }
        return text
    }

    private fun describeExitReason(info: ApplicationExitInfo): String {
        // 信号编号在 status（REASON_SIGNALED / REASON_CRASH_NATIVE）；其余码的
        // status/description 原样带出——系统侧的表述比我们的映射更可信，映射
        // 错了证据也不丢。
        val base = when (info.reason) {
            ApplicationExitInfo.REASON_EXIT_SELF -> "自行退出(exit)"
            ApplicationExitInfo.REASON_SIGNALED -> "被信号终止(signal=${info.status})"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "系统低内存回收(LMK)"
            ApplicationExitInfo.REASON_CRASH -> "应用崩溃(status=${info.status})"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "原生崩溃(signal=${info.status})"
            ApplicationExitInfo.REASON_ANR -> "ANR 主线程无响应"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "初始化失败"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "资源超限被系统终止"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "用户请求停止"
            ApplicationExitInfo.REASON_USER_STOPPED -> "被用户/任务管理停止"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "权限变更被杀"
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "应用状态变更被杀"
            else -> "退出码 ${info.reason}"
        }
        val desc = info.description
        return if (desc.isNullOrEmpty()) base else "$base: $desc"
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4101)
        }
    }

    private companion object {
        const val EXIT_REASON_FRESH_MS = 10 * 60_000L
    }
}
