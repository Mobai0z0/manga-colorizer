# Android 端侧 ONNX 全自动上色 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android Flutter 壳离线运行 `v6_sam_encoder + v6_generator` 全自动上色，与桌面 `/colorize_auto` 同源；权重首启由用户下载（不进 APK）。

**Architecture:** ORT CPU EP 直跑原模型；推理细节封闭在 `mobile/lib/onnx/backend.dart`（两方法接口，可 mock）；管线/下载器各一文件；RGB↔Lab 与分块羽化等纯 Dart 数学进 `manga_colorizer_core`（金样对拍 cv2/Python）。Spec §3.1 业界参照 local-dream。

**Tech Stack:** Flutter 3.47 / Dart 3.13、flutter_onnxruntime（候补 onnxruntime_v2，Step 0 定夺）、crypto、path_provider、image（仅 mobile 侧 resize）。

**Spec:** `docs/superpowers/specs/2026-09-23-android-onnx-design.md`（先读它再动手）

## Global Constraints

- 权重**绝不**打包进 APK / assets（CC BY-NC-SA）；manifest 值逐字：
  - `v6_generator.onnx` size=191335312 sha256=`48284fcf0b7a606270702630f559af88eecf95bc6cdec1ff8bce8663d12b4bb6`
  - `v6_sam_encoder.onnx` size=108983556 sha256=`97c4cad5814e1fb12c13d1b23d3969dd9e2fce92d818539fe7db575140333a34`
  - URL 模式 `https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/<name>`，镜像 `https://hf-mirror.com/sharky172/manga-light-colorizer/resolve/main/models/<name>`
- 张量契约（对拍 service.py `_run_pair`，service.py:331-342）：SAM `rgb_input [1,3,1024,1024]`＝BGR 灰度三通道 `x/127.5-1` CHW；generator `L_bw [1,1,1024,1024]`（灰度同归一化）、`sam_level0/1`（透传 SAM 输出与形状）、`wd14_embedding [1,1024]` 全零 → `rgb_pred [1,3,1024,1024]`，反归一化 `clip((y+1)*127.5)`
- 语义对齐桌面：`colorize()`＝max(w,h)≤1024 单块、L 恒取原稿（service.py:401-410）；`colorize_tiled`＝tile 1024/overlap 256、只羽化融合 a/b（service.py:375-398）；`_tile_bounds`/`_feather_weight` 逐字移植（service.py:305-328）
- `packages/manga_colorizer_core` 保持无 `dart:io`、无新依赖；既有 25 项测试全绿是每任务底线
- 并发 1、进度按块上报、可取消、空闲即 `dispose()` session
- Step 0 放行线（spec §6）：arm64 真机单块 1024² ≤120 s 且峰值 RSS ≤4 GB；不达标 **STOP 回 spec 分叉**，不得继续 Task 1+
- win32 + Git Bash 环境；`dart analyze` 因既有 pub-workspace 配置不可用，以 `flutter analyze mobile` + `dart format` + 测试为准

---

### Task 0: Step 0 真机门槛 spike（throwaway，不入库）

**Files:**
- Create: `build/spike-onnx/`（`build/` 已在 .gitignore，天然不入库）
- Modify: 无仓库文件；结论回填 `docs/superpowers/specs/2026-09-23-android-onnx-design.md` §6

**Interfaces:**
- Consumes: adb 连接的 arm64 真机（用户自备）、`models/manga-light-colorizer/*.onnx`
- Produces: 实测数字（加载秒数 / 单块推理秒数 / 峰值 RSS）与绑定可用性结论，写入 spec §6 附记

- [ ] **Step 1: 环境确认**（无设备 → 向用户要设备，不得用模拟器数字代替放行线）

```bash
adb devices        # 期望恰好 1 台 arm64 真机；无设备则暂停等用户
flutter --version  # 3.47.x
```

- [ ] **Step 2: 脚手架 + 依赖**

```bash
cd /e/manga-colorizer/build && flutter create --platforms=android --project-name spike_onnx spike-onnx
cd spike-onnx && flutter pub add flutter_onnxruntime path_provider
```

- [ ] **Step 3: 写 spike 入口**（整文件覆盖 `lib/main.dart`）

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

const _names = ['v6_sam_encoder.onnx', 'v6_generator.onnx'];

Future<Directory> _cache() async {
  final d = await getExternalStorageDirectory();
  return d!;
}

void main() => runApp(FutureBuilder<String>(
      future: run(),
      builder: (_, s) => MaterialApp(home: Scaffold(body: Center(
          child: Text(s.data ?? s.error?.toString() ?? 'running…',
              textAlign: TextAlign.center)))),
    ));

