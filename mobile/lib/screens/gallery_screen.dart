// 图库目的地：展示本机已保存的上色/全自动结果。三态——
// 空态引导、软上限提示条（仅提示，绝不自动删除）、缩略图网格。点格进灯箱
// 看全图与前后对比，长按删除。数据来自注入的 GalleryStore（ChangeNotifier），
// 经 ListenableBuilder 实时刷新。
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../gallery/gallery_entry.dart';
import '../gallery/gallery_store.dart';
import '../shell/screen_chrome.dart';
import '../theme/warm_tokens.dart';
import '../widgets/gallery_lightbox.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    required this.controller,
    required this.gallery,
  });

  final SettingsController controller;
  final GalleryStore gallery;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

/// 图库排序方式。
enum _GallerySort { newest, oldest, type }

class _GalleryScreenState extends State<GalleryScreen> {
  _GallerySort _sort = _GallerySort.newest;

  /// 按当前排序产出展示列表（默认 newest 与旧行为一致：时间新→旧）。
  List<GalleryEntry> get _sorted {
    final list = List<GalleryEntry>.from(widget.gallery.entries);
    switch (_sort) {
      case _GallerySort.newest:
        list.sort((a, b) => b.timeIso.compareTo(a.timeIso));
      case _GallerySort.oldest:
        list.sort((a, b) => a.timeIso.compareTo(b.timeIso));
      case _GallerySort.type:
        list.sort((a, b) {
          final c = a.mode.compareTo(b.mode);
          if (c != 0) return c;
          return b.timeIso.compareTo(a.timeIso);
        });
    }
    return list;
  }

  void _openLightbox(GalleryEntry e) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GalleryLightboxPage(entry: e, gallery: widget.gallery),
    ));
  }

  Future<void> _confirmDelete(GalleryEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条图库记录？'),
        content: const Text('将从本机移除该记录的结果图、原图与缩略图，不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await widget.gallery.delete(e.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: screenAppBar(
        context,
        title: '图库',
        controller: widget.controller,
        actions: [
          PopupMenuButton<_GallerySort>(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                  value: _GallerySort.newest, child: Text('时间（新→旧）')),
              PopupMenuItem(
                  value: _GallerySort.oldest, child: Text('时间（旧→新）')),
              PopupMenuItem(
                  value: _GallerySort.type, child: Text('按类型（全自动/提示点）')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.gallery,
        builder: (context, _) {
          final entries = _sorted;
          if (entries.isEmpty) return _empty(context);
          return Column(
            children: [
              if (widget.gallery.overSoftCap) _capBanner(context, entries.length),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _cell(context, entries[i]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.photo_library_outlined,
              size: 56,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('还没有作品', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('上色 / 全自动完成后会自动保存在这里', textAlign: TextAlign.center),
        ]),
      ),
    );
  }

  Widget _capBanner(BuildContext context, int count) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text('已保存 $count 项，占用较多存储，可长按删除旧作品',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ]),
      ),
    );
  }

  /// 信息条第二行：与桌面 `.g-row` 同口径的数据（分辨率 / 提示点数或耗时 /
  /// 参考图来源），等宽字体 + 数字等宽对齐。
  String _metaLine(GalleryEntry e) {
    final parts = <String>['${e.width}×${e.height}'];
    if (e.hintCount != null) parts.add('提示点 ×${e.hintCount}');
    if (e.elapsedS != null) parts.add('耗时 ${e.elapsedS!.toStringAsFixed(1)}s');
    if (e.sourceLabel != null) parts.add('参考 ${e.sourceLabel}');
    return parts.join(' · ');
  }

  Widget _cell(BuildContext context, GalleryEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: () => _openLightbox(e),
      onLongPress: () => _confirmDelete(e),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(children: [
          Expanded(
            child: Image.file(File(widget.gallery.pathOf(e.thumbFile)),
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    ColoredBox(color: scheme.surfaceContainerHighest)),
          ),
          // 信息条取代旧的黑 45% 渐变叠层：模式/时间一行 + 等宽数据一行。
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(e.modeLabel,
                      style: text.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(e.timeLabel,
                      style: text.labelSmall?.copyWith(
                          fontFamily: kMonoFamily,
                          color: scheme.onSurfaceVariant)),
                ]),
                const SizedBox(height: 3),
                Text(_metaLine(e),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(
                        fontSize: 10.5,
                        letterSpacing: 0.1,
                        color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
