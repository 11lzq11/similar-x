import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// Telegram — tier 1, fully feasible.
///
/// Official MTProto API + TDLib, free, no approval, no quota. The only
/// platform that actively encourages third-party clients. Flutter route:
/// TDLib (C++) via Dart FFI; reference implementation: Mithka
/// (github.com/iebb/mithka). Needs an api_id/api_hash from
/// my.telegram.org. v0.1.0: stub — capabilities below are targets.
class TelegramAdapter extends StubAdapter {
  const TelegramAdapter();

  @override
  String get id => 'telegram';

  @override
  String get displayName => 'Telegram';

  @override
  PlatformStatus get status => PlatformStatus.planned;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.like,
        AdapterCapability.comment,
        AdapterCapability.directMessage,
        AdapterCapability.notifications,
        AdapterCapability.search,
      };

  @override
  String get note => 'Fully feasible — MTProto + TDLib, free, no approval.';
}
