import 'dart:convert';

enum MetadataProviderId { ehentai, jmcomic }

class MetadataReference {
  const MetadataReference({
    required this.provider,
    required this.id,
    required this.sourceUrl,
    this.token,
  });

  final MetadataProviderId provider;
  final String id;
  final String sourceUrl;
  final String? token;

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'id': id,
    'sourceUrl': sourceUrl,
    if (token != null) 'token': token,
  };

  factory MetadataReference.fromJson(Map<String, dynamic> json) =>
      MetadataReference(
        provider: MetadataProviderId.values.byName(json['provider'] as String),
        id: json['id'] as String,
        sourceUrl: json['sourceUrl'] as String,
        token: json['token'] as String?,
      );
}

class MetadataResult {
  MetadataResult({
    required this.reference,
    required this.title,
    List<String> authors = const [],
    Map<String, List<String>> tags = const {},
    this.description = '',
    this.coverUrl,
    this.pageCount,
    DateTime? fetchedAt,
  }) : authors = List.unmodifiable(authors),
       tags = Map.unmodifiable({
         for (final entry in tags.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       }),
       fetchedAt = fetchedAt ?? DateTime.now();

  final MetadataReference reference;
  final String title;
  final List<String> authors;
  final Map<String, List<String>> tags;
  final String description;
  final String? coverUrl;
  final int? pageCount;
  final DateTime fetchedAt;

  Map<String, dynamic> toJson() => {
    'reference': reference.toJson(),
    'title': title,
    'authors': authors,
    'tags': tags,
    'description': description,
    'coverUrl': coverUrl,
    'pageCount': pageCount,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
  };

  factory MetadataResult.fromJson(Map<String, dynamic> json) => MetadataResult(
    reference: MetadataReference.fromJson(
      Map<String, dynamic>.from(json['reference'] as Map),
    ),
    title: json['title'] as String,
    authors: List<String>.from(json['authors'] as List),
    tags: {
      for (final entry in (json['tags'] as Map).entries)
        entry.key as String: List<String>.from(entry.value as List),
    },
    description: json['description'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
    pageCount: json['pageCount'] as int?,
    fetchedAt: DateTime.parse(json['fetchedAt'] as String),
  );
}

abstract interface class MetadataGateway {
  MetadataReference parseReference(
    String input, {
    MetadataProviderId? provider,
  });

  Future<MetadataResult> fetch(MetadataReference reference);

  bool isAllowedCoverUri(MetadataProviderId provider, Uri uri);
}

class MetadataBinding {
  const MetadataBinding({
    required this.sourceKey,
    required this.comicId,
    required this.result,
    required this.cacheCover,
    required this.updatedAt,
    this.coverPath,
  });

  final String sourceKey;
  final String comicId;
  final MetadataResult result;

  /// The requested policy. [coverPath] is non-null only after a successful save.
  final bool cacheCover;
  final String? coverPath;
  final DateTime updatedAt;

  String get identity => jsonEncode([sourceKey, comicId]);
}

class MetadataSaveResult {
  const MetadataSaveResult({required this.binding, this.coverError});

  final MetadataBinding binding;
  final String? coverError;
}
