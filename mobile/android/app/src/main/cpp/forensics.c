// v0.5.16/17 断连取证：原生信号遗嘱 + 崩溃 backtrace + maps 快照 + stderr 重定向。
//
// 背景：:inference 进程在首个 ORT Run 内部死亡（v0.5.13/14/15 三轮真机
// 复现，死亡点恒定「[backend] SAM Run 开始 → 无 Run 完成」），而
// ApplicationExitInfo 在该 ROM 上被权限拒绝（android.permission.DUMP），
// logcat 是唯一取证来源。SIGSEGV/SIGABRT 等「进程自己崩溃」类信号默认
// 只留下 tombstone（/data/tombstones 普通应用不可读），应用侧无从得知
// 死因；SIGKILL（LMK/厂商杀）则什么痕迹都不留。
//
// v0.5.16 首战告捷：真机遗嘱命中 SIGABRT（will signal=6）——进程是
// abort() 自杀，不是被杀。但只有信号编号不知道崩在哪。v0.5.17 升级取证：
//   1. 遗嘱追加 backtrace（_Unwind_Backtrace 裸 PC 列表，async-signal-safe，
//      不解符号——PC+offset 由 Dart 主进程对照 maps 快照离线换算，最终由
//      llvm-symbolizer 对着本地 so 出符号）；
//   2. 同步快照 /proc/self/maps 到 will.maps（进程死后 maps 即消失，PC
//      没有归属表就废了）；
//   3. stderr 重定向落盘（dup2 fd2→文件）：std::terminate 的 what()、
//      assert 输出走 stderr 且 Android 默认直通 /dev/null——落盘才能拿到
//      abort 前的最后一句人话。
//
// 只用 signal-safe API：open/write/close/read 均为 async-signal-safe；
// _Unwind_Backtrace 不经堆（DWARF eh_frame 线性解析）。handler 里不做任何
// 分配、不走 ART/JNI。串号防御用 O_APPEND 原子追加。
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <jni.h>
#include <string.h>
#include <errno.h>
#include <setjmp.h>
#include <unwind.h>

// 遗嘱文件路径（JNI 注册时从 Dart 侧传入并缓存；open 时才解引用）。
static char g_will_path[512];

// maps 快照路径 = will 路径 + ".maps"（注册时派生，避免 handler 里拼串）。
static char g_maps_path[512];

// ============ v0.5.16：信号 + 触发地址 ============

// 与 Dart 侧约定一致的信号→编号文本，避免 handler 里 snprintf 浮点/表驱动。
// 只写十进制信号编号：Dart 侧按编号翻译（1=HUP 2=INT 3=QUIT 4=ILL 5=TRAP
// 6=ABRT 7=BUS 8=FPE 9=KILL 10=USR1 11=SEGV 12=USR2 13=PIPE 15=TERM）。

// 手写十六进制（无 sprintf 依赖）：把 a 追加到 *p，返回新位置。
static char *append_hex(char *p, uintptr_t a) {
  *p++ = '0';
  *p++ = 'x';
  if (a == 0) {
    *p++ = '0';
    return p;
  }
  int started = 0;
  for (int i = 60; i >= 0; i -= 4) {
    int nib = (int)((a >> i) & 0xF);
    if (nib == 0 && !started) continue;
    started = 1;
    *p++ = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
  }
  return p;
}

// ============ v0.5.17：backtrace（裸 PC 列表） ============

#define FORENSICS_MAX_FRAMES 48

struct bt_ctx {
  int count;
  uintptr_t pcs[FORENSICS_MAX_FRAMES];
};

static _Unwind_Reason_Code bt_callback(struct _Unwind_Context *ctx, void *data) {
  struct bt_ctx *c = (struct bt_ctx *)data;
  if (c->count >= FORENSICS_MAX_FRAMES) return _URC_END_OF_STACK; // 停止遍历
  c->pcs[c->count++] = (uintptr_t)_Unwind_GetIP(ctx);
  return _URC_NO_REASON;
}

// 把 PC 列表写成一行「bt=0x…,0x…,…」（逗号分隔，Dart 侧正则一行捕获）。
// static 缓冲：信号上下文里不占信号栈（默认 8KB，1.5KB 局部数组偏险）；
// 进程将死不存在并发重入，static 竞争无意义。
static char g_bt_buf[2048];

