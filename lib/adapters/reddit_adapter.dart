import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// Reddit — tier 2, limited.
///
/// Data API free tier: 100 calls/minute via OAuth, non-commercial use
/// only. Since late 2025 every new app (including free personal ones)
/// needs manual approval, typically 2–4 weeks. Commercial use is
/// $0.24/1,000 calls. Realistic model: each user logs in with their
/// own Reddit account (per-user OAuth), so quota and cost stay with
/// the user, not the app. Reference: RedReader.
/// v0.1.0: stub — capabilities below are targets.
class RedditAdapter extends StubAdapter {
  const RedditAdapter();

  @override
  String get id => 'reddit';

  @override
  String get displayName => 'Reddit';

  @override
  PlatformStatus get status => PlatformStatus.planned;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.like,
        AdapterCapability.comment,
        AdapterCapability.search,
        AdapterCapability.notifications,
      };

  @override
  String get note => 'Limited — free tier needs manual approval first.';
}
