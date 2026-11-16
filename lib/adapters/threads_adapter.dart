import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// Threads — tier 2, limited.
///
/// Official Threads API (since 2024-06) is free, but it can only read
/// and write the user's OWN account: posts, replies, reply management
/// and insights. There is no public timeline, no recommendations feed
/// and no reading other people's content. Keyword search is capped at
/// 500 calls/7 days. Production use needs Meta App Review and tokens
/// expire after 60 days. Best used as a publishing/management end,
/// not a reading end. v0.1.0: stub — capabilities below are targets.
class ThreadsAdapter extends StubAdapter {
  const ThreadsAdapter();

  @override
  String get id => 'threads';

  @override
  String get displayName => 'Threads';

  @override
  PlatformStatus get status => PlatformStatus.planned;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.post,
        AdapterCapability.comment,
        AdapterCapability.search,
      };

  @override
  String get note => 'Limited — own account only, no public timeline.';
}
