import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
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
    this.onOpenComic,
  });

  final CloudHomeController controller;
  final bool isActive;
  final void Function(CloudHomeItem item, String comicId)? onOpenComic;

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
  int _openRequest = 0;

  CloudHomeController get _controller => widget.controller;
  int get _anchor => _anchors[_controller.directory] ?? 0;

  @override
  void didUpdateWidget(covariant CloudHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) _preloadKey = null;
    if (oldWidget.isActive && !widget.isActive) {
      _openRequest++;
      _navigating = false;
    }
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

  Object get _openingScope => (
    _controller.mountedLibrary?.id,
    _controller.mountedLibrary?.accountId,
    _controller.mount?.directory,
    _controller.sourceKey,
    _controller.directory,
  );

  Future<void> _openItem(CloudHomeItem item) async {
    if (_navigating || _turning || _controller.isLoading || !widget.isActive) {
      return;
    }
    final scope = _openingScope;
    final request = ++_openRequest;
    setState(() => _navigating = true);
    try {
      final resolved = await _controller.resolveItemForOpen(item);
      if (!mounted ||
          !widget.isActive ||
          request != _openRequest ||
          resolved == null ||
          scope != _openingScope) {
        return;
      }
      if (resolved.kind == CloudHomeItemKind.directory) {
        await _controller.openDirectory(resolved.path);
      } else if (resolved.isReadable) {
        _openComic(resolved);
      }
    } catch (error) {
      if (mounted &&
          widget.isActive &&
          request == _openRequest &&
          scope == _openingScope) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && request == _openRequest) {
        setState(() => _navigating = false);
      }
    }
  }

  void _openComic(CloudHomeItem item) {
    final comicId = _controller.comicIdFor(item.path);
    if (widget.onOpenComic != null) {
      widget.onOpenComic!(item, comicId);
      return;
    }
    context.to(
      () => ComicPage(
        id: comicId,
        sourceKey: _controller.sourceKey,
        title: _title(item),
        cover: item.cover,
      ),
    );
  }

  Future<void> _setOverride(
    String path,
    CloudHomeDirectoryOverride value,
  ) async {
    try {
      await _controller.setDirectoryOverride(path, value);
      if (mounted) setState(() => _preloadKey = null);
    } on CloudHomeUnsupportedComicFolder {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(CloudHomeUnsupportedComicFolder.message.tl)),
      );
    }
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
      final library = _controller.mountedLibrary;
      final binding = library == null
          ? null
          : '${library.id}|${library.sourceKey}|${_controller.mount?.directory}';
      if (_bindingKey != binding) {
        _bindingKey = binding;
        _openRequest++;
        _navigating = false;
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
          enabled: volume && library != null,
          active: widget.isActive,
          onPrevious: () => _turnPage(reverse ? 1 : -1),
          onNext: () => _turnPage(reverse ? -1 : 1),
          child: library == null
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
          Text(
            _controller.mount == null
                ? 'No comic library mounted on Home'.tl
                : 'Mounted comic library is unavailable'.tl,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () =>
                showCloudHomeSettings(context, controller: _controller),
            icon: const Icon(Icons.folder_open_outlined),
            label: Text('Choose an imported comic library'.tl),
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
                _controller.isVirtualLibraryRoot
                    ? _controller.mountedLibrary!.name
                    : _controller.directory,
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
          if (!compact)
            PopupMenuButton<String>(
              tooltip: 'Home page'.tl,
              onSelected: (value) async {
                if (value == 'current') {
                  await _controller.setCurrentDirectoryAsHome();
                } else {
                  await _controller.bindLibrary(_controller.mountedLibrary!.id);
                }
              },
              itemBuilder: (_) => [
                if (!_controller.isVirtualLibraryRoot)
                  PopupMenuItem(
                    value: 'current',
                    child: Text('Use current folder as Home'.tl),
                  ),
                PopupMenuItem(
                  value: 'library',
                  child: Text('Comic library home'.tl),
                ),
              ],
            ),
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
        final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
        const horizontalPadding = 16.0;
        const columnSpacing = 12.0;
        const rowSpacing = 20.0;
        final width = math.max(
          1.0,
          constraints.maxWidth - horizontalPadding * 2,
        );
        final minimumWidth = 120 * math.max(1.0, scale * .7);
        final columns = math.max(
          1,
          ((width + columnSpacing) / (minimumWidth + columnSpacing)).floor(),
        );
        final itemWidth = math.max(
          1.0,
          (width - columnSpacing * (columns - 1)) / columns,
        );
        final footerHeight = compact
            ? 0.0
            : 40.0 + 12 * math.max(0.0, scale - 1);
        final safeBottom = math.max(8.0, MediaQuery.paddingOf(context).bottom);
        final available = math.max(
          1.0,
          constraints.maxHeight - footerHeight - safeBottom - 16,
        );
        final titleHeight = 15 * scale * 1.3 * (compact ? 1 : 2);
        final typeHeight = 12 * scale * 1.25;
        final naturalHeight =
            itemWidth * 4 / 3 + 7 + titleHeight + 4 + typeHeight;
        var rows = math.max(
          1,
          ((available + rowSpacing) / (naturalHeight + rowSpacing)).floor(),
        );
        // A small cover reduction avoids losing a whole row at a boundary.
        // Text retains its system scale and covers retain their 3:4 ratio.
        final extraRowHeight = (available - rowSpacing * rows) / (rows + 1);
        final textExtent = 7 + titleHeight + 4 + typeHeight;
        if (extraRowHeight - textExtent >= itemWidth * 4 / 3 * .85) {
          rows++;
        }
        final itemHeight = math.min(
          naturalHeight,
          math.max(1.0, (available - rowSpacing * (rows - 1)) / rows),
        );
        final capacity = rows * columns;
        if (_capacity != capacity) {
          _capacity = capacity;
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
                  horizontalPadding,
                  8,
                  horizontalPadding,
                  compact ? 8 + safeBottom : 8,
                ),
                child: GridView.builder(
                  key: const Key('cloud-home-page-grid'),
                  primary: false,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: itemHeight,
                    crossAxisSpacing: columnSpacing,
                    mainAxisSpacing: rowSpacing,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, index) =>
                      _entry(visible[index], compact: compact),
                ),
              ),
            ),
            if (!compact)
              SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: footerHeight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        key: const Key('cloud-home-previous'),
                        tooltip: 'Previous page'.tl,
                        onPressed: page == 0 || _turning || _navigating
                            ? null
                            : () => _turnPage(-1),
                        icon: const Icon(Icons.chevron_left),
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
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
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
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _title(CloudHomeItem item) =>
      item.isDirectory ? item.name : comicFileStem(item.name);

  String _fileType(CloudHomeItem item) => switch (item.kind) {
    CloudHomeItemKind.directory => 'Folder'.tl,
    CloudHomeItemKind.pdfCollection => 'PDF',
    CloudHomeItemKind.imageComic => 'Images'.tl,
    _ =>
      item.name.contains('.')
          ? item.name.split('.').last.toUpperCase()
          : 'File'.tl,
  };

  Widget _entry(CloudHomeItem item, {required bool compact}) {
    final canOpen = item.isReadable || item.kind == CloudHomeItemKind.directory;
    final icon = switch (item.kind) {
      CloudHomeItemKind.directory => Icons.folder_outlined,
      CloudHomeItemKind.imageComic => Icons.photo_library_outlined,
      CloudHomeItemKind.unsupported => Icons.insert_drive_file_outlined,
      _ => Icons.menu_book_outlined,
    };
    final type = _fileType(item);
    return Semantics(
      label: '${_title(item)}, $type',
      button: canOpen,
      enabled: canOpen,
      child: Material(
        key: ValueKey('cloud-entry-${item.path}'),
        color: Colors.transparent,
        child: InkWell(
          onTap: canOpen ? () => _openItem(item) : null,
          onLongPress: item.isDirectory
              ? () => _showDirectoryOptions(item)
              : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scaler = MediaQuery.textScalerOf(context);
              final titleLine = scaler.scale(15) * 1.3;
              final typeHeight = scaler.scale(12) * 1.25;
              var titleLines = compact ? 1 : 2;
              if (constraints.maxHeight <
                  titleLine * titleLines + typeHeight + 4) {
                titleLines = 1;
              }
              final showType =
                  constraints.maxHeight >=
                  titleLine * titleLines + typeHeight + 4;
              final textHeight =
                  titleLine * titleLines + (showType ? typeHeight + 4 : 0);
              final coverHeight = math.min(
                constraints.maxWidth * 4 / 3,
                math.max(0.0, constraints.maxHeight - textHeight - 7),
              );
              final showCover = coverHeight >= 28;
              final coverWidth = coverHeight * 3 / 4;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showCover) ...[
                    SizedBox(
                      key: ValueKey('cloud-cover-${item.path}'),
                      width: coverWidth,
                      height: coverHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: item.cover == null
                            ? _coverPlaceholder(icon)
                            : Image(
                                image: CachedImageProvider(
                                  item.cover!,
                                  sourceKey: _controller.sourceKey,
                                  cid: _controller.comicIdFor(item.path),
                                ),
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                errorBuilder: (_, error, stackTrace) =>
                                    _coverPlaceholder(icon),
                              ),
                      ),
                    ),
                    const SizedBox(height: 7),
                  ],
                  Flexible(
                    child: Text(
                      _title(item),
                      key: ValueKey('cloud-title-${item.path}'),
                      maxLines: titleLines,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                  ),
                  if (showType) ...[
                    const SizedBox(height: 4),
                    Text(
                      type,
                      key: ValueKey('cloud-type-${item.path}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        height: 1.25,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: .7),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(IconData icon) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Center(
      child: Icon(
        icon,
        size: 32,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