// v0.5.21：unwind 防二次崩。实测（MuMu x86_64）_Unwind_Backtrace 在信号上下文
// 展开时自身 SIGSEGV（崩溃 PC=call 返回地址 libapp_native+0x2b59），handler
// 嵌套重入直至 SIG_DFL 死亡——遗嘱只留下二次崩的 signal=11，**原始信号被吞**。
// sigsetjmp/siglongjmp 是 async-signal-safe 的（POSIX 明确列出）：forensics_handler
// 识别 unwind 活动标志后长跳回这里，改写「bt=unwind-crashed」，保住原始信号记录。
static sigjmp_buf g_unwind_jmp;
static volatile sig_atomic_t g_unwind_active = 0;

static void write_backtrace(int fd) {
  struct bt_ctx c;
  c.count = 0;
  g_unwind_active = 1;
  if (sigsetjmp(g_unwind_jmp, 1) == 0) {
    _Unwind_Backtrace(bt_callback, &c);
  } else {
    // 二次崩：栈展开不可信，记录事实即可。
    c.count = 0;
    const char *msg = "bt=unwind-crashed\n";
    ssize_t rc = write(fd, msg, strlen(msg));
    (void)rc;
    g_unwind_active = 0;
    return;
  }
  g_unwind_active = 0;
  if (c.count == 0) return;
  char *p = g_bt_buf;
  const char *head = "bt=";
  for (const char *q = head; *q; q++) *p++ = *q;
  for (int i = 0; i < c.count; i++) {
    if (i > 0) *p++ = ',';
    p = append_hex(p, c.pcs[i]);
    if ((size_t)(p - g_bt_buf) > sizeof(g_bt_buf) - 32) break; // 防溢出
  }
  *p++ = '\n';
  ssize_t rc = write(fd, g_bt_buf, (size_t)(p - g_bt_buf));
  (void)rc;
}

// /proc/self/maps 快照：进程死后归属表消失，PC 离线符号化全靠它。
// 一个 Flutter 应用进程 maps 约 30-100KB，8KB 缓冲循环拷贝。
static char g_maps_buf[8192];

