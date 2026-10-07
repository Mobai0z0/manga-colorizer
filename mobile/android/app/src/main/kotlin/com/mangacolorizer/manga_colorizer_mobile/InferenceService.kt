package com.mangacolorizer.manga_colorizer_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * :inference 独立进程的托管服务（架构参考 xororz/local-dream 的 BackendService）：
 * 推理跑在独立进程的 headless FlutterEngine 里（Dart 入口 inferenceMain，
 * 在 127.0.0.1 上提供帧协议服务，见 mobile/lib/inference/），原生崩溃或被系统
 * 所杀只终结本进程，UI 进程存活可报错重试；进程死亡即 ORT 双 session 全部
 * 归还——会话没有滞留路径。
 *
 * dataSync 前台服务：上色任务分钟级，用户选择「推理中切后台跑完」；FGS 同时
 * 抬高 oom_adj，压低 lowmemorykiller 命中 :inference 的概率。
 *
 * onStartCommand 幂等（引擎已建则只刷新前台通知）；stopService → onDestroy
 * 销毁引擎（Dart isolate 与其 ServerSocket 一并终止，进程随空载退出）。
 */
class InferenceService : Service() {
    private var engine: FlutterEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        if (engine == null) {
            val loader = FlutterInjector.instance().flutterLoader()
            val entry = DartEntrypoint(loader.findAppBundlePath(), "inferenceMain")
            engine = FlutterEngineGroup(this).createAndRunEngine(this, entry).also {
                // 手动创建的引擎不会自动注册插件：flutter_onnxruntime 的 ORT
                // 平台通道全靠这里挂上。
                GeneratedPluginRegistrant.registerWith(it)
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    private fun startAsForeground() {
        val notification = buildNotification("上色推理进行中")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "上色推理",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "推理进程前台服务保活通知"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Manga Colorizer")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "inference"
        private const val NOTIFICATION_ID = 0x1A17
    }
}
