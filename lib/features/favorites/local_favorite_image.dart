import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/image_provider/base_image_provider.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'local_favorite_image.dart' as image_provider;

class LocalFavoriteImageProvider
    extends BaseImageProvider<image_provider.LocalFavoriteImageProvider> {
  /// Image provider for normal image.
  const LocalFavoriteImageProvider(this.url, this.id, this.intKey);

  final String url;

  final String id;

  final int intKey;

  static void delete(String id, int intKey) {
    final identity = (id + intKey.toString()).hashCode.toString();
    final directory = Directory(FilePath.join(App.dataPath, 'favorite_cover'));
    if (!directory.existsSync()) return;
    for (final file in directory.listSync().whereType<File>()) {
      final name = file.name;
      if (name == identity || name.startsWith('$identity-')) {
        file.deleteSync();
      }
    }
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var sourceKey = ComicSource.fromIntKey(intKey)?.key;
    var fileName = '${(id + intKey.toString()).hashCode}-${url.hashCode}';
    var file = File(FilePath.join(App.dataPath, 'favorite_cover', fileName));
    if (await file.exists()) {
      return await file.readAsBytes();
    } else {
      await file.create(recursive: true);
    }
    checkStop();
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      sourceKey,
      null,
      BaseImageProvider.cancelSignalOf(checkStop),
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        var data = progress.imageBytes!;
        await file.writeAsBytes(data);
        return data;
      }
    }
    checkStop();
    throw "Error: Empty response body.";
  }

  @override
  Future<LocalFavoriteImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture(this);
  }

  @override
  String get key => '${id.length}:$id:$intKey:$url';
}
