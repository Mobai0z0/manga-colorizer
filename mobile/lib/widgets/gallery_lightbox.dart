// 图库灯箱：单条记录全屏查看与前后对比。默认展示结果；分段控件在
// 结果 / 原图 / 左右滑动对比之间切换。分享走已在磁盘的结果文件，删除经
// GalleryStore 逐项移除后弹回网格。仅用 Flutter + share_plus，无新依赖。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../gallery/gallery_entry.dart';
import '../gallery/gallery_store.dart';

enum _View { result, source, split }

class GalleryLightboxPage extends StatefulWidget {
  const GalleryLightboxPage({
    super.key,
    required this.entry,
    required this.gallery,
  });

  final GalleryEntry entry;
  final GalleryStore gallery;

  @override
  State<GalleryLightboxPage> createState() => _GalleryLightboxPageState();
}

class _GalleryLightboxPageState extends State<GalleryLightboxPage> {
  _View _view = _View.result;
  double _split = 0.5;

  Widget _file(String name, BoxFit fit) => Image.file(
        File(widget.gallery.pathOf(name)),
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(
            child: Icon(Icons.broken_image_outlined, size: 48)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.entry.mode == 'auto' ? '全自动' : '上色'} · ${widget.entry.timeLabel}'),
        actions: [
          IconButton(
            tooltip: '分享',
            onPressed: _share,
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: _confirmDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SegmentedButton<_View>(
              segments: const [
                ButtonSegment(value: _View.result, label: Text('结果')),
                ButtonSegment(value: _View.source, label: Text('原图')),
                ButtonSegment(value: _View.split, label: Text('对比')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_view) {
      case _View.result:
        return InteractiveViewer(
            child: Center(child: _file(widget.entry.resultFile, BoxFit.contain)));
      case _View.source:
        return InteractiveViewer(
            child: Center(child: _file(widget.entry.sourceFile, BoxFit.contain)));
      case _View.split:
        return _compare();
    }
  }

  // 左右滑动对比：左原图、右结果，_split 为分界线位置。
  Widget _compare() {
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      final h = cons.maxHeight;
      final cw = (w * _split).clamp(0.0, w);
      return Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                    child: _file(widget.entry.resultFile, BoxFit.contain)),
                Positioned(
                  left: 0,
                  top: 0,
                  width: cw,
                  height: h,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 0,
                      maxWidth: w,
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: _file(widget.entry.sourceFile, BoxFit.contain),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: (cw - 1).clamp(0.0, w),
                  top: 0,
                  bottom: 0,
                  child: const VerticalDivider(
                      width: 2, thickness: 2, color: Colors.white),
                ),
              ],
            ),
          ),
          Slider(
            value: _split,
            onChanged: (v) => setState(() => _split = v),
          ),
        ],
      );
    });
  }

  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Share.shareXFiles(
        [XFile(widget.gallery.pathOf(widget.entry.resultFile))],
        text: 'Manga Colorizer 上色结果',
      );
    } on Object {
      messenger.showSnackBar(const SnackBar(content: Text('分享失败')));
    }
  }

  Future<void> _confirmDelete() async {
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
    if (ok != true) return;
    await widget.gallery.delete(widget.entry.id);
    if (mounted) Navigator.of(context).pop();
  }
}