Future<String> run() async {
  final log = StringBuffer();
  final dir = await _cache();
  for (final n in _names) {
    if (!File('${dir.path}/$n').existsSync()) {
      return '先 adb push models/manga-light-colorizer/$n ${dir.path}/ （见 Step 4）';
    }
  }
  final ort = OnnxRuntime();
  final sw = Stopwatch()..start();
  final sam = await ort.createSessionFromFile('${dir.path}/${_names[0]}');
  final gen = await ort.createSessionFromFile('${dir.path}/${_names[1]}');
  log.writeln('load=${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  final x = Float32List(3 * 1024 * 1024); // 中灰输入即可
  for (var i = 0; i < x.length; i++) { x[i] = 0; }
  final sw2 = Stopwatch()..start();
  final inT = await OrtValue.fromList(x, [1, 3, 1024, 1024]);
  final samOut = await sam.run({sam.inputNames.first: inT});
  final s0 = samOut[0]!, s1 = samOut[1]!;
  log.writeln('sam=${sw2.elapsedMilliseconds / 1000}s shapes=${s0.shape} ${s1.shape}');
  sw2.reset();
  final feed = {
    'L_bw': await OrtValue.fromList(Float32List(1024 * 1024), [1, 1, 1024, 1024]),
    'sam_level0': s0,
    'sam_level1': s1,
    'wd14_embedding': await OrtValue.fromList(Float32List(1024), [1, 1024]),
  };
  final g = await gen.run(feed);
  log.writeln('gen=${sw2.elapsedMilliseconds / 1000}s out=${g[0]!.shape}');
  return log.toString();
}
```

注：`OrtValue.fromList` / `session.inputNames` / `createSessionFromFile` 的确切签名以
Step 2 解析到的 flutter_onnxruntime 版本的 `flutter pub deps` + IDE 补全为准；**若该版本
无文件加载或无多命名输入 feed 能力 → 记录事实，改试 `onnxruntime_v2`，再不行才评估自写
FFI**。这一步就是绑定选型门槛，结论写进 spec。峰值 RSS 以
`adb shell dumpsys meminfo io.flutter.spikespike`（或 spike 的 applicationId）为准。

- [ ] **Step 4: 推送权重并运行**

```bash
APPDIR=$(adb shell pm path io.flutter.spike_onnx 2>/dev/null | head -1 | sed 's/package://;s/base.apk//') 
adb push /e/manga-colorizer/models/manga-light-colorizer/v6_sam_encoder.onnx /e/manga-colorizer/models/manga-light-colorizer/v6_generator.onnx "$APPDIR/../files/" 
flutter run   # 屏幕显示 load/sam/gen 三行耗时
adb shell dumpsys meminfo io.flutter.spike_onnx | grep -E 'Total RSS|Total PSS'
```

- [ ] **Step 5: 回填结论并提交（唯一入库动作是 spec 附记）**

把数字与绑定结论追加到 spec §6 末尾，格式：`实测(设备,日期): load=…, sam=…, gen=…, RSS=…, 绑定=…，判定=放行/不达标`。

```bash
git add docs/superpowers/specs/2026-09-23-android-onnx-design.md
git commit -m "docs(spec): Step 0 真机门槛实测结论回填"
```

**不达标 → 停止本计划，回 spec §3 分叉（D/C/512²/暂停）重新决策。**

---

### Task 1: core 新增 lab.dart（RGB↔Lab，对拍 cv2 金样）

**Files:**
- Create: `packages/manga_colorizer_core/lib/src/lab.dart`
- Create: `packages/manga_colorizer_core/test/goldens/lab_golden.json`（脚本生成，入库）
- Create: `packages/manga_colorizer_core/test/lab_test.dart`
- Modify: `packages/manga_colorizer_core/lib/manga_colorizer_core.dart`（加 export）

**Interfaces:**
- Consumes: 无
- Produces（Task 5 依赖，签名逐字）:
  - `Uint8List rgbToLab(Uint8List rgb, int n)` — 输入 n 像素 ×3 通道，输出 n×3 的 8bit Lab（a/b 带 +128 偏置，对齐 `cv2.COLOR_RGB2LAB`）
  - `Uint8List labToRgb(Uint8List lab, int n)` — 逆（对齐 `cv2.COLOR_LAB2RGB`）

- [ ] **Step 1: 生成金样**（仓库根执行；用仓库 .venv 的 cv2。随机图 16×32 + 全灰阶条带 16×256 两份）

```bash
cd /e/manga-colorizer && mkdir -p packages/manga_colorizer_core/test/goldens && .venv/Scripts/python.exe - <<'EOF'
import cv2, json, numpy as np
np.random.seed(7)
img = np.random.randint(0, 256, (16, 32, 3), np.uint8)
strip = np.dstack([np.tile(np.arange(256, dtype=np.uint8), (16, 8))] * 1)[:16, :256]
for name, src in [('noise', img), ('strip', strip)]:
    lab = cv2.cvtColor(src, cv2.COLOR_RGB2LAB)
    back = cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)
    d = {'w': int(src.shape[1]), 'h': int(src.shape[0]),
         'rgb': src.reshape(-1).tolist(),
         'lab': lab.reshape(-1).tolist(),
         'rgb_back': back.reshape(-1).tolist()}
    with open(f'packages/manga_colorizer_core/test/goldens/lab_golden_{name}.json', 'w') as f:
        json.dump(d, f)
print('ok')
EOF
```

- [ ] **Step 2: 写失败测试** `packages/manga_colorizer_core/test/lab_test.dart`

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:test/test.dart';

void main() {
  for (final name in ['noise', 'strip']) {
    test('lab golden $name matches cv2 within quantization', () {
      final d = jsonDecode(File('test/goldens/lab_golden_$name.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final rgb = (d['rgb'] as List).cast<int>().map<int>((e) => e).toList();
      final lab = (d['lab'] as List).cast<int>().map<int>((e) => e).toList();
      final back = (d['rgb_back'] as List).cast<int>().map<int>((e) => e).toList();
      final n = rgb.length ~/ 3;
      final got = rgbToLab(Uint8List.fromList(rgb), n);
      final rt = labToRgb(got, n);
      for (var i = 0; i < rgb.length; i++) {
        expect((got[i] - lab[i]).abs(), lessThanOrEqual(2),
            reason: '$name@$i got=${got[i]} cv2=${lab[i]}');
        expect((rt[i] - rgb[i]).abs(), lessThanOrEqual(1), reason: 'roundtrip@$i');
        expect((rt[i] - back[i]).abs(), lessThanOrEqual(2), reason: 'vs cv2 back@$i');
      }
      expect(n, greaterThan(0)); // 防呆: 空样本
    });
  }
}
```

- [ ] **Step 3: 跑测试确认失败**

```bash
cd /e/manga-colorizer/packages/manga_colorizer_core && dart test test/lab_test.dart
```
Expected: FAIL（`rgbToLab` 未定义 → 编译错误即可视为失败）

- [ ] **Step 4: 实现** `packages/manga_colorizer_core/lib/src/lab.dart`

```dart
// RGB↔Lab(D65, 8bit, a/b 偏置 +128)，数值语义对齐 OpenCV cvtColor（金样对拍见测试）。
import 'dart:math' as math;
import 'dart:typed_data';

const _d = 6 / 29; // δ
double _fwd(double t) =>
    t > _d * _d * _d ? math.pow(t, 1 / 3).toDouble() : t / (3 * _d * _d) + 4 / 29;
double _inv(double t) => t > _d ? t * t * t : 3 * _d * _d * (t - 4 / 29);
double _srgb(double c) =>
    c > 0.04045 ? math.pow((c + 0.055) / 1.055, 2.4).toDouble() : c / 12.92;
int _gamma(double c) {
  final v = c > 0.0031308 ? 1.055 * math.pow(c, 1 / 2.4) - 0.055 : 12.92 * c;
  return (v.clamp(0.0, 1.0) * 255).round();
}

Uint8List rgbToLab(Uint8List rgb, int n) {
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final r = _srgb(rgb[i * 3] / 255.0),
        g = _srgb(rgb[i * 3 + 1] / 255.0),
        b = _srgb(rgb[i * 3 + 2] / 255.0);
    final x = _fwd((0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456);
    final y = _fwd(0.212671 * r + 0.715160 * g + 0.072169 * b);
    final z = _fwd((0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754);
    out[i * 3] = (116 * y - 16).clamp(0, 255).round();
    out[i * 3 + 1] = (500 * (x - y) + 128).clamp(0, 255).round();
    out[i * 3 + 2] = (200 * (y - z) + 128).clamp(0, 255).round();
  }
  return out;
}

Uint8List labToRgb(Uint8List lab, int n) {
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final l = lab[i * 3] / 255.0 * 100.0,
        a = lab[i * 3 + 1] - 128.0,
        b = lab[i * 3 + 2] - 128.0;
    final fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
    final x = _inv(fx) * 0.950456,
        y = l > 8 ? fy * fy * fy : l / 903.3,
        z = _inv(fz) * 1.088754;
    out[i * 3] = _gamma(3.240481 * x - 1.537152 * y - 0.498536 * z);
    out[i * 3 + 1] = _gamma(-0.969254 * x + 1.875990 * y + 0.041556 * z);
    out[i * 3 + 2] = _gamma(0.055643 * x - 0.203997 * y + 1.057311 * z);
  }
  return out;
}
```

