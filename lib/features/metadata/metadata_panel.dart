import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_service.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/translations.dart';

bool supportsMetadataCompletion(String sourceKey) =>
    sourceKey == 'local' || WebDavLibraryEngines.find(sourceKey) != null;

/// Returns whether the comic's saved information changed while the panel was open.
Future<bool> showMetadataPanel(
  BuildContext context, {
  required String sourceKey,
  required String comicId,
  required String comicTitle,
  MetadataService? service,
  VoidCallback? onChanged,
}) async {
  var changed = false;
  await showSideBar(
    context,
    MetadataPanel(
      sourceKey: sourceKey,
      comicId: comicId,
      comicTitle: comicTitle,
      service: service,
      onChanged: () {
        changed = true;
        onChanged?.call();
      },
    ),
  );
  return changed;
}

class MetadataPanel extends StatefulWidget {
  const MetadataPanel({
    super.key,
    required this.sourceKey,
    required this.comicId,
    required this.comicTitle,
    this.service,
    this.onChanged,
  });

  final String sourceKey;
  final String comicId;
  final String comicTitle;
  final MetadataService? service;
  final VoidCallback? onChanged;

  @override
  State<MetadataPanel> createState() => _MetadataPanelState();
}

class _MetadataPanelState extends State<MetadataPanel> {
  late final MetadataService _service;
  late final TextEditingController _input;
  late final TextEditingController _jmBaseUrl;
  late final TextEditingController _jmCoverBaseUrl;
  MetadataProviderId _provider = MetadataProviderId.ehentai;
  MetadataBinding? _binding;
  MetadataResult? _result;
  Future<Uint8List>? _cover;
  bool _cacheCover = false;
  bool _busy = false;
  bool _available = true;
  String? _error;
  String? _notice;
  String? _coverWarning;

  bool get _disabled => _busy || !_available;

  @override
  void initState() {
    super.initState();
    var jmBaseUrl = '';
    var jmCoverBaseUrl = '';
    try {
      _service = widget.service ?? MetadataService();
      _binding = _service.find(widget.sourceKey, widget.comicId);
      jmBaseUrl = _service.jmBaseUrl;
      jmCoverBaseUrl = _service.jmCoverBaseUrl;
    } catch (_) {
      _available = false;
      _error = 'Local information is unavailable'.tl;
    }
    final binding = _binding;
    _result = binding?.result;
    _provider = binding?.result.reference.provider ?? _provider;
    _cacheCover = binding?.cacheCover ?? false;
    if (_available && binding != null && binding.result.coverUrl != null) {
      _cover = _service.loadBindingCover(binding);
    }
    _input = TextEditingController(
      text: binding?.result.reference.sourceUrl ?? '',
    );
    _jmBaseUrl = TextEditingController(text: jmBaseUrl);
    _jmCoverBaseUrl = TextEditingController(text: jmCoverBaseUrl);
  }

  @override
  void dispose() {
    _input.dispose();
    _jmBaseUrl.dispose();
    _jmCoverBaseUrl.dispose();
    super.dispose();
  }

  void _clearPreview() {
    setState(() {
      _result = null;
      _cover = null;
      _error = null;
      _notice = null;
      _coverWarning = null;
    });
  }

