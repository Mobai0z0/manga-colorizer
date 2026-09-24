import 'package:flutter_test/flutter_test.dart';
import 'package:manga_colorizer_mobile/gallery/gallery_entry.dart';

void main() {
  test('toJson/fromJson 往返保持字段', () {
    final e = GalleryEntry(
      id: '20260924_153001_ab12',
      timeIso: '2026-09-24T15:30:01.000',
      mode: 'hints',
      width: 800,
      height: 1200,
      elapsedS: 4.2,
      hintCount: 3,
      sourceLabel: '内置样例',
      resultFile: '20260924_153001_ab12.png',
      sourceFile: '20260924_153001_ab12_src.png',
      thumbFile: '20260924_153001_ab12_thumb.jpg',
    );
    final json = e.toJson();
    expect(json['elapsed_s'], 4.2);
    expect(json['hint_count'], 3);
    expect(json['source_label'], '内置样例');
    expect(json['result_file'], '20260924_153001_ab12.png');
    expect(json['source_file'], '20260924_153001_ab12_src.png');
    expect(json['thumb_file'], '20260924_153001_ab12_thumb.jpg');
    expect(json['time'], '2026-09-24T15:30:01.000');
    expect(json.containsKey('mode'), isTrue);

    final back = GalleryEntry.fromJson(e.toJson());
    expect(back.id, e.id);
    expect(back.timeIso, e.timeIso);
    expect(back.mode, 'hints');
    expect(back.width, 800);
    expect(back.height, 1200);
    expect(back.elapsedS, 4.2);
    expect(back.hintCount, 3);
    expect(back.sourceLabel, '内置样例');
    expect(back.resultFile, e.resultFile);
    expect(back.sourceFile, e.sourceFile);
    expect(back.thumbFile, e.thumbFile);
  });

  test('fromJson 读取字面账本行（钉住 snake_case 键名）', () {
    final e = GalleryEntry.fromJson({
      'id': 'x1',
      'time': '2026-09-24T08:09:10.000',
      'mode': 'auto',
      'width': 7,
      'height': 9,
      'result_file': 'x1.png',
      'source_file': 'x1_src.png',
      'thumb_file': 'x1_thumb.jpg',
    });
    expect(e.id, 'x1');
    expect(e.timeIso, '2026-09-24T08:09:10.000');
    expect(e.mode, 'auto');
    expect(e.width, 7);
    expect(e.height, 9);
    expect(e.elapsedS, isNull);
    expect(e.hintCount, isNull);
    expect(e.sourceLabel, isNull);
  });

  test('auto 项 elapsed/hintCount 为 null', () {
    final e = GalleryEntry(
      id: 'x',
      timeIso: '2026-09-24T15:30:01.000',
      mode: 'auto',
      width: 10,
      height: 20,
      resultFile: 'x.png',
      sourceFile: 'x_src.png',
      thumbFile: 'x_thumb.jpg',
    );
    final back = GalleryEntry.fromJson(e.toJson());
    expect(back.elapsedS, isNull);
    expect(back.hintCount, isNull);
    expect(back.sourceLabel, isNull);
  });

  test('timeLabel 格式化', () {
    final e = GalleryEntry(
      id: 'x',
      timeIso: '2026-09-24T05:07:09.000',
      mode: 'auto',
      width: 1,
      height: 1,
      resultFile: 'x.png',
      sourceFile: 'x_src.png',
      thumbFile: 'x_thumb.jpg',
    );
    expect(e.timeLabel, '2026-09-24 05:07');
  });
}
