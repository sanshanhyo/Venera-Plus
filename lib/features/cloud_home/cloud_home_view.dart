import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/volume_navigation.dart';

import 'cloud_home_controller.dart';
import 'cloud_home_settings_view.dart';

/// A screenful of direct remote entries. Data preloading and presentation pages
/// are intentionally separate, so a server's batch size never creates scrolling.
class CloudHomeView extends StatefulWidget {
  const CloudHomeView({
    super.key,
    required this.controller,
    this.isActive = true,
  });

  final CloudHomeController controller;
  final bool isActive;

  @override
  State<CloudHomeView> createState() => _CloudHomeViewState();
}

class _CloudHomeViewState extends State<CloudHomeView> {
  final _anchors = <String, int>{};
  String? _bindingKey;
  String? _preloadKey;
  int _capacity = 1;
  bool _navigating = false;
  bool _turning = false;

  CloudHomeController get _controller => widget.controller;
  int get _anchor => _anchors[_controller.directory] ?? 0;

  @override
  void didUpdateWidget(covariant CloudHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) _preloadKey = null;
  }

  void _schedulePreload(int start, int capacity) {
    if (!widget.isActive || _controller.isLoading) return;
    final key =
        '${_controller.sourceKey}|${_controller.directory}|$start|$capacity';
    if (_preloadKey == key) return;
    _preloadKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isActive || key != _preloadKey) return;
      unawaited(_preload(start, capacity * 2));
    });
  }

  Future<void> _preload(int start, int count) async {
    try {
      await _controller.preload(start: start, count: count);
    } catch (_) {
      // Preloading is advisory. Opening or refreshing an entry reports errors.
    }
  }

  Future<void> _turnPage(int delta) async {
    if (_turning || _navigating || _controller.isLoading) return;
    final directory = _controller.directory;
    final count = _controller.items.length;
    final pages = math.max(1, (count / _capacity).ceil());
    final current = (_anchor ~/ _capacity).clamp(0, pages - 1);
    final next = current + delta;
    if (next < 0 || next >= pages) return;
    final nextStart = next * _capacity;
    setState(() {
      _anchors[directory] = nextStart;
      _turning = true;
    });
    // Coalesce input until this screen is painted. Directory entries are
    // already available; slow cover preloads must never lock navigation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _turning = false);
    });
  }

  Future<void> _openDirectory(String? path) async {
    if (_navigating || _turning) return;
    setState(() => _navigating = true);
    try {
      if (path == null) {
        await _controller.goUp();
      } else {
        await _controller.openDirectory(path);
      }
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  Future<void> _refresh() async {
    if (_controller.isRefreshing || _navigating) return;
    final directory = _controller.directory;
    final items = _controller.items;
    final first = items.isEmpty
        ? null
        : items[math.min(_anchor, items.length - 1)].path;
    await _controller.refresh();
    if (!mounted || directory != _controller.directory) return;
    setState(() {
      if (first != null) {
        final index = _controller.items.indexWhere(
          (item) => item.path == first,
        );
        if (index >= 0) _anchors[directory] = index;
      }
      _preloadKey = null;
    });
  }

  void _openItem(CloudHomeItem item) {
    if (_navigating || _turning) return;
    if (item.kind == CloudHomeItemKind.directory ||
        item.kind == CloudHomeItemKind.pdfCollection) {
      unawaited(_openDirectory(item.path));
    } else if (item.isReadable) {
      context.to(
        () => ComicPage(
          id: item.path,
          sourceKey: _controller.sourceKey,
          title: item.name,
          cover: item.cover,
        ),
      );
    }
  }

  Future<void> _setOverride(
    String path,
    CloudHomeDirectoryOverride value,
  ) async {
    await _controller.setDirectoryOverride(path, value);
    if (mounted) setState(() => _preloadKey = null);
  }

  Future<void> _showDirectoryOptions(CloudHomeItem item) async {
    final selected = await showDialog<CloudHomeDirectoryOverride>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(item.name),
        children: [
          for (final value in CloudHomeDirectoryOverride.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(value),
              child: Row(
                children: [
                  Icon(
                    _controller.directoryOverride(item.path) == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_overrideLabel(value))),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) await _setOverride(item.path, selected);
  }

  String _overrideLabel(CloudHomeDirectoryOverride value) => switch (value) {
    CloudHomeDirectoryOverride.automatic => 'Automatic recognition'.tl,
    CloudHomeDirectoryOverride.folder => 'Treat as folder'.tl,
    CloudHomeDirectoryOverride.comic => 'Treat as comic'.tl,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, appdata.settings]),
    builder: (context, _) {
      final location = _controller.location;
      final binding = location == null
          ? null
          : '${location.accountId}|${location.directory}';
      if (_bindingKey != binding) {
        _bindingKey = binding;
        _anchors.clear();
        _preloadKey = null;
      }
      final volume = appdata.settings['homeCloudVolumeKeys'] != false;
      final reverse = appdata.settings['homeCloudReverseVolumeKeys'] == true;
      return PopScope(
        canPop: !widget.isActive || !_controller.canGoUp,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && widget.isActive && _controller.canGoUp) {
            unawaited(_openDirectory(null));
          }
        },
        child: VolumePageScope(
          enabled: volume && location != null,
          active: widget.isActive,
          onPrevious: () => _turnPage(reverse ? 1 : -1),
          onNext: () => _turnPage(reverse ? -1 : 1),
          child: location == null
              ? _emptyBinding()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final scale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    final compact =
                        constraints.maxHeight < math.max(280, 200 * scale);
                    return Column(
                      children: [
                        _header(compact: compact),
                        if (_controller.error != null && !compact)
                          _errorBanner(),
                        Expanded(child: _directoryContents(compact: compact)),
                      ],
                    );
                  },
                ),
        ),
      );
    },
  );

  Widget _emptyBinding() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_outlined, size: 52),
          const SizedBox(height: 16),
          Text('No cloud folder bound'.tl, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () =>
                showCloudHomeSettings(context, controller: _controller),
            icon: const Icon(Icons.folder_open_outlined),
            label: Text('Select a cloud folder'.tl),
          ),
        ],
      ),
    ),
  );

  Widget _header({required bool compact}) {
    final pages = math.max(1, (_controller.items.length / _capacity).ceil());
    final page = (_anchor ~/ _capacity).clamp(0, pages - 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          IconButton(
            key: const Key('cloud-home-parent'),
            tooltip: 'Parent directory'.tl,
            onPressed: _controller.canGoUp && !_navigating && !_turning
                ? () => _openDirectory(null)
                : null,
            icon: const Icon(Icons.arrow_upward),
          ),
          Expanded(
            child: Tooltip(
              message: _controller.directory,
              child: Text(
                _controller.directory,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          if (!compact && (_controller.isRefreshing || _navigating))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Loading...'.tl,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          if (compact) ...[
            IconButton(
              key: const Key('cloud-home-previous'),
              tooltip: 'Previous page'.tl,
              onPressed: page == 0 || _turning || _navigating
                  ? null
                  : () => _turnPage(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              '${page + 1}/$pages',
              key: const Key('cloud-home-page-number'),
            ),
            IconButton(
              key: const Key('cloud-home-next'),
              tooltip: 'Next page'.tl,
              onPressed: page + 1 >= pages || _turning || _navigating
                  ? null
                  : () => _turnPage(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
          IconButton(
            tooltip: compact && _controller.error != null
                ? _controller.error!
                : 'Refresh'.tl,
            onPressed: _controller.isRefreshing || _navigating
                ? null
                : _refresh,
            icon: Icon(
              compact && _controller.error != null
                  ? Icons.error_outline
                  : Icons.refresh,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.errorContainer,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _controller.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
        TextButton(onPressed: _refresh, child: Text('Retry'.tl)),
        IconButton(
          tooltip: 'Cloud Home Settings'.tl,
          onPressed: () =>
              showCloudHomeSettings(context, controller: _controller),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
  );

  Widget _directoryContents({required bool compact}) {
    final items = _controller.items;
    if (items.isEmpty) {
      return Center(
        child: Text(
          _controller.isLoading
              ? 'Loading...'.tl
              : 'No files in this folder'.tl,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final width = math.max(1.0, constraints.maxWidth - 24);
        final columns = math.max(
          1,
          (width / (300 * math.max(1.0, scale))).floor(),
        );
        final footerHeight = compact ? 0.0 : 52 + 20 * math.max(0.0, scale - 1);
        final bottomPadding = math.max(
          8.0,
          MediaQuery.paddingOf(context).bottom,
        );
        final available = math.max(
          1.0,
          constraints.maxHeight -
              (compact ? bottomPadding : footerHeight - 8 + bottomPadding) -
              16,
        );
        final minHeight = 104 + 44 * math.max(0.0, scale - 1);
        final rows = math.max(1, ((available + 8) / (minHeight + 8)).floor());
        final capacity = rows * columns;
        if (_capacity != capacity) {
          _capacity = capacity;
          // The compact pager is above this LayoutBuilder. Refresh its count
          // once the newly available grid dimensions have been measured.
          if (compact) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          }
        }
        final pages = math.max(1, (items.length / _capacity).ceil());
        final page = (_anchor ~/ _capacity).clamp(0, pages - 1);
        final start = page * _capacity;
        final visible = items.skip(start).take(_capacity).toList();
        _schedulePreload(start, _capacity);
        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  8,
                  12,
                  compact ? 8 + bottomPadding : 8,
                ),
                child: GridView.builder(
                  key: const Key('cloud-home-page-grid'),
                  primary: false,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: math.max(
                      1.0,
                      (available - 8 * (rows - 1)) / rows,
                    ),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, index) => _entry(visible[index]),
                ),
              ),
            ),
            if (!compact)
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SizedBox(
                  height: footerHeight - 8,
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('cloud-home-previous'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 44),
                          ),
                          onPressed: page == 0 || _turning || _navigating
                              ? null
                              : () => _turnPage(-1),
                          child: Semantics(
                            label: 'Previous page'.tl,
                            child: const Icon(Icons.chevron_left),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            '@page / @pages'.tlParams({
                              'page': page + 1,
                              'pages': pages,
                            }),
                            key: const Key('cloud-home-page-number'),
                          ),
                        ),
                      ),
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('cloud-home-next'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 44),
                          ),
                          onPressed:
                              page + 1 >= pages || _turning || _navigating
                              ? null
                              : () => _turnPage(1),
                          child: Semantics(
                            label: 'Next page'.tl,
                            child: const Icon(Icons.chevron_right),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _entry(CloudHomeItem item) {
    final isDirectory = item.isDirectory;
    final readable = item.isReadable || isDirectory;
    final icon = switch (item.kind) {
      CloudHomeItemKind.directory => Icons.folder_outlined,
      CloudHomeItemKind.pdfCollection => Icons.library_books_outlined,
      CloudHomeItemKind.imageComic => Icons.photo_library_outlined,
      CloudHomeItemKind.comicFile => Icons.menu_book_outlined,
      CloudHomeItemKind.unsupported => Icons.insert_drive_file_outlined,
    };
    final label = switch (item.kind) {
      CloudHomeItemKind.directory => 'Folder'.tl,
      CloudHomeItemKind.pdfCollection => 'PDF collection'.tl,
      CloudHomeItemKind.imageComic => 'Image comic'.tl,
      CloudHomeItemKind.comicFile => 'Comic file'.tl,
      CloudHomeItemKind.unsupported => 'Unsupported file'.tl,
    };
    final subtitle = item.fileCount == null
        ? label
        : '$label · ${'@count files'.tlParams({'count': item.fileCount!})}';
    return Semantics(
      label: '${item.name}, $subtitle',
      button: readable,
      enabled: readable,
      child: Material(
        key: ValueKey('cloud-entry-${item.path}'),
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: readable ? () => _openItem(item) : null,
          onLongPress: isDirectory ? () => _showDirectoryOptions(item) : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scaler = MediaQuery.textScalerOf(context);
              final titleStyle = Theme.of(context).textTheme.titleSmall;
              final labelStyle = Theme.of(context).textTheme.labelSmall;
              final titleHeight =
                  scaler.scale(titleStyle?.fontSize ?? 14) * 1.6;
              final labelHeight =
                  scaler.scale(labelStyle?.fontSize ?? 11) * 1.6;
              final verticalPadding = constraints.maxHeight < titleHeight + 24
                  ? 0.0
                  : 8.0;
              final height = math.max(
                0.0,
                constraints.maxHeight - 2 * verticalPadding,
              );
              final showSubtitle = height >= titleHeight + labelHeight + 4;
              final titleLines =
                  height >=
                      titleHeight * 2 + (showSubtitle ? labelHeight + 4 : 0)
                  ? 2
                  : 1;
              final showCover = height >= 66;
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  verticalPadding,
                  4,
                  verticalPadding,
                ),
                child: Row(
                  children: [
                    if (showCover)
                      SizedBox(
                        width: 44,
                        height: 66,
                        child: item.cover == null
                            ? Icon(icon, size: 36)
                            : Image(
                                image: CachedImageProvider(
                                  item.cover!,
                                  sourceKey: _controller.sourceKey,
                                  cid: item.path,
                                ),
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) =>
                                    Icon(icon, size: 36),
                              ),
                      ),
                    if (showCover) const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              item.name,
                              maxLines: titleLines,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle,
                            ),
                          ),
                          if (showSubtitle) ...[
                            const SizedBox(height: 4),
                            Flexible(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: labelStyle,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (isDirectory && height >= 48)
                      IconButton(
                        tooltip: 'Recognition options'.tl,
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => _showDirectoryOptions(item),
                      )
                    else
                      const SizedBox(width: 8),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