  Future<void> _fetch() async {
    if (_disabled) return;
    if (_input.text.trim().isEmpty) {
      setState(() => _error = 'Enter a source link or ID'.tl);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _result = null;
      _cover = null;
      _error = null;
      _notice = null;
      _coverWarning = null;
    });
    try {
      if (_provider == MetadataProviderId.jmcomic &&
          (_jmBaseUrl.text.trim() != _service.jmBaseUrl ||
              _jmCoverBaseUrl.text.trim() != _service.jmCoverBaseUrl)) {
        await _service.configureJm(
          baseUrl: _jmBaseUrl.text.trim(),
          coverBaseUrl: _jmCoverBaseUrl.text.trim(),
        );
        if (!mounted) return;
      }
      final result = await _service.fetch(
        _input.text.trim(),
        provider: _provider,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _cover = result.coverUrl == null ? null : _service.loadCover(result);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final result = _result;
    if (_disabled || result == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _coverWarning = null;
    });
    try {
      final saved = await _service.save(
        sourceKey: widget.sourceKey,
        comicId: widget.comicId,
        result: result,
        cacheCover: _cacheCover,
      );
      widget.onChanged?.call();
      if (!mounted) return;
      setState(() {
        _binding = saved.binding;
        _notice = 'Information saved locally'.tl;
        _coverWarning = saved.coverError == null
            ? null
            : 'Information saved, but the cover could not be cached'.tl;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Information could not be saved locally'.tl);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_disabled || _binding == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove saved information'.tl),
        content: Text('The original comic information will be restored.'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _coverWarning = null;
    });
    try {
      await _service.remove(widget.sourceKey, widget.comicId);
      widget.onChanged?.call();
      if (!mounted) return;
      setState(() {
        _binding = null;
        _result = null;
        _cover = null;
        _notice = 'Saved information removed'.tl;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Saved information could not be removed'.tl);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) => error
      .toString()
      .replaceFirst(
        RegExp(r'^(?:Exception|FormatException|StateError):\s*'),
        '',
      )
      .tl;

  @override
  Widget build(BuildContext context) => PopUpWidgetScaffold(
    title: 'Complete information'.tl,
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.comicTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text('Saved information applies to this comic on this device.'.tl),
          const SizedBox(height: 20),
          DropdownButtonFormField<MetadataProviderId>(
            key: const Key('metadata-provider'),
            initialValue: _provider,
            decoration: InputDecoration(
              labelText: 'Information source'.tl,
              border: const OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: MetadataProviderId.ehentai,
                child: Text('E-Hentai'),
              ),
              DropdownMenuItem(
                value: MetadataProviderId.jmcomic,
                child: Text('JMComic'),
              ),
            ],
            onChanged: _disabled
                ? null
                : (provider) {
                    if (provider == null || provider == _provider) return;
                    _provider = provider;
                    _clearPreview();
                  },
          ),
          if (_provider == MetadataProviderId.jmcomic)
            ExpansionTile(
              key: const Key('metadata-jm-settings'),
              tilePadding: EdgeInsets.zero,
              title: Text('JM connection settings'.tl),
              // Outlined fields paint their floating labels above their box.
              // Keep that paint inside ExpansionTile's animated body clip.
              childrenPadding: const EdgeInsets.only(top: 12, bottom: 12),
              children: [
                TextField(
                  key: const Key('metadata-jm-base-url'),
                  controller: _jmBaseUrl,
                  enabled: !_disabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Website address'.tl,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _clearPreview(),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('metadata-jm-cover-base-url'),
                  controller: _jmCoverBaseUrl,
                  enabled: !_disabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Cover address'.tl,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _clearPreview(),
                ),
                const SizedBox(height: 8),
                Text('Addresses are saved when you fetch information.'.tl),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('metadata-reference'),
            controller: _input,
            enabled: !_disabled,
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 2,
            minLines: 1,
            decoration: InputDecoration(
              labelText: 'Source link or ID'.tl,
              helperText: _provider == MetadataProviderId.ehentai
                  ? 'E-Hentai gallery link'.tl
                  : 'JM ID or album link'.tl,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _clearPreview(),
            onSubmitted: _disabled ? null : (_) => _fetch(),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const Key('metadata-fetch'),
            onPressed: _disabled ? null : _fetch,
            icon: const Icon(Icons.cloud_download_outlined),
            label: Text('Fetch information'.tl),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null) _status(_error!, isError: true),
          if (_notice != null) _status(_notice!),
          if (_coverWarning != null) _status(_coverWarning!, isError: true),
          if (_binding != null) ...[
            const SizedBox(height: 16),
            Text(
              'Saved source: @source'.tlParams({
                'source':
                    _binding!.result.reference.provider ==
                        MetadataProviderId.ehentai
                    ? 'E-Hentai'
                    : 'JMComic',
              }),
            ),
            Text(
              _binding!.coverPath == null
                  ? 'Cover is not cached locally'.tl
                  : 'Cover cached locally'.tl,
            ),
          ],
          if (_result != null) ...[
            const Divider(height: 32),
            _preview(_result!),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              key: const Key('metadata-cache-cover'),
              contentPadding: EdgeInsets.zero,
              title: Text('Cache cover locally'.tl),
              value: _cacheCover,
              onChanged: _disabled
                  ? null
                  : (value) => setState(() {
                      _cacheCover = value;
                      _notice = null;
                      _coverWarning = null;
                    }),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('metadata-save'),
              onPressed: _disabled ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text('Save locally'.tl),
            ),
          ],
          if (_binding != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('metadata-remove'),
              onPressed: _disabled ? null : _remove,
              icon: const Icon(Icons.restore),
              label: Text('Remove saved information'.tl),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _status(String message, {bool isError = false}) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      message,
      style: isError
          ? TextStyle(color: Theme.of(context).colorScheme.error)
          : null,
    ),
  );

  Widget _preview(MetadataResult result) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Preview'.tl, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      if (_cover != null)
        FutureBuilder<Uint8List>(
          future: _cover,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text('Cover preview unavailable'.tl);
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Image.memory(
                snapshot.data!,
                height: 160,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Text('Cover preview unavailable'.tl),
              ),
            );
          },
        ),
      SelectableText(
        result.title,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      if (result.authors.isNotEmpty) ...[
        const SizedBox(height: 8),
        SelectableText(result.authors.join(', ')),
      ],
      if (result.pageCount != null) ...[
        const SizedBox(height: 8),
        Text('Pages: @count'.tlParams({'count': result.pageCount!})),
      ],
      if (result.description.trim().isNotEmpty) ...[
        const SizedBox(height: 8),
        SelectableText(result.description),
      ],
      for (final entry in result.tags.entries) ...[
        const SizedBox(height: 8),
        Text(entry.key, style: Theme.of(context).textTheme.labelLarge),
        Text(entry.value.join(', ')),
      ],
    ],
  );
}
