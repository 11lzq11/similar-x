import '../core/platform_adapter.dart';

/// Shared stub behaviour for v0.1.0 adapters.
///
/// Every adapter starts as a stub: it declares its id, name, status,
/// capabilities and feasibility note, and returns empty timelines until
/// its real API client lands. Subclasses only fill in the metadata.
abstract class StubAdapter extends PlatformAdapter {
  const StubAdapter();

  @override
  Future<bool> get isLoggedIn async => false;

  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async => const <Post>[];

  @override
  Future<void> login() async {}

  @override
  Future<void> logout() async {}
}
