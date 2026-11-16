import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// YouTube — tier 2, limited.
///
/// Data API v3 is free but quota-tight: 10,000 units/day by default and
/// `search.list` costs 100 units per call (~100 searches/day). Plan:
/// official API for metadata, subscriptions and comments; InnerTube
/// (unofficial) as the playback/search fallback. The official API never
/// serves video streams — playback needs InnerTube or the official
/// IFrame player in a WebView. Reference: NewPipe, LibreTube.
/// v0.1.0: stub — capabilities below are targets.
class YouTubeAdapter extends StubAdapter {
  const YouTubeAdapter();

  @override
  String get id => 'youtube';

  @override
  String get displayName => 'YouTube';

  @override
  PlatformStatus get status => PlatformStatus.planned;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.comment,
        AdapterCapability.search,
        AdapterCapability.notifications,
      };

  @override
  String get note => 'Limited — Data API quota 10k units/day; search is scarce.';
}
