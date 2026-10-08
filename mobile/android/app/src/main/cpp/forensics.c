// v0.5.16 断连取证：原生信号遗嘱。
//
// 背景：:inference 进程在首个 ORT Run 内部死亡（v0.5.13/14/15 三轮真机
// 复现，死亡点恒定「[backend] SAM Run 开始 → 无 Run 完成」），而
// ApplicationExitInfo 在该 ROM 上被权限拒绝（android.permission.DUMP），
// logcat 是唯一取证来源。SIGSEGV/SIGABRT 等「进程自己崩溃」类信号默认
// 只留下 tombstone（/data/tombstones 普通应用不可读），应用侧无从得知
// 死因；SIGKILL（LMK/厂商杀）则什么痕迹都不留。
//
// 本库在进程内安装同步 signal handler：捕获致命信号后，在信号上下文里
// 只做 async-signal-safe 的操作——open/write/close 写一份「遗嘱」文件
// （信号编号 + 触发地址），然后恢复默认处置并 re-raise，让系统照常生成
// tombstone/崩溃记录。遗嘱文件落在应用私有目录（getCacheDir/forensics，
// 由 Dart 侧传入路径，经 JNI 注册时缓存 jstring），Dart 侧断连后读取，
// 把「原生崩溃 signal N」直书进日志页——崩溃 vs 被杀由此定罪：
//   · 遗嘱存在 → 原生崩溃（信号编号即死因）；
//   · 遗嘱缺失 + 心跳活跃 → SIGKILL 被杀（LMK/厂商省电）；
//   · 心跳停滞 >3s → 进程先被冻结后杀（厂商冻结策略）。
//
// 只用 signal-safe API：open/write/close 均为 async-signal-safe；串号
// 防御用 O_APPEND 原子追加。handler 里不做任何分配、不走 ART/JNI。
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <jni.h>
#include <string.h>
#include <errno.h>

// 遗嘱文件路径（JNI 注册时从 Dart 侧传入并缓存；open 时才解引用）。
static char g_will_path[512];

// 与 Dart 侧约定一致的信号→编号文本，避免 handler 里 snprintf 浮点/表驱动。
// 只写十进制信号编号：Dart 侧按编号翻译（1=HUP 2=INT 3=QUIT 4=ILL 5=TRAP
// 6=ABRT 7=BUS 8=FPE 9=KILL 10=USR1 11=SEGV 12=USR2 13=PIPE 15=TERM）。

static void write_will(int sig, siginfo_t *info) {
  // O_CREAT|O_WRONLY|O_APPEND：多次崩溃追加不覆盖；权限 0600 私有。
  int fd = open(g_will_path, O_CREAT | O_WRONLY | O_APPEND, 0600);
  if (fd < 0) return; // 写不了就算了：取证不可妨碍死亡本身
  // 行格式：will signal=<n> addr=<hex>\n（addr 转十六进制，避免依赖 sprintf）
  char buf[128];
  char *p = buf;
  const char *head = "will signal=";
  for (const char *q = head; *q; q++) *p++ = *q;
  // 信号编号十进制（sig <= 31，两位足够）
  if (sig >= 10) *p++ = (char)('0' + sig / 10);
  *p++ = (char)('0' + sig % 10);
  const char *mid = " addr=0x";
  for (const char *q = mid; *q; q++) *p++ = *q;
  // 触发地址十六进制（64 位指针）
  uintptr_t a = (uintptr_t)info->si_addr;
  for (int i = 60; i >= 0; i -= 4) {
    // 跳过前导零：找到第一个非零半字节后开始输出
    if (a >> i) {
      for (; i >= 0; i -= 4) {
        int nib = (int)((a >> i) & 0xF);
        *p++ = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
      }
      break;
    }
  }
  if (a == 0) *p++ = '0';
  *p++ = '\n';
  ssize_t rc = write(fd, buf, (size_t)(p - buf));
  (void)rc; // handler 里无法报告写失败；尽力而为
  close(fd);
}

static void forensics_handler(int sig, siginfo_t *info, void *ucontext) {
  (void)ucontext;
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
  if (n >= sizeof(g_will_path)) {
    (*env)->ReleaseStringUTFChars(env, path, p);
    return -2;
  }
  memcpy(g_will_path, p, n + 1);
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