static void snapshot_maps(void) {
  int src = open("/proc/self/maps", O_RDONLY);
  if (src < 0) return;
  int dst = open(g_maps_path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
  if (dst < 0) {
    close(src);
    return;
  }
  for (;;) {
    ssize_t n = read(src, g_maps_buf, sizeof(g_maps_buf));
    if (n <= 0) break;
    ssize_t off = 0;
    while (off < n) {
      ssize_t w = write(dst, g_maps_buf + off, (size_t)(n - off));
      if (w <= 0) break;
      off += w;
    }
  }
  close(src);
  close(dst);
}

// 遗嘱：信号 + 触发地址 + backtrace；maps 另落一份。
static void write_will(int sig, siginfo_t *info) {
  // O_CREAT|O_WRONLY|O_APPEND：多次崩溃追加不覆盖；权限 0600 私有。
  int fd = open(g_will_path, O_CREAT | O_WRONLY | O_APPEND, 0600);
  if (fd < 0) return; // 写不了就算了：取证不可妨碍死亡本身
  // 行格式：will signal=<n> addr=<hex>\n
  char buf[128];
  char *p = buf;
  const char *head = "will signal=";
  for (const char *q = head; *q; q++) *p++ = *q;
  // 信号编号十进制（sig <= 31，两位足够）
  if (sig >= 10) *p++ = (char)('0' + sig / 10);
  *p++ = (char)('0' + sig % 10);
  const char *mid = " addr=";
  for (const char *q = mid; *q; q++) *p++ = *q;
  p = append_hex(p, (uintptr_t)info->si_addr);
  *p++ = '\n';
  ssize_t rc = write(fd, buf, (size_t)(p - buf));
  (void)rc; // handler 里无法报告写失败；尽力而为
  // v0.5.17：崩在哪比崩没崩更重要——PC 列表 + 归属表一起落盘。
  write_backtrace(fd);
  snapshot_maps();
  close(fd);
}

static void forensics_handler(int sig, siginfo_t *info, void *ucontext) {
  (void)ucontext;
  // v0.5.21：_Unwind_Backtrace 展开期间若二次崩溃（MuMu x86_64 实测崩在
  // unwind 内部，PC=call 返回地址 +0x2b59），仍会进入本 handler（disposition
  // 未变）。识别 unwind 活动标志 → siglongjmp 跳回 write_backtrace 的
  // sigsetjmp 点改写「bt=unwind-crashed」——保住遗嘱里的原始信号记录，
  // 不再嵌套重入直至 SIG_DFL。
  if (g_unwind_active) {
    g_unwind_active = 0;
    siglongjmp(g_unwind_jmp, 1);
  }
  write_will(sig, info);
  // 恢复默认处置并 re-raise：系统照常记录 tombstone/ANR，进程按原始死因
  // 死亡（不吞信号、不假装活着）。SIGKILL 到不了这里（内核直杀）。
  signal(sig, SIG_DFL);
  raise(sig);
}

// 安装 fatal 信号组 handler；返回 0 成功。幂等：重复调用只刷新路径。
JNIEXPORT jint JNICALL
Java_com_mangacolorizer_manga_1colorizer_1mobile_Forensics_installNativeWills(
    JNIEnv *env, jclass clazz, jstring path) {
  (void)clazz;
  if (path == NULL) return -1;
  const char *p = (*env)->GetStringUTFChars(env, path, NULL);
  if (p == NULL) return -1;
  size_t n = strlen(p);
  if (n >= sizeof(g_will_path) - 8) { // 预留 ".maps" 后缀空间
    (*env)->ReleaseStringUTFChars(env, path, p);
    return -2;
  }
  memcpy(g_will_path, p, n + 1);
  memcpy(g_maps_path, p, n);
  g_maps_path[n] = '\0';
  const char *ext = ".maps";
  memcpy(g_maps_path + n, ext, strlen(ext) + 1);
  (*env)->ReleaseStringUTFChars(env, path, p);

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = forensics_handler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  //致命信号组：崩溃类（ILL/TRAP/BUS/FPE/SEGV/ABRT/SYS）+ 终止类
  //（HUP/INT/QUIT/TERM/USR1/USR2/PIPE，被 kill <pid> 发的也是这些）。
  // XCPU/XFSZ（资源超限）一并捕——厂商省电策略有先例。
  const int sigs[] = {SIGHUP,  SIGINT,  SIGQUIT, SIGILL,  SIGTRAP,
                      SIGABRT, SIGBUS,  SIGFPE,  SIGSEGV, SIGSYS,
                      SIGPIPE, SIGTERM, SIGUSR1, SIGUSR2,
                      SIGXCPU, SIGXFSZ};
  for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
    if (sigaction(sigs[i], &sa, NULL) != 0) return -(int)(i + 10);
  }
  return 0;
}

// v0.5.17：stderr 重定向落盘（dup2 fd2 → 文件）。
//
// Android 上进程 stderr 默认直通 /dev/null：std::terminate 的 what()、
// __assert2 的断言文本、C 库 fatal 消息全都拿不到（tombstone 里才有，
// 而 tombstone 应用不可读）。dup2 到 cacheDir 文件后，这些「死前最后
// 一句人话」落盘；Dart 侧（stderr 也是 fd2）的 '[manga-inference]' 日志
// 镜像一并进文件，与 ORT 报错按时间序同框。
//
// O_TRUNC：每次进程新生清空（旧文件内容已被主进程在上一轮断连时消费，
// 保留反而伪证）。调用点在引擎创建前（Kotlin 侧 engine==null 分支内），
// 幂等重入（onStartCommand 二次进来 engine 已建）不会误清。
JNIEXPORT jint JNICALL
Java_com_mangacolorizer_manga_1colorizer_1mobile_Forensics_installStderrRedirection(
    JNIEnv *env, jclass clazz, jstring path) {
  (void)clazz;
  if (path == NULL) return -1;
  char buf[512];
  const char *p = (*env)->GetStringUTFChars(env, path, NULL);
  if (p == NULL) return -1;
  size_t n = strlen(p);
  if (n >= sizeof(buf)) {
    (*env)->ReleaseStringUTFChars(env, path, p);
    return -2;
  }
  memcpy(buf, p, n + 1);
  (*env)->ReleaseStringUTFChars(env, path, p);

  int fd = open(buf, O_CREAT | O_WRONLY | O_APPEND | O_TRUNC, 0600);
  if (fd < 0) return -3;
  if (dup2(fd, STDERR_FILENO) < 0) {
    close(fd);
    return -4;
  }
  if (fd != STDERR_FILENO) close(fd); // fd2 已指向文件，原 fd 可弃
  return 0;
}
