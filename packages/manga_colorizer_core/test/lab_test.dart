import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';
import 'package:test/test.dart';

// 8bit RGB↔Lab 对拍 cv2 金样。容差依据(实测):
//  1. 正向 rgbToLab vs cv2.COLOR_RGB2LAB: 差 <=2 即对齐(实测最大 1);
//  2. 逆向用 cv2 的 lab 作输入单独对拍 cv2.COLOR_LAB2RGB 的 back(实测最大 1,
//     隔离正向量化差的放大);
//  3. 全往返 rt vs 原 rgb / rt vs cv2 back: 8bit Lab 量化对饱和色本身就是有损的
//     —— cv2 自家往返 back vs rgb 实测最大差 14, 故该断言只能放宽到量化地板
//     (16), 它不是对齐性的主判据, 1/2 才是。
void main() {
  for (final name in ['noise', 'strip']) {
    test('lab golden $name matches cv2 within quantization', () {
      final d = jsonDecode(
              File('test/goldens/lab_golden_$name.json').readAsStringSync())
          as Map<String, dynamic>;
      final rgb = (d['rgb'] as List).cast<int>().map<int>((e) => e).toList();
      final lab = (d['lab'] as List).cast<int>().map<int>((e) => e).toList();
      final back =
          (d['rgb_back'] as List).cast<int>().map<int>((e) => e).toList();
      final n = rgb.length ~/ 3;
      expect(n, greaterThan(0)); // 防呆: 空样本

      // 1) 正向: 我们的 Lab 对拍 cv2 Lab。
      final got = rgbToLab(Uint8List.fromList(rgb), n);
      // 2) 逆向(隔离): 用 cv2 的 Lab 喂我们的逆, 对拍 cv2 的 back。
      final invOnCv2 = labToRgb(Uint8List.fromList(lab), n);
      // 3) 全往返(量化地板断言, 见文件头注释)。
      final rt = labToRgb(got, n);
      for (var i = 0; i < rgb.length; i++) {
        expect((got[i] - lab[i]).abs(), lessThanOrEqualTo(2),
            reason: 'fwd $name@$i got=${got[i]} cv2=${lab[i]}');
        expect((invOnCv2[i] - back[i]).abs(), lessThanOrEqualTo(2),
            reason: 'inv $name@$i ours=${invOnCv2[i]} cv2=${back[i]}');
        expect((rt[i] - rgb[i]).abs(), lessThanOrEqualTo(16),
            reason: 'roundtrip(quantization floor) $name@$i');
        expect((rt[i] - back[i]).abs(), lessThanOrEqualTo(16),
            reason: 'rt vs cv2 back(quantization floor) $name@$i');
      }
    });
  }

  test('grayToLabL 与 rgbToLab 在灰度输入下逐值一致（全 256 值）', () {
    // 灰度退化 RGB（R=G=B）的 a/b 恒为偏置 128，L 只依赖灰度值；grayToLabL
    // 的系数求和顺序与 rgbToLab 一致，256 个 8bit 输入必须逐位相等。
    final gray = Uint8List(256);
    final rgb = Uint8List(256 * 3);
    for (var g = 0; g < 256; g++) {
      gray[g] = g;
      rgb[g * 3] = rgb[g * 3 + 1] = rgb[g * 3 + 2] = g;
    }
    final lab = rgbToLab(rgb, 256);
    final l = grayToLabL(gray);
    for (var g = 0; g < 256; g++) {
      expect(lab[g * 3 + 1], 128, reason: 'a 偏置 g=$g');
      expect(lab[g * 3 + 2], 128, reason: 'b 偏置 g=$g');
      expect(l[g], lab[g * 3], reason: 'L g=$g');
    }
  });
}
