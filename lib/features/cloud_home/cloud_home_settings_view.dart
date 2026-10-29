import 'package:flutter/material.dart';
import 'package:venera_plus/features/storage/remote_location_fields.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'cloud_home_controller.dart';

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
  String? _accountId;
  List<String> _directories = const [];
  late bool _volumeKeys;
  late bool _reverseKeys;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? CloudHomeController();
    final raw = appdata.settings['homeRemoteLocation'];
    final location =
        _controller.location ??
        (raw is Map ? RemoteLocation.fromJson(raw) : null);
    _accountId = location?.accountId;
    _directories = location == null ? const [] : [location.directory];
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
        await _controller.bind(
          RemoteLocation(
            accountId: _accountId!,
            directory: _directories.single,
          ),
        );
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

  @override
  Widget build(BuildContext context) {
    final account = _accountId == null
        ? null
        : RemoteStorageAccounts.instance.account(_accountId!);
    final configured = appdata.settings['homeRemoteLocation'] is Map;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('Cloud Home Settings'.tl),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Show the direct contents of one cloud folder on Home.'.tl,
                ),
                const SizedBox(height: 20),
                IgnorePointer(
                  ignoring: _saving,
                  child: RemoteLocationFields(
                    accountId: _accountId,
                    directories: _directories,
                    onChanged: (account, directories) => setState(() {
                      _accountId = account?.id;
                      _directories = directories;
                    }),
                  ),
                ),
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
              child: Text('Unbind cloud folder'.tl),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: _saving || account == null || _directories.length != 1
                ? null
                : () => _save(),
            child: Text('Save'.tl),
          ),
        ],
      ),
    );
  }
}
