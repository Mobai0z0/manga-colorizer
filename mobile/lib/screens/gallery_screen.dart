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

class _GalleryScreenState extends State<GalleryScreen> {
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
      appBar: screenAppBar(context, title: '图库', controller: widget.controller),
      body: ListenableBuilder(
        listenable: widget.gallery,
        builder: (context, _) {
          final entries = widget.gallery.entries;
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

  Widget _cell(BuildContext context, GalleryEntry e) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _openLightbox(e),
      onLongPress: () => _confirmDelete(e),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(fit: StackFit.expand, children: [
          Image.file(File(widget.gallery.pathOf(e.thumbFile)),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: scheme.surfaceContainerHighest)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black.withValues(alpha: 0.45),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(children: [
                Text(e.mode == 'auto' ? '全自动' : '上色',
                    style: TextStyle(
                        fontSize: 11,
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(e.timeLabel,
                    style: TextStyle(fontSize: 11, color: scheme.onPrimary)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
