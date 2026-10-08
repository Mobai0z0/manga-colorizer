package com.mangacolorizer.manga_colorizer_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File

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
        // v0.5.16 断连取证：本进程（:inference）安装原生遗嘱 + 心跳。
        // 幂等：重复 start 只重装（C 层覆写路径 + sigaction 语义不变）。
        // 取证失败绝不伤推理主链路（Forensics.install 内部已吞异常）。
        // 目录必须在这里建好：崩溃可能发生在 Dart 心跳（forensics/ 的另一
        // 个创建者）启动之前，届时 C 层 open(O_CREAT) 会因目录缺失而静默
        // 丢失遗嘱。
        runCatching { File(cacheDir, "forensics").mkdirs() }
        Forensics.install(cacheDir.resolve("forensics/will").absolutePath)
        // v0.5.17 取证：stderr（fd2）重定向落盘。Android 上进程 stderr 默认
        // 直通 /dev/null——SIGABRT 前 ORT/std::terminate/assert 写到 stderr
        // 的报错原文全部丢失；dup2 到文件后按时间序落盘（Dart 侧
        // '[manga-inference]' 日志镜像同 fd 同框）。必须在引擎创建前做：
        // ORT session 创建/Run 的报错都要赶在第一个字节出现之前接住。
        // O_TRUNC=进程每次新生清空；幂等重入（engine!=null）不会误清。
        Forensics.redirectStderr(cacheDir.resolve("forensics/stderr.log").absolutePath)
        // 心跳由 Dart 侧 inferenceMain 启动（path_provider 需 binding 先行）。
        if (engine == null) {
            try {
                // :inference 进程没有 FlutterActivity，Application 又是 Flutter
                // gradle 插件的默认占位符 android.app.Application（onCreate 不做
                // 引擎初始化），本进程必须在这里手动初始化 FlutterLoader——
                // findAppBundlePath 读的 flutterApplicationInfo 只在
                // startInitialization 里赋值，漏掉这行会在下一步直接 NPE 崩掉
                // 推理进程（v0.5.9 真机「连接全部被拒 → 回退 isolate」根因之一）。
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(this)
                val entry = DartEntrypoint(loader.findAppBundlePath(), "inferenceMain")
                engine = FlutterEngineGroup(this).createAndRunEngine(this, entry).also {
                    // 手动创建的引擎不会自动注册插件：flutter_onnxruntime 的 ORT
                    // 平台通道全靠这里挂上。
                    GeneratedPluginRegistrant.registerWith(it)
                }
            } catch (t: Throwable) {
                // 引擎起不来（初始化异常/OOM 等）：前台服务停掉留 logcat 痕迹，
                // 主进程侧由连接超时统一回退进程内 isolate。
                Log.w(TAG, "inference engine failed to start", t)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engine?.destroy()
        engine = null
        super.onDestroy()
        // 停服即自杀：不杀死进程的话，下一次 start 会在同一进程里重建引擎，
        // 被销毁引擎的原生残留（ORT 会话缓冲、分配器碎片）滞留在进程里
        // （真机实测同进程第二次加载 RSS +90MB）；进程死亡同时把「会话必然
        // 归还」从依赖引擎销毁的软保证变成硬保证。下一次 start 必得全新进程。
        android.os.Process.killProcess(android.os.Process.myPid())
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
        private const val TAG = "InferenceService"
        private const val CHANNEL_ID = "inference"
        private const val NOTIFICATION_ID = 0x1A17
    }
}
