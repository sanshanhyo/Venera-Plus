import 'package:flutter/material.dart';
import 'package:venera_plus/features/settings/content_sources_page.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'cloud_home_controller.dart';

String cloudHomeLibrarySummary() {
  final mount = readCloudHomeMount();
  if (mount == null) return 'Not Configured'.tl;
  final library = RemoteStorageAccounts.instance.libraries
      .where((library) => library.id == mount.libraryId)
      .firstOrNull;
  if (library == null) return 'Comic library unavailable'.tl;
  return mount.directory == null
      ? library.name
      : '${library.name} · ${mount.directory}';
}

Future<bool?> showCloudHomeSettings(
  BuildContext context, {
  CloudHomeController? controller,
}) => showDialog<bool>(
  context: context,
  builder: (_) => _CloudHomeSettings(controller: controller),
);

class _CloudHomeSettings extends StatefulWidget {
  const _CloudHomeSettings({this.controller});

  final CloudHomeController? controller;

  @override
  State<_CloudHomeSettings> createState() => _CloudHomeSettingsState();
}

class _CloudHomeSettingsState extends State<_CloudHomeSettings> {
  late final CloudHomeController _controller;
  String? _libraryId;
  String? _directory;
  late bool _volumeKeys;
  late bool _reverseKeys;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? CloudHomeController();
    final mount = _controller.mount ?? readCloudHomeMount();
    _libraryId = mount?.libraryId;
    if (_libraryId == null && _controller.libraries.length == 1) {
      _libraryId = _controller.libraries.single.id;
    }
    _directory = mount?.directory;
    final library = _controller.libraries
        .where((library) => library.id == _libraryId)
        .firstOrNull;
    if (_directory != null &&
        library != null &&
        !library.directories.any(
          (root) => normalizeRemoteDirectory(
            _directory!,
          ).startsWith(normalizeRemoteDirectory(root)),
        )) {
      _directory = null;
    }
    _volumeKeys = appdata.settings['homeCloudVolumeKeys'] != false;
    _reverseKeys = appdata.settings['homeCloudReverseVolumeKeys'] == true;
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  Future<void> _save({bool remove = false}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (remove) {
        await _controller.unbind();
      } else {
        await _controller.bindLibrary(_libraryId!, directory: _directory);
        appdata.settings['homeView'] = 'cloud';
      }
      appdata.settings['homeCloudVolumeKeys'] = _volumeKeys;
      appdata.settings['homeCloudReverseVolumeKeys'] = _reverseKeys;
      await appdata.saveData(false);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _manageLibraries() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const ContentSourcesPage()));
    if (mounted) setState(() {});
  }

  Future<void> _chooseDirectory(RemoteLibrary library) async {
    final selected = await showDialog<_HomeDirectorySelection>(
      context: context,
      builder: (_) => _LibraryDirectoryPicker(
        controller: _controller,
        library: library,
        initialDirectory: _directory,
      ),
    );
    if (mounted && selected != null) {
      setState(() => _directory = selected.directory);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, appdata.settings]),
    builder: (context, _) {
      final libraries = _controller.libraries;
      final library = libraries
          .where((library) => library.id == _libraryId)
          .firstOrNull;
      final configured =
          _controller.mount != null || readCloudHomeMount() != null;
      return PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title: Text('Cloud Home Settings'.tl),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Show an imported comic library on Home.'.tl),
                  const SizedBox(height: 20),
                  if (libraries.isEmpty) ...[
                    Text(
                      'Import an online comic library in Settings first.'.tl,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('cloud-home-manage-libraries'),
                      onPressed: _saving ? null : _manageLibraries,
                      icon: const Icon(Icons.library_books_outlined),
                      label: Text('Online Comic Libraries'.tl),
                    ),
                  ] else ...[
                    DropdownButtonFormField<String>(
                      key: const Key('cloud-home-library'),
                      initialValue: library?.id,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Comic Library'.tl,
                      ),
                      items: [
                        for (final library in libraries)
                          DropdownMenuItem(
                            value: library.id,
                            child: Text(
                              library.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                              _libraryId = value;
                              _directory = null;
                            }),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      key: const Key('cloud-home-start-directory'),
                      contentPadding: EdgeInsets.zero,
                      title: Text('Start page'.tl),
                      subtitle: Text(
                        _directory ?? 'Comic library home'.tl,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _saving || library == null
                          ? null
                          : () => _chooseDirectory(library),
                    ),
                  ],
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Use volume keys in Cloud Home'.tl),
                    subtitle: Text(
                      'Volume up: previous page. Volume down: next page.'.tl,
                    ),
                    value: _volumeKeys,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _volumeKeys = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Reverse Cloud Home volume keys'.tl),
                    value: _reverseKeys,
                    onChanged: _saving || !_volumeKeys
                        ? null
                        : (value) => setState(() => _reverseKeys = value),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_saving) ...[
                    const SizedBox(height: 12),
                    Text('Saving...'.tl),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (configured)
              TextButton(
                onPressed: _saving ? null : () => _save(remove: true),
                child: Text('Remove Home mount'.tl),
              ),
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              key: const Key('cloud-home-save-settings'),
              onPressed: _saving || library == null ? null : () => _save(),
              child: Text('Save'.tl),
            ),
          ],
        ),
      );
    },
  );
}

class _HomeDirectorySelection {
  const _HomeDirectorySelection(this.directory);

  final String? directory;
}

/// A library-scoped picker. Its first page contains only the imported roots;
/// browsing can never escape to the account's server root.
class _LibraryDirectoryPicker extends StatefulWidget {
  const _LibraryDirectoryPicker({
    required this.controller,
    required this.library,
    this.initialDirectory,
  });

  final CloudHomeController controller;
  final RemoteLibrary library;
  final String? initialDirectory;

  @override
  State<_LibraryDirectoryPicker> createState() =>
      _LibraryDirectoryPickerState();
}

class _LibraryDirectoryPickerState extends State<_LibraryDirectoryPicker> {
  String? _directory;
  List<RemoteEntry> _entries = const [];
  final _parents = <String?>[];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _directory = widget.initialDirectory;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.controller.listLibraryDirectories(
        widget.library.id,
        directory: _directory,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _open(String path) {
    _parents.add(_directory);
    _directory = path;
    _load();
  }

  void _up() {
    _directory = _parents.isEmpty ? null : _parents.removeLast();
    _load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Start page'.tl),
    content: SizedBox(
      width: 400,
      height: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Comic library home'.tl,
                onPressed: _directory == null || _loading ? null : _up,
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: Text(
                  _directory ?? widget.library.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(),
          Expanded(
            child: _loading
                ? Center(child: Text('Loading...'.tl))
                : _error != null
                ? Center(
                    child: TextButton(
                      onPressed: _load,
                      child: Text('Retry'.tl),
                    ),
                  )
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        title: Text(entry.name),
                        leading: const Icon(Icons.folder_outlined),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(entry.path),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text('Cancel'.tl),
      ),
      FilledButton(
        key: const Key('cloud-home-select-start-page'),
        onPressed: _loading || _error != null
            ? null
            : () => Navigator.of(
                context,
              ).pop(_HomeDirectorySelection(_directory)),
        child: Text('Use this page'.tl),
      ),
    ],
  );
}
