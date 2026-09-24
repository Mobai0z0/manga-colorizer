// make_android_icons.dart — 从单一源图标生成 Android 全套启动图标。
//
//   dart run tool/make_android_icons.dart [源图png]
//   默认源图 = mobile/assets/app-icon-512.png
//
// 产出（写入 mobile/android/app/src/main/res/）：
//   · mipmap-<dpi>/ic_launcher.png          旧设备方形图标（< API 26）
//   · mipmap-<dpi>/ic_launcher_round.png    旧设备圆形图标
//   · mipmap-<dpi>/ic_launcher_foreground.png  自适应图标前景（全幅出血）
//   · mipmap-<dpi>/ic_launcher_monochrome.png  自适应 monochrome 层（剪影）
//   · mipmap-anydpi-v26/ic_launcher.xml / ic_launcher_round.xml  自适应图标定义
//   · values/colors.xml                       ic_launcher_background 纯色底
//
// 自适应图标规格：画布 108dp，安全可见区为中心 72dp（系统按圆/方/…裁剪）。
// 前景做全幅出血（源图铺满 108dp），蒙版裁掉外缘，露出满屏渐变与设计主体。
// monochrome 层供 Android 13+「主题图标」动态取色：取源图不透明区域作剪影，
// 系统按主题色整片着色。若想要内部明暗细节，可另供一版单色稿替换同名文件。
import 'dart:io';
import 'package:image/image.dart' as img;

const _resDir = 'mobile/android/app/src/main/res';
// 108dp 前景：mdpi=108px 起，按密度倍数放大。
const _fgDensities = <String, double>{
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};
// 旧设备方形图标：mdpi=48px 起。
const _legacyBase = 48;

// 品牌底色（取源图一角青绿），纯色底 + 启动背景共用。
const _bgR = 30, _bgG = 143, _bgB = 139;

img.Image _coverResize(img.Image src, int n) =>
    img.copyResize(src, width: n, height: n, interpolation: img.Interpolation.cubic);

/// 单色层：取源图不透明区域作剪影（白色 + 源 alpha）。Android 13+「主题图标」
/// 会用它按系统色整片着色，得到干净的单色形状。若想要内部明暗细节，可另供
/// 一版真正的单色稿替换本层（保持 108dp 各密度同名文件即可）。
img.Image _monochrome(img.Image src, int n) {
  final r = _coverResize(src, n);
  final out = img.Image(width: n, height: n, numChannels: 4);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final p = r.getPixel(x, y);
      out.setPixelRgba(x, y, 255, 255, 255, p.a.toInt());
    }
  }
  return out;
}

/// 圆形裁剪版方形图标（旧设备 roundIcon）。
img.Image _roundCropped(img.Image src, int n) {
  final r = _coverResize(src, n);
  final out = img.Image(width: n, height: n, numChannels: 4);
  final rad = n / 2.0;
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final dx = x + 0.5 - rad, dy = y + 0.5 - rad;
      final p = r.getPixel(x, y);
      final inside = (dx * dx + dy * dy) <= rad * rad;
      out.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(),
          inside ? p.a.toInt() : 0);
    }
  }
  return out;
}

void _writePng(String path, img.Image image) {
  File(path).writeAsBytesSync(img.encodePng(image));
}

void main(List<String> args) {
  final srcPath = args.isNotEmpty ? args[0] : 'mobile/assets/app-icon-512.png';
  final src = img.decodePng(File(srcPath).readAsBytesSync());
  if (src == null) {
    stderr.writeln('无法解码 PNG: $srcPath');
    exitCode = 1;
    return;
  }
  stdout.writeln('源图 ${src.width}x${src.height} → $_resDir');

  for (final e in _fgDensities.entries) {
    final dpi = e.key, scale = e.value;
    final fgN = (108 * scale).round();
    final lgN = (_legacyBase * scale).round();
    final dir = '$_resDir/mipmap-$dpi';
    Directory(dir).createSync(recursive: true);
    _writePng('$dir/ic_launcher.png', _coverResize(src, lgN));
    _writePng('$dir/ic_launcher_round.png', _roundCropped(src, lgN));
    _writePng('$dir/ic_launcher_foreground.png', _coverResize(src, fgN));
    _writePng('$dir/ic_launcher_monochrome.png', _monochrome(src, fgN));
    stdout.writeln('  mipmap-$dpi: legacy ${lgN}px, fg/mono ${fgN}px');
  }

  final anydpi = '$_resDir/mipmap-anydpi-v26';
  Directory(anydpi).createSync(recursive: true);
  const xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
''';
  File('$anydpi/ic_launcher.xml').writeAsStringSync(xml);
  File('$anydpi/ic_launcher_round.xml').writeAsStringSync(xml);

  final hex = (_bgR << 16 | _bgG << 8 | _bgB).toRadixString(16).padLeft(6, '0');
  File('$_resDir/values/colors.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#$hex</color>
</resources>
''');
  stdout.writeln('  mipmap-anydpi-v26/*.xml + values/colors.xml (#$hex)');
  stdout.writeln('完成。');
}
