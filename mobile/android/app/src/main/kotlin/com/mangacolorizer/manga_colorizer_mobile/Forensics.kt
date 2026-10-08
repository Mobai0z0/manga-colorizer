package com.mangacolorizer.manga_colorizer_mobile

// v0.5.16 断连取证：原生信号遗嘱的 Kotlin 桥。
//
// :inference 进程死亡时 ROM 拒绝 ApplicationExitInfo 查询（v0.5.15 真机
// 实锤：SecurityException requires android.permission.DUMP），logcat 是
// 唯一取证来源。C 层（app_native/forensics.c）在 fatal 信号上下文里写
// 一份遗嘱文件（signal 编号 + 触发地址）后 re-raise——遗嘱存在＝原生崩
// 溃（编号即死因）；遗嘱缺失＋心跳活跃＝SIGKILL 被杀。
//
// 设计约束：
//   · 独立小对象，不持任何 Android 组件引用——:inference 进程的
//     InferenceService 与主进程都可安装，互不干扰（遗嘱路径按进程区分）。
//   · install 幂等：重复调用只刷新路径（C 层 g_will_path 覆写 + sigaction
//     重装，语义不变）。
//   · 任何异常都吞掉返回 false——取证设施绝不能妨碍推理主链路。
object Forensics {
    @Volatile
    var lastError: String? = null
        private set

    @Volatile
    var available: Boolean = false
        private set

    /** System.loadLibrary 的隔离：失败（ exotic ROM/裁剪 NDK）不抛出。 */
    private fun load(): Boolean = try {
        System.loadLibrary("app_native")
        true
    } catch (t: Throwable) {
        lastError = "${t.javaClass.simpleName}: ${t.message}"
        false
    }

    private val loaded: Boolean by lazy { load() }

    /** 安装 fatal 信号遗嘱。path＝遗嘱文件绝对路径（应用私有目录内）。 */
    fun install(path: String): Boolean {
        if (!loaded) return false
        available = try {
            val rc = installNativeWills(path)
            if (rc != 0) {
                lastError = "sigaction 失败 rc=$rc"
                false
            } else {
                true
            }
        } catch (t: Throwable) {
            // UnsatisfiedLinkError（符号缺失）等：取证不可用但不伤主链路。
            lastError = "${t.javaClass.simpleName}: ${t.message}"
            false
        }
        return available
    }

    /**
     * v0.5.17：stderr 重定向落盘（dup2 fd2→文件）。
     * path＝stderr 镜像文件绝对路径（应用私有目录内）。O_TRUNC：进程每次
     * 新生清空。失败只记 lastError，绝不抛出。
     */
    fun redirectStderr(path: String): Boolean {
        if (!loaded) return false
        return try {
            val rc = installStderrRedirection(path)
            if (rc != 0) {
                lastError = "stderr 重定向失败 rc=$rc"
                false
            } else {
                true
            }
        } catch (t: Throwable) {
            lastError = "${t.javaClass.simpleName}: ${t.message}"
            false
        }
    }

    private external fun installNativeWills(path: String): Int

    private external fun installStderrRedirection(path: String): Int
}
