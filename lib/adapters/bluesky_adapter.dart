import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// Bluesky — tier 1, fully feasible.
///
/// AT Protocol, fully open and free. Public content (profiles, posts,
/// followers) is readable without login via the public AppView
/// (https://public.api.bsky.app); writes use an App Password, never the
/// account password. No approval, no paid tier. Reference clients:
/// the official social-app (open source), Graysky.
/// v0.1.0: stub — capabilities below are targets.
class BlueskyAdapter extends StubAdapter {
  const BlueskyAdapter();

  @override
  String get id => 'bluesky';

  @override
  String get displayName => 'Bluesky';

  @override
  PlatformStatus get status => PlatformStatus.planned;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.like,
        AdapterCapability.comment,
        AdapterCapability.repost,
        AdapterCapability.notifications,
        AdapterCapability.search,
      };

  @override
  String get note => 'Fully feasible — AT Protocol, free, public read.';
}
