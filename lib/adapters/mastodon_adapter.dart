import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// Mastodon — tier 1, fully feasible.
///
/// Open federated network (ActivityPub). REST + Streaming API are fully
/// public: no app registration, no approval, no quota. One integration
/// covers Mastodon, Pleroma, GoToSocial, Friendica. Plain HTTPS + JSON,
/// Dart `http` is enough. Reference clients: Tusky, Pachli, Ice Cubes.
/// v0.1.0: stub — capabilities below are targets.
class MastodonAdapter extends StubAdapter {
  const MastodonAdapter();

  @override
  String get id => 'mastodon';

  @override
  String get displayName => 'Mastodon';

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
  String get note => 'Fully feasible — open API, free, no approval.';
}
