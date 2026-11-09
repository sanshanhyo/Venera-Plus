import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/metadata/metadata.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/features/history/history_manager.dart';
import 'package:venera_plus/foundation/image_provider/base_image_provider.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  HistoryImageProvider(History history) : this._(history, history.cover);

  HistoryImageProvider._(this.history, this._cover)
    : _id = history.id,
      _type = history.type,
      _sourceKey = history.sourceKey,
      _key =
          'history:${history.type.value}:${history.id.length}:${history.id}:$_cover';

  final History history;
  final String _cover;
  final String _id;
  final ComicType _type;
  final String _sourceKey;
  final String _key;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = _cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(_id, _type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
      var comicSource = _type.comicSource ?? (throw "Comic source not found.");
      var comic = await comicSource.loadComicInfo!(_id);
      checkStop();
      url = MetadataStore.originalDetails(comic.data).cover;
      if (history.id == _id && history.type == _type) {
        history.cover = url;
        HistoryManager().addHistory(history);
      }
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      _sourceKey,
      _id,
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
        return progress.imageBytes!;
      }
    }
    checkStop();
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => _key;
}