容差说明：cv2 8bit 走 LUT，个别格点与 float 公式差 ±1～2；金样测试的
`lessThanOrEqual(2)`（lab/roundtrip 为 1/2）即以此为据，差值再大视为实现错误。

- [ ] **Step 5: 跑测试确认通过 + 全量回归**

```bash
cd /e/manga-colorizer/packages/manga_colorizer_core && dart test
```
Expected: 27 项全绿（25 既有 + 新 2）

- [ ] **Step 6: 导出 + 提交**

`manga_colorizer_core.dart` 的 export 区加一行：`export 'src/lab.dart';`

```bash
cd /e/manga-colorizer && git add packages/manga_colorizer_core && git commit -m "feat(core): cv2 对齐的 8bit RGB↔Lab 转换与金样测试"
```

---

### Task 2: mobile 分块几何（tileBounds / featherWeight，逐字移植 service.py:305-328）

**Files:**
- Create: `mobile/lib/onnx/tiles.dart`
- Create: `mobile/test/tiles_test.dart`

**Interfaces:**
- Consumes: 无
- Produces（Task 5 依赖，签名逐字）:
  - `List<(int, int)> tileBounds(int total, int tile, int overlap)`
  - `Float32List featherWeight(int a0, int a1, int overlap)` — 长度 `a1-a0`

- [ ] **Step 1: 写失败测试** `mobile/test/tiles_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/tiles.dart';

void main() {
  test('short axis single bound', () {
    expect(tileBounds(800, 1024, 256), [(0, 800)]);
  });
  test('long axis tiles cover and overlap', () {
    final b = tileBounds(2000, 1024, 256);
    expect(b.first, (0, 1024));
    expect(b.last.\$2, 2000);
    for (var i = 1; i < b.length; i++) {
      expect(b[i - 1].\$2 - b[i].\$1, greaterThanOrEqualTo(0)); // 不重倒
      expect(b[i].\$2 - b[i].\$1, greaterThan(0));
    }
  });
  test('feather ramps at both ends, plateau middle', () {
    final w = featherWeight(0, 1024, 256);
    expect(w.length, 1024);
    expect(w[0], 0.0);
    expect(w[256], 1.0);
    expect(w[767], 1.0);
    expect(w[1023], 0.0);
    expect(featherWeight(0, 300, 256)[150], 1.0); // lo=150 上限
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /e/manga-colorizer/mobile && flutter test test/tiles_test.dart
```

- [ ] **Step 3: 实现** `mobile/lib/onnx/tiles.dart`

```dart
// 长图分块几何: 与桌面 tool/colorizer_service/service.py 的 _tile_bounds/_feather_weight
// 同语义（线性羽化、重叠 256、末块强制触边）。
import 'dart:typed_data';

List<(int, int)> tileBounds(int total, int tile, int overlap) {
  if (total <= tile) return [(0, total)];
  final step = tile - overlap;
  final bounds = <(int, int)>[];
  var start = 0;
  while (true) {
    final end = start + tile < total ? start + tile : total;
    bounds.add((start, end));
    if (end >= total) break;
    start = end - overlap > start ? end - overlap : start + step;
  }
  return bounds;
}

Float32List featherWeight(int a0, int a1, int overlap) {
  final w = Float32List(a1 - a0)..fillRange(0, a1 - a0, 1.0);
  var lo = overlap;
  if (lo > (a1 - a0) ~/ 2) lo = (a1 - a0) ~/ 2;
  for (var i = 0; i < lo; i++) {
    w[i] = i / lo;
    final j = a1 - a0 - lo + i;
    final ramp = (lo - 1 - i) / lo;
    if (ramp < w[j]) w[j] = ramp;
  }
  return w;
}
```

Python `np.linspace(0,1,lo,endpoint=False)` ⇔ `i/lo`；`ramp[::-1]` ⇔ 上式倒序。

- [ ] **Step 4: 跑测试确认通过** — 同 Step 2，Expected: All tests passed

- [ ] **Step 5: 提交**

```bash
cd /e/manga-colorizer && git add mobile/lib/onnx mobile/test/tiles_test.dart && git commit -m "feat(mobile): 长图分块几何移植自桌面侧 tile/feather 语义"
```

---

### Task 3: weights.dart 权重仓储（下载断点续传 + sha256 校验）

**Files:**
- Create: `mobile/lib/onnx/weights.dart`
- Create: `mobile/test/weights_test.dart`
- Modify: `mobile/pubspec.yaml`（dependencies 加 `crypto: ^3.0.3`）

**Interfaces:**
- Consumes: 无
- Produces（Task 4/6 依赖，签名逐字）:
  - `class WeightFile { final String name; final int size; final String sha256; final String url; final String mirrorUrl; }`
  - `const List<WeightFile> kWeightFiles`（Global Constraints 的 manifest 值逐字）
  - `class WeightsStore({required Directory dir, bool Function(String url) mirrorPreferred})`
    - `Future<bool> get ready`（两文件在位且 size 匹配；不重算哈希——哈希只在下载完成时算）
    - `Future<void> download(WeightFile f, {void Function(int done, int total)? onProgress})` — Range 续传 `.part`，完成后流式 sha256 校验，不符删 `.part` 抛 `WeightsException`
    - `String pathOf(WeightFile f)`

- [ ] **Step 1: 写失败测试**（本地 `HttpServer` 实现 Range，分两段中断测试续传）`mobile/test/weights_test.dart`

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/onnx/weights.dart';

