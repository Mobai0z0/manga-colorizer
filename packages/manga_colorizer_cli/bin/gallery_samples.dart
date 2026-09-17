import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:manga_colorizer_cli/src/manga_page_v2.dart';
import 'package:manga_colorizer_cli/src/sample_page.dart';
import 'package:manga_colorizer_core/manga_colorizer_core.dart';

/// 画廊样本生成: 5 张自绘日漫风格样张 (不同网点/墨色风格) + 台账。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('out-dir', defaultsTo: 'out/gallery')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final dir = Directory('${parsed['out-dir']}/samples');
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final samples = <Map<String, Object>>[];
  DecodedImage img;
  String file;

  // S1 现代网点风: v2 页, 网点+渐变背景, 标准墨量。
  file = 's1-gendai-tones.png';
  img = makeMangaPageV2(width: 900, height: 1300, seed: 31);
  _save(dir, file, img);
  samples.add({
    'file': 'samples/$file',
    'title': '無題 (現代トーン風)',
    'titleZh': '现代网点风样张',
    'author': 'AutoClaw 引擎合成 (makeMangaPageV2 seed=31)',
    'year': '2026',
    'style': '规则 50% 网点 + 灰阶渐变背景 + 发丝高光细线',
    'license': 'CC0 1.0 (自绘样张, 无权利保留)',
    'source': '本仓库确定性生成: dart run manga_colorizer_cli:gallery_samples',
  });

  // S2 浓墨实黑风: v2 页无网点, 压暗 0.78。
  file = 's2-noguro-bokashi.png';
  img = makeMangaPageV2(
      width: 900, height: 1300, seed: 52, screentone: false, brightness: 0.78);
  _save(dir, file, img);
  samples.add({
    'file': 'samples/$file',
    'title': '無題 (濃墨・ベタ塗り風)',
    'titleZh': '浓墨实黑风样张',
    'author': 'AutoClaw 引擎合成 (makeMangaPageV2 seed=52, brightness=0.78)',
    'year': '2026',
    'style': '无网点, 大面积实黑 + 压暗灰阶渐变 (昭和剧画倾向)',
    'license': 'CC0 1.0 (自绘样张, 无权利保留)',
    'source': '本仓库确定性生成: dart run manga_colorizer_cli:gallery_samples',
  });

  // S3 早期简笔风: v1 生成器 (细速度线+对话气泡), 淡墨。
  file = 's3-kojitsu-fu.png';
  img = makeSampleManga(width: 720, height: 900, seed: 12, brightness: 0.96);
  _save(dir, file, img);
  samples.add({
    'file': 'samples/$file',
    'title': '無題 (簡筆・初期風)',
    'titleZh': '早期简笔风样张',
    'author': 'AutoClaw 引擎合成 (makeSampleManga seed=12)',
    'year': '2026',
    'style': '细速度线 + 大气泡 + 淡墨 (战后期单页倾向)',
    'license': 'CC0 1.0 (自绘样张, 无权利保留)',
    'source': '本仓库确定性生成: dart run manga_colorizer_cli:gallery_samples',
  });

  // S4 中淡墨网点风: v2 页, 网点 on, 轻压暗。
  file = 's4-chuuawa-tones.png';
  img = makeMangaPageV2(
      width: 900, height: 1300, seed: 77, brightness: 0.92);
  _save(dir, file, img);
  samples.add({
    'file': 'samples/$file',
    'title': '無題 (中淡墨トーン風)',
    'titleZh': '中淡墨网点风样张',
    'author': 'AutoClaw 引擎合成 (makeMangaPageV2 seed=77, brightness=0.92)',
    'year': '2026',
    'style': '网点 + 中淡墨 (平成 weekly 连载页倾向)',
    'license': 'CC0 1.0 (自绘样张, 无权利保留)',
    'source': '本仓库确定性生成: dart run manga_colorizer_cli:gallery_samples',
  });

  // S5 双人群像风: 双人同框。
  file = 's5-futari-gunzou.png';
  img = makeSceneTwoCharacters(width: 900, height: 720, seed: 11);
  _save(dir, file, img);
  samples.add({
    'file': 'samples/$file',
    'title': '無題 (二人同框)',
    'titleZh': '双人群像风样张',
    'author': 'AutoClaw 引擎合成 (makeSceneTwoCharacters seed=11)',
    'year': '2026',
    'style': '双人同框, 深浅两档墨色分区 (跨角色墨量对照)',
    'license': 'CC0 1.0 (自绘样张, 无权利保留)',
    'source': '本仓库确定性生成: dart run manga_colorizer_cli:gallery_samples',
  });

  final ledger = {
    'note': '全部样本为自绘合成样张 (CC0), 非扫描件; 替换为自有扫描图时保持文件名不变即可',
    'count': samples.length,
    'samples': samples,
    'generatedAt': DateTime.now().toIso8601String(),
  };
  File('${parsed['out-dir']}/samples-ledger.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(ledger));
  stdout.writeln('已生成 ${samples.length} 张样本 → ${dir.path}');
}

void _save(Directory dir, String name, DecodedImage img) {
  File('${dir.path}/$name').writeAsBytesSync(MangaImageIO.encodePng(
      rgb: img.rgb, width: img.width, height: img.height));
}
