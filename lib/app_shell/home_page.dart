import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_controller.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_settings_view.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_view.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.onOpenHistory,
    this.isActive = true,
    this.cloudController,
  });

  final VoidCallback? onOpenHistory;
  final bool isActive;
  final CloudHomeController? cloudController;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final CloudHomeController _cloud;
  late bool _visitedFavorites;
  late bool _visitedCloud;

  bool get _showCloud => appdata.settings['homeView'] == 'cloud';

  @override
  void initState() {
    super.initState();
    _cloud = widget.cloudController ?? CloudHomeController();
    _visitedCloud = _showCloud;
    _visitedFavorites = !_showCloud;
    appdata.settings.addListener(_onSettingsChanged);
    unawaited(_cloud.initialize());
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    setState(() {
      _visitedCloud |= _showCloud;
      _visitedFavorites |= !_showCloud;
    });
  }

  void _select(bool cloud) {
    appdata.settings['homeView'] = cloud ? 'cloud' : 'favorites';
    unawaited(appdata.saveData(false));
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsChanged);
    if (widget.cloudController == null) _cloud.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _showCloud;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.bookmarks_outlined),
                  label: Text('Favorites'.tl),
                ),
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.cloud_outlined),
                  label: Text('Cloud'.tl),
                ),
              ],
              selected: {cloud},
              onSelectionChanged: (values) => _select(values.single),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              if (_visitedFavorites)
                Positioned.fill(
                  child: Offstage(
                    offstage: cloud,
                    child: TickerMode(
                      enabled: !cloud && widget.isActive,
                      child: ReadingFavoritesView(
                        onOpenHistory: widget.onOpenHistory,
                      ),
                    ),
                  ),
                ),
              if (_visitedCloud)
                Positioned.fill(
                  child: Offstage(
                    offstage: !cloud,
                    child: TickerMode(
                      enabled: cloud && widget.isActive,
                      child: CloudHomeView(
                        controller: _cloud,
                        isActive: cloud && widget.isActive,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Keeps the shell action in sync with the selected home view.
class HomeMenuButton extends StatelessWidget {
  const HomeMenuButton({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appdata.settings,
    builder: (context, _) => appdata.settings['homeView'] == 'cloud'
        ? IconButton(
            tooltip: 'Cloud Home Settings'.tl,
            icon: const Icon(Icons.cloud_outlined),
            onPressed: () => showCloudHomeSettings(context),
          )
        : const ReadingFavoritesMenuButton(),
  );
}