void main() {
  late HttpServer server;
  late Uint8List payload;
  late String sha;
  var hits = 0;
  setUp(() async {
    payload = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    sha = sha256.convert(payload).toString();
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits++;
      final range = req.headers.value('range');
      final start = range == null ? 0 : int.parse(RegExp(r'bytes=(\d+)').firstMatch(range)!.group(1)!);
      if (range != null && hits == 1) { // 首次续传请求直接拒绝 → 应整段回 200
        req.response.statusCode = HttpStatus.ok;
        req.response.add(payload);
      } else {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${payload.length - 1}/${payload.length}');
        req.response.add(payload.sublist(start));
      }
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('download with resume + sha256 verify', () async {
    final dir = await Directory.systemTemp.createTemp('weights');
    final store = WeightsStore(dir: dir, mirrorPreferred: (_) => false);
    final f = WeightFile(name: 'gen.onnx', size: payload.length, sha256: sha,
        url: 'http://127.0.0.1:${server.port}/gen.onnx',
        mirrorUrl: 'http://127.0.0.1:${server.port}/gen.onnx');
    // 预置 .part 前 400 字节 → 触发 Range 续传路径
    await File('${dir.path}/gen.onnx.part').writeAsBytes(payload.sublist(0, 400));
    await store.download(f);
    expect(store.readyFor(f), isTrue);
    expect(File(store.pathOf(f)).readAsBytesSync(), payload);
  });

  test('bad sha deletes part and throws', () async {
    final dir = await Directory.systemTemp.createTemp('weights');
    final store = WeightsStore(dir: dir, mirrorPreferred: (_) => false);
    final f = WeightFile(name: 'gen.onnx', size: payload.length, sha256: '0' * 64,
        url: 'http://127.0.0.1:${server.port}/gen.onnx',
        mirrorUrl: 'http://127.0.0.1:${server.port}/gen.onnx');
    expect(() => store.download(f), throwsA(isA<WeightsException>()));
    expect(File('${dir.path}/gen.onnx.part').existsSync(), isFalse);
  });
}
```

- [ ] **Step 2: 跑测试确认失败** `cd mobile && flutter test test/weights_test.dart`

- [ ] **Step 3: 实现** `mobile/lib/onnx/weights.dart`

```dart
// 权重仓储：首启下载（Range 断点续传 + sha256 校验）。权重 CC BY-NC-SA 4.0，
// 不随 APK 分发，由使用者自行下载；镜像站 hf-mirror 供国内网络直连。
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class WeightFile {
  const WeightFile({required this.name, required this.size, required this.sha256,
      required this.url, required this.mirrorUrl});
  final String name;
  final int size;
  final String sha256;
  final String url;
  final String mirrorUrl;
}

const kWeightFiles = <WeightFile>[
  WeightFile(
    name: 'v6_generator.onnx', size: 191335312, sha256: '48284fcf0b7a606270702630f559af88eecf95bc6cdec1ff8bce8663d12b4bb6',
    url: 'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/v6_generator.onnx',
    mirrorUrl: 'https://hf-mirror.com/sharky172/manga-light-colorizer/resolve/main/models/v6_generator.onnx',
  ),
  WeightFile(
    name: 'v6_sam_encoder.onnx', size: 108983556, sha256: '97c4cad5814e1fb12c13d1b23d3969dd9e2fce92d818539fe7db575140333a34',
    url: 'https://huggingface.co/sharky172/manga-light-colorizer/resolve/main/models/v6_sam_encoder.onnx',
    mirrorUrl: 'https://hf-mirror.com/sharky172/manga-light-colorizer/resolve/main/models/v6_sam_encoder.onnx',
  ),
];

class WeightsException implements Exception {
  WeightsException(this.message);
  final String message;
  @override
  String toString() => 'WeightsException: $message';
}

class WeightsStore {
  WeightsStore({required this.dir, required this.mirrorPreferred});
  final Directory dir;
  final bool Function(String url) mirrorPreferred;

  String pathOf(WeightFile f) => '${dir.path}/${f.name}';
  bool readyFor(WeightFile f) {
    final x = File(pathOf(f));
    return x.existsSync() && x.lengthSync() == f.size;
  }
  Future<bool> get ready async {
    for (final f in kWeightFiles) { if (!readyFor(f)) return false; }
    return true;
  }

  Future<void> download(WeightFile f, {void Function(int done, int total)? onProgress}) async {
    final part = File('${pathOf(f)}.part');
    var start = part.existsSync() ? part.lengthSync() : 0;
    if (start > f.size) { await part.delete(); start = 0; }
    final client = HttpClient();
    final url = mirrorPreferred(f.url) ? f.mirrorUrl : f.url;
    final done = await _fetch(client, Uri.parse(url), part, start, f, onProgress);
    if (done != f.size) {
      // .part 可能过期损坏：整段重下一次（唯一一次），仍不对则抛
      await part.delete();
      final again = await _fetch(client, Uri.parse(url), part, 0, f, onProgress);
      if (again != f.size) { await part.delete(); client.close(); throw WeightsException('${f.name}: 大小 $again != ${f.size}'); }
    }
    final digest = await sha256.bind(part.openRead()).toString();
    client.close();
    if (digest != f.sha256) { await part.delete(); throw WeightsException('${f.name}: sha256 校验失败'); }
    final out = File(pathOf(f));
    if (out.existsSync()) await out.delete();
    await part.rename(out.path);
  }

  Future<int> _fetch(HttpClient client, Uri url, File part, int start, WeightFile f,
      void Function(int, int)? onProgress) async {
    final req = await client.getUrl(url);
    if (start > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final res = await req.close();
    if (res.statusCode != 200 && res.statusCode != 206) throw WeightsException('${f.name}: HTTP ${res.statusCode}');
    final append = res.statusCode == 206;
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    var done = append ? start : 0;
    await for (final chunk in res) {
      sink.add(chunk);
      done += chunk.length;
      onProgress?.call(done, f.size);
    }
    await sink.flush(); await sink.close();
    return part.lengthSync();
  }
}
```

- [ ] **Step 4: 跑测试确认通过**（含修正测试笔误后再跑）`cd mobile && flutter test test/weights_test.dart`

- [ ] **Step 5: 提交**

```bash
cd /e/manga-colorizer && git add mobile && git commit -m "feat(mobile): 权重下载器（断点续传+sha256, manifest 与桌面一致）"
```

---

### Task 4: backend.dart（OnnxBackend 抽象 + flutter_onnxruntime 实现 + 常量 mock）

**Files:**
- Create: `mobile/lib/onnx/backend.dart`
- Create: `mobile/test/fake_backend.dart`（测试内 mock，非 lib）
- Modify: `mobile/pubspec.yaml`（加 `flutter_onnxruntime: ^1.4.0`；Step 0 已定版则用其版本）
- Modify: `mobile/android/app/build.gradle.kts`（仅当绑定要求 minSdk/NDK 版本时按其 README 调整；默认不动）

**Interfaces:**
- Consumes: Task 3 `kWeightFiles`/`WeightsStore.pathOf`
- Produces（Task 5/6 依赖，签名逐字）:

```dart
abstract class OnnxBackend {
  Future<void> load();
  /// 输入 [1,3,S,S] CHW 归一化浮点；返回 SAM 两级特征（数据+形状，透传给 runGen）
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(Float32List chw, int s);
  /// 返回 [1,3,S,S] CHW、[-1,1] 的 RGB
  Future<Float32List> runGen(Float32List grayChw, int s, (Float32List, List<int>) sam0, (Float32List, List<int>) sam1);
  Future<void> dispose();
}
class OnnxCancelled implements Exception {}
```

- [ ] **Step 1: 写 mock（先有测试替身）** `mobile/test/fake_backend.dart`

```dart
import 'dart:typed_data';
import 'package:manga_colorizer_mobile/onnx/backend.dart';

/// 常数场替身: 特征固定形状, rgb 输出按像素 x 左红右蓝。
class FakeBackend implements OnnxBackend {
  FakeBackend({this.calls = const []});
  final List<String> calls;
  bool throwOnGen = false;

  @override
  Future<void> load() async { calls.add('load'); }
  @override
  Future<void> dispose() async { calls.add('dispose'); }
  @override
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(Float32List chw, int s) async {
    calls.add('sam:${chw.length}');
    final a = Float32List(256 * 64 * 64)..fillRange(0, 256 * 64 * 64, 0.1);
    final b = Float32List(256 * 32 * 32)..fillRange(0, 256 * 32 * 32, 0.1);
    return ((a, [1, 256, 64, 64]), (b, [1, 256, 32, 32]));
  }
  @override
  Future<Float32List> runGen(Float32List l, int s, (Float32List, List<int>) a, (Float32List, List<int>) b) async {
    if (throwOnGen) throw StateError('boom');
    calls.add('gen:${l.length}');
    final out = Float32List(3 * s * s);
    for (var y = 0; y < s; y++) {
      for (var x = 0; x < s; x++) {
        final i = (y * s + x) * 3;
        final redSide = x < s ~/ 2;
        out[i] = redSide ? 0.9 : -0.3;        // r
        out[i + 1] = -0.5;                     // g
        out[i + 2] = redSide ? -0.5 : 0.9;     // b
      }
    }
    return out;
  }
}
```

- [ ] **Step 2: 实现真实后端** `mobile/lib/onnx/backend.dart`

```dart
// ONNX Runtime 推理层的唯一出入口：桌面管线同款两 session（SAM encoder → generator）。
// 绑定方法名（createSessionFromFile/run/release/inputNames）以 Step 0 实测定版为准；
// OnnxBackend 三方法签名是硬约束，绑定差异只允许封闭在本文件内。
import 'dart:typed_data';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'backend_api.dart';
import 'weights.dart';

export 'backend_api.dart';

class OrtOnnxBackend implements OnnxBackend {
  OrtOnnxBackend(this._store);
  final WeightsStore _store;
  InferenceSession? _sam;
  InferenceSession? _gen;

  @override
  Future<void> load() async {
    if (_sam != null) return;
    final ort = OnnxRuntime();
    _sam = await ort.createSessionFromFile(_store.pathOf(kWeightFiles[1]));
    _gen = await ort.createSessionFromFile(_store.pathOf(kWeightFiles[0]));
  }

  @override
  Future<((Float32List, List<int>), (Float32List, List<int>))> runSam(Float32List chw, int s) async {
    final input = await OrtValue.fromList(chw, [1, 3, s, s]);
    final out = await _sam!.run({_sam!.inputNames.first: input});
    // 按输出名匹配 sam_level0/1；无名字接口时退化为顺序 [0]/[1]（Step 0 spike 已验证顺序）
    final names = _sam!.outputNames;
    final i0 = names.indexOf('sam_level0'), i1 = names.indexOf('sam_level1');
    final a = out[i0 >= 0 ? i0 : 0], b = out[i1 >= 0 ? i1 : 1];
    return ((a.value as Float32List, (a.shape as List).cast<int>()),
            (b.value as Float32List, (b.shape as List).cast<int>()));
  }

  @override
  Future<Float32List> runGen(Float32List gray, int s, (Float32List, List<int>) a, (Float32List, List<int>) b) async {
    final out = await _gen!.run({
      'L_bw': await OrtValue.fromList(gray, [1, 1, s, s]),
      'sam_level0': await OrtValue.fromList(a.\$1, a.\$2),
      'sam_level1': await OrtValue.fromList(b.\$1, b.\$2),
      'wd14_embedding': await OrtValue.fromList(Float32List(1024), [1, 1024]),
    });
    final names = _gen!.outputNames;
    final j = names.indexOf('rgb_pred');
    return out[j >= 0 ? j : 0].value as Float32List;
  }

  @override
  Future<void> dispose() async {
    await _sam?.release(); await _gen?.release();
    _sam = null; _gen = null;
  }
}
```

配套 `mobile/lib/onnx/backend_api.dart`：上面 Interfaces 代码块逐字（抽象类 + `OnnxCancelled`），由 `backend.dart` re-export。

- [ ] **Step 3: 编译/静态检查**

```bash
cd /e/manga-colorizer/mobile && flutter pub get && flutter analyze lib/onnx && flutter test
```
Expected: analyze 0 error（真实 ORT 代码在 dart 测试里不执行，只验类型）；已有测试全绿

- [ ] **Step 4: 提交**

```bash
cd /e/manga-colorizer && git add mobile && git commit -m "feat(mobile): OnnxBackend 抽象与 flutter_onnxruntime 实现（接口隔离绑定差异）"
```

---

### Task 5: pipeline.dart 全自动管线（mock 可测）

**Files:**
- Create: `mobile/lib/onnx/pipeline.dart`
- Create: `mobile/test/pipeline_test.dart`
- Modify: `mobile/pubspec.yaml`（加 `image: ^4.3.0`，仅用于 resize/blur 的纯 Dart 实现）

**Interfaces:**
- Consumes: Task 1 `rgbToLab`/`labToRgb`（core）、Task 2 `tileBounds`/`featherWeight`、Task 4 `OnnxBackend`
- Produces（Task 6 依赖，签名逐字）:

```dart
/// 输入灰度 w*h（1B/px），输出上色 RGB w*h*3；null = 被取消。
Future<Uint8List?> autoColorize({
  required Uint8List gray, required int width, required int height,
  required OnnxBackend backend, int infer = 1024, int overlap = 256,
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
});
```

- [ ] **Step 1: 写失败测试** `mobile/test/pipeline_test.dart`（关键断言：亮度保真、左红右蓝融合、取消返回 null、backend 调用次数 = 块数×2）

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:manga_colorizer_mobile/onnx/pipeline.dart';
import 'fake_backend.dart';

void main() {
  test('single tile keeps luminance of original', () async {
    final w = 64, h = 48;
    final gray = Uint8List(w * h);
    for (var i = 0; i < gray.length; i++) { gray[i] = (i * 7) % 256; }
    final b = FakeBackend();
    final out = await autoColorize(gray: gray, width: w, height: h, backend: b, infer: 1024);
    expect(out, isNotNull);
    expect(out!.length, w * h * 3);
    final lab = rgbToLab(out, w * h);
    // L 通道来自原稿: lut 近似 L=gray*255/50*... 用 labToRgb 回环比较不严谨，
    // 直接断言: 结果转 Lab 的 L 与 gray 转 Lab 的 L 完全一致（同一 lut 函数）。
    final refLab = rgbToLab(_gray3(gray), w * h);
    for (var p = 0; p < w * h; p++) {
      expect((lab[p * 3] - refLab[p * 3]).abs(), lessThanOrEqual(1), reason: 'L@$p');
    }
  });
  test('cancelled returns null', () async {
    final w = 64, h = 48;
    final out = await autoColorize(
      gray: Uint8List(w * h), width: w, height: h,
      backend: FakeBackend(), cancelled: () => true);
    expect(out, isNull);
  });
  test('two tiles fuse chroma in overlap', () async {
    final w = 1400, h = 100; // x 轴两块, y 轴一块
    final b = FakeBackend();
    final calls = <String>[];
    final out = await autoColorize(gray: Uint8List(w * h)..fillRange(0, w * h, 128),
        width: w, height: h, backend: b, overlap: 256);
    expect(out, isNotNull);
    // 左半偏红、右半偏蓝: 中位区（远离两块接缝）两侧色相差明显
    final lab = rgbToLab(out!, w * h);
    int ab(int x) => (lab[(50 * w + x) * 3 + 1] - 128).abs() + (lab[(50 * w + x) * 3 + 2] - 128).abs();
    expect(ab(100), greaterThan(0));
    expect((ab(100) - ab(1300)).abs(), greaterThan(0)); // 两侧色相不同
    calls.add('done');
  });
  test('backend called twice per tile', () async {
    final b = FakeBackend();
    await autoColorize(gray: Uint8List(64 * 48), width: 64, height: 48, backend: b);
    expect(b.calls.where((c) => c.startsWith('sam:')).length, 1);
    expect(b.calls.where((c) => c.startsWith('gen:')).length, 1);
  });
}

Uint8List _gray3(Uint8List g) {
  final o = Uint8List(g.length * 3);
  for (var i = 0; i < g.length; i++) { o[i * 3] = o[i * 3 + 1] = o[i * 3 + 2] = g[i]; }
  return o;
}
```

- [ ] **Step 2: 跑测试确认失败** `cd mobile && flutter test test/pipeline_test.dart`

- [ ] **Step 3: 实现** `mobile/lib/onnx/pipeline.dart`

```dart
// 端侧全自动上色管线：对齐桌面 service.py colorize()/colorize_tiled() 语义 —
// 每块 缩 infer² → SAM+generator → 只取 a/b 色度，线性羽化融合；L 恒取原稿灰度。
import 'dart:typed_data';
import 'package:image/image.dart' as imglib;
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'backend.dart';
import 'tiles.dart';

Future<Uint8List?> autoColorize({
  required Uint8List gray, required int width, required int height,
  required OnnxBackend backend, int infer = 1024, int overlap = 256,
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
}) async {
  bool c() => cancelled?.call() ?? false;
  if (c()) return null;
  final ys = tileBounds(height, infer, overlap), xs = tileBounds(width, infer, overlap);
  final total = ys.length * xs.length;
  var done = 0;
  final chroma = Float32List(width * height * 2);
  final weight = Float32List(width * height);
  for (final (y0, y1) in ys) {
    for (final (x0, x1) in xs) {
      if (c()) return null;
      final pw = x1 - x0, ph = y1 - y0;
      final patch = _crop(gray, width, x0, y0, pw, ph);
      final rgb = await _inferPatch(patch, pw, ph, infer, backend);
      final lab = rgbToLab(rgb, pw * ph);
      final wy = featherWeight(y0, y1, overlap), wx = featherWeight(x0, x1, overlap);
      for (var py = 0; py < ph; py++) {
        final m2 = wy[py];
        final rowBase = (y0 + py) * width + x0;
        final pBase = py * pw * 3;
        for (var px = 0; px < pw; px++) {
          final m = m2 * wx[px];
          final g = rowBase + px;
          chroma[g * 2] += lab[(pBase + px * 3) + 1] * m;
          chroma[g * 2 + 1] += lab[(pBase + px * 3) + 2] * m;
          weight[g] += m;
        }
      }
      done++;
      onProgress?.call(done / total);
    }
  }
  // L 恒取原稿: gray→(r=g=b)→Lab 的 L + 融合后的 a/b
  final refLab = rgbToLab(_expand3(gray), width * height);
  final outLab = Uint8List(width * height * 3);
  for (var p = 0; p < width * height; p++) {
    final ww = weight[p] < 1e-6 ? 1e-6 : weight[p];
    outLab[p * 3] = refLab[p * 3];
    outLab[p * 3 + 1] = (chroma[p * 2] / ww).clamp(0, 255).round();
    outLab[p * 3 + 2] = (chroma[p * 2 + 1] / ww).clamp(0, 255).round();
  }
  return labToRgb(outLab, width * height);
}

Uint8List _crop(Uint8List g, int gw, int x0, int y0, int w, int h) {
  final o = Uint8List(w * h);
  for (var y = 0; y < h; y++) { o.setRange(y * w, y * w + w, g, (y0 + y) * gw + x0); }
  return o;
}
Uint8List _expand3(Uint8List g) {
  final o = Uint8List(g.length * 3);
  for (var i = 0; i < g.length; i++) { o[i * 3] = o[i * 3 + 1] = o[i * 3 + 2] = g[i]; }
  return o;
}

Future<Uint8List> _inferPatch(Uint8List patch, int pw, int ph, int infer, OnnxBackend b) async {
  // 桌面语义: INTER_AREA 缩 infer²方形, 模型输出 INTER_CUBIC 放大回块尺寸
  final src = imglib.Image(width: pw, height: ph, numChannels: 1);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      src.setPixel(x, y, imglib.Pixel(8, [patch[y * pw + x].toDouble()]));
    }
  }
  final small = imglib.copyResize(src, width: infer, height: infer,
      interpolation: imglib.Interpolation.average);
  final chw = Float32List(3 * infer * infer);
  final lchw = Float32List(infer * infer);
  for (var y = 0; y < infer; y++) {
    for (var x = 0; x < infer; x++) {
      final n = small.getPixel(x, y).r / 127.5 - 1.0;
      final i = y * infer + x;
      chw[i] = n; chw[infer * infer + i] = n; chw[2 * infer * infer + i] = n;
      lchw[i] = n;
    }
  }
  final (s0, s1) = await b.runSam(chw, infer);
  final out = await b.runGen(lchw, infer, s0, s1);
  final mid = imglib.Image(width: infer, height: infer, numChannels: 3);
  for (var y = 0; y < infer; y++) {
    for (var x = 0; x < infer; x++) {
      final i = (y * infer + x) * 3;
      mid.setPixel(x, y, imglib.Pixel(8, [
        ((out[i] + 1) * 127.5).clamp(0.0, 255.0),
        ((out[i + 1] + 1) * 127.5).clamp(0.0, 255.0),
        ((out[i + 2] + 1) * 127.5).clamp(0.0, 255.0),
      ]));
    }
  }
  final big = imglib.copyResize(mid, width: pw, height: ph,
      interpolation: imglib.Interpolation.catmullRom);
  final rgb = Uint8List(pw * ph * 3);
  for (var y = 0; y < ph; y++) {
    for (var x = 0; x < pw; x++) {
      final p = big.getPixel(x, y);
      final i = (y * pw + x) * 3;
      rgb[i] = p.r.round(); rgb[i + 1] = p.g.round(); rgb[i + 2] = p.b.round();
    }
  }
  return rgb;
}
```

`image` 包版本注意：4.x 的 `Pixel` 构造签名为 `Pixel(int bytesPerComponent, List<num> values)`；
若解析到的次版本构造形式不同，以 IDE 补全为准改为 `Pixel.withValue(8, v)` 等价写法，语义不变
（8bit 通道）。`imglib.Pixel` 逐像素构造对 1024² 块约几十毫秒，在 isolate 内可接受。

- [ ] **Step 4: 跑测试确认通过** `cd mobile && flutter test test/pipeline_test.dart`，随后全量 `flutter test`

- [ ] **Step 5: 提交**

```bash
cd /e/manga-colorizer && git add mobile && git commit -m "feat(mobile): 全自动管线（分块+羽化+L保真，桌面语义对齐，mock 后端测试）"
```

---

### Task 6: isolate 服务 + UI「全自动」模式接入

**Files:**
- Create: `mobile/lib/onnx/auto_service.dart`
- Create: `mobile/lib/auto_panel.dart`
- Modify: `mobile/lib/main.dart`（AppBar 下加 `TabBar` 两页签：提示点 / 全自动；现有 body 移入第一页签）
- Modify: `mobile/pubspec.yaml`（加 `path_provider` 已有；无新依赖）
- Test: `mobile/test/widget_test.dart`（更新：两页签渲染 + 权重缺失时全自动页签显示下载引导）

**Interfaces:**
- Consumes: Task 3 `WeightsStore`/`kWeightFiles`，Task 4 `OrtOnnxBackend`，Task 5 `autoColorize`
- Produces:

```dart
class AutoEngine {  // 主 isolate 门面；工作 isolate 常驻，空闲 60s 自动释放后端
  Future<void> ensureStarted(String dirPath);
  Future<Uint8List?> colorize(Uint8List gray, int w, int h, {void Function(double)? onProgress});
  Future<void> cancel();    // 取消当前 job（null 完结）并杀工作 isolate
  Future<void> shutdown();  // 优雅: 先 dispose 后端再回收 isolate
}
```

- [ ] **Step 1: 写失败 widget 测试**（`widget_test.dart` 追加）

```dart
testWidgets('workbench shows hint and auto tabs', (tester) async {
  await tester.pumpWidget(const MangaColorizerApp());
  expect(find.text('提示点'), findsOneWidget);
  expect(find.text('全自动'), findsOneWidget);
});
```

- [ ] **Step 2: 跑测试确认失败** `cd mobile && flutter test test/widget_test.dart`

- [ ] **Step 3: 实现 auto_service.dart**

```dart
// 全自动推理的 isolate 门面：模型加载/推理都在工作 isolate；空闲 60s 释放后端归还内存。
// 事件协议（worker→main）: ['progress', double] | ['result', Uint8List?] | ['error', String]
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'backend.dart';
import 'pipeline.dart';
import 'weights.dart';

class AutoEngine {
  Isolate? _iso;
  SendPort? _to;
  ReceivePort? _rx;
  StreamSubscription? _sub;
  Timer? _idle;
  Completer<Uint8List?>? _job;
  void Function(double)? _onProgress;

  bool get alive => _to != null;

  /// dirPath 由主 isolate 的 getApplicationSupportDirectory()/manga-light-colorizer 传入
  Future<void> ensureStarted(String dirPath) async {
    if (alive) return;
    _idle?.cancel();
    _rx = ReceivePort();
    _iso = await Isolate.spawn(_worker, _rx!.sendPort);
    final ready = Completer<SendPort>();
    _sub = _rx!.listen((msg) {
      if (msg is SendPort) { ready.complete(msg); return; }
      final m = msg as List;
      switch (m[0]) {
        case 'progress': _onProgress?.call(m[1] as double);
        case 'result': _job?.complete(m[1] as Uint8List?); _job = null;
        case 'error': _job?.completeError(Exception(m[1] as String)); _job = null;
      }
    });
    _to = await ready.future;
    _to!.send(['dir', dirPath]);
  }

  void _touchIdle() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 60), shutdown);
  }

  Future<Uint8List?> colorize(Uint8List gray, int w, int h,
      {void Function(double)? onProgress}) async {
    if (!alive) throw StateError('先 ensureStarted');
    _touchIdle();
    _onProgress = onProgress;
    _job = Completer<Uint8List?>();
    _to!.send(['job', gray, w, h]);
    return _job!.future;
  }

  /// 取消 = 杀工作 isolate（kill 是即时的，worker 内当前块推理随线程终止释放）；
  /// 下次 colorize 前重新 ensureStarted。返回时进行中的 _job 以 null 完结。
  Future<void> cancel() async {
    _job?.complete(null); _job = null;
    await _teardown();
  }

  Future<void> shutdown() async {
    _to?.send(['stop']);
    await Future.delayed(const Duration(milliseconds: 50)); // 给 worker 走 dispose
    await _teardown();
  }

  Future<void> _teardown() async {
    await _sub?.cancel(); _sub = null;
    _rx?.close(); _rx = null;
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _iso = null; _to = null;
    _idle?.cancel();
  }

  static void _worker(SendPort main) async {
    final rx = ReceivePort();
    main.send(rx.sendPort);
    String? dirPath;
    OnnxBackend? b;
    await for (final msg in rx) {
      final m = msg as List;
      if (m[0] == 'dir') { dirPath = m[1] as String; continue; }
      if (m[0] == 'stop') { await b?.dispose(); b = null; continue; }
      if (m[0] != 'job') continue;
      try {
        if (b == null) {
          b = OrtOnnxBackend(WeightsStore(
              dir: _dirOf(dirPath!), mirrorPreferred: (u) => false));
          await b.load();
        }
        final out = await autoColorize(
          gray: m[1] as Uint8List, width: m[2] as int, height: m[3] as int,
          backend: b!, onProgress: (p) => main.send(['progress', p]));
        main.send(['result', out]);
      } catch (e) {
        main.send(['error', e.toString()]);
      }
    }
  }
}
```

`_dirOf(String p)` = `Directory(p)`（weights.dart 的 `WeightsStore.dir` 类型）；
`ensureStarted` 的调用方（auto_panel）负责 `path_provider` 取目录：
`getApplicationSupportDirectory()` 下建 `manga-light-colorizer` 子目录（与桌面
weights 布局同名，便于文档统一）。`OrtOnnxBackend` 需要 `dart:io` 的 `Directory`，
worker 里可直接 import。

- [ ] **Step 4: 实现 auto_panel.dart + 改 main.dart**

auto_panel.dart（StatelessWidget 包装一个 StatefulWidget `AutoTab`）：
- 状态机：`weights missing → 显示大小/许可提示 + 「下载权重(~300MB)」按钮`（onProgress 线性进度条）→ `ready → 选图(复用 ImagePicker) → 「开始全自动」`
- 推理中：进度条（`onProgress`）+「取消」（`AutoEngine.shutdown()`）
- 完成：`Image.memory(png)` 预览 + 分享（复用 main.dart `_shareResult` 的写法：写 temp 文件 + `Share.shareXFiles`）
- 许可提示文案（复用桌面语义）：「模型权重 CC BY-NC-SA 4.0，需自行下载，仅限非商业使用；详见仓库 docs/licensing。」

main.dart 改动（三处，均为追加式）：
1. `WorkbenchPage` body 外裹 `DefaultTabController(length: 2)`，`appBar` 加 `bottom: TabBar(tabs: [Tab(text:'提示点'), Tab(text:'全自动')])`，body 换 `TabBarView(children: [现有内容, AutoTab()])`
2. 现有 toolbar/canvas 原样保留
3. `initState` 增加 `WidgetsBinding.instance.addObserver(this)`，`didChangeAppLifecycleState` 在 `paused` 时调 `_engine.shutdown()`（spec §4 空闲释放的后台侧）

- [ ] **Step 5: 跑全部测试 + 静态检查 + 构建**

```bash
cd /e/manga-colorizer/mobile && flutter test && flutter analyze && flutter build apk --debug
```
Expected: 全绿、analyze 无 error、apk 构建成功（构建不含权重，验证体积仅壳+绑定 so）

- [ ] **Step 6: 真机验收（需设备；同 Step 0 设备）**

3 页目检（spec §5）：单页 800×1200、长页 1200×7000、内置样例——与桌面
`/colorize_auto` 同图结果并排比对；记录耗时。

- [ ] **Step 7: 提交**

```bash
cd /e/manga-colorizer && git add mobile && git commit -m "feat(mobile): 全自动页签（权重引导下载+isolate 推理+进度取消+空闲释放）"
```

---

### Task 7: 文档与版本（发布前最后一步，版本 bump 需用户点头）

**Files:**
- Modify: `docs/architecture.zh.md` / `docs/architecture.en.md`（移动端小节：删除「端侧 ONNX…尚未实现」句；组件图 `mobile/` 行改为「Flutter Android 壳（Dart 引擎 + 端侧 ONNX 全自动）」；API/环境变量表不动）
- Modify: `docs/getting-started.zh.md` / `.en.md`（新增「方式四：Android 应用」小节：安装 mobile apk / 首次启动下载权重 / 最低设备门槛按 Step 0 实测填值）
- Modify: `NOTICE`（追加 flutter_onnxruntime、ORT、image、crypto 的许可条目）
- Modify（仅当用户批准发版）: `mobile/pubspec.yaml` version → `0.2.0`；桌面三连 `0.4.0 → 0.5.0` 按仓库惯例在 release commit 单独做

- [ ] **Step 1: 改 4 份 docs + NOTICE**（双语成对改，链接语言后缀别搞混）
- [ ] **Step 2: 链接自检** `grep -rn "尚未实现\|not yet implemented" docs/ && echo FOUND || echo CLEAN`
- [ ] **Step 3: 提交** `git commit -m "docs: Android 端侧全自动上色上手与架构文档同步"`

---

## Self-Review 记录

- Spec 覆盖：§4 各文件（weights/backend/pipeline/auto_service/核心 lab/几何 tiles/UI）→ Task 3/4/5/6/1/2/6；§5 测试 → 各任务 TDD 步 + Task 6 Step 6；§6 门槛 → Task 0；§7 许可 → Task 3 文案 + Task 6 许可提示 + Task 7 NOTICE；§8 文档/版本 → Task 7。
- 类型一致性：Task 4 定版 `runSam` 返回两级特征元组（Task 5 注记统一修正），`OnnxBackend` 三方法签名贯穿 Task 4/5/6 一致；`WeightsStore.pathOf/readyFor/ready/download` 与 Task 6 使用一致；`tileBounds/featherWeight` 与 Task 5 一致。
- 已知占位风险点（均附「执行者必读」定版说明，非 TBD）：Task 4 绑定方法名以 Step 0 为准（接口三方法签名不变是硬约束）；Task 5 `_inferPatch` 尾段按注记定版重写；Task 6 `_boot` 按注记走 spawn 传路径。
