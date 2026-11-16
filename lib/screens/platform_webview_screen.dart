import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../adapters/webview/webview_session.dart';
import '../adapters/webview_adapter.dart';
import '../core/app_localizations.dart';

/// In-app WebView for one closed platform (X, Instagram, Facebook).
///
/// Shows the platform's official mobile website with navigation
/// controls and a login-state indicator. The login lives in the
/// WebView's cookies; Similar-X never sees a token. Timeline, likes
/// and comments happen through the website — there is no native feed
/// for these platforms, so the unified timeline cannot include them.
///
/// On platforms without a WebView implementation (Windows/Linux in
/// v0.1.0, and the test environment) the screen shows a fallback
/// message instead of crashing.
class PlatformWebViewScreen extends StatefulWidget {
  const PlatformWebViewScreen({super.key, required this.adapter});

  /// The platform this screen embeds.
  final WebViewAdapter adapter;

  @override
  State<PlatformWebViewScreen> createState() => _PlatformWebViewScreenState();
}

class _PlatformWebViewScreenState extends State<PlatformWebViewScreen> {
  WebViewController? _controller;
  bool _webViewUnavailable = false;
  WebViewLoginState _loginState = WebViewLoginState.unknown;
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initController());
  }

  /// Sets up the WebView controller. Any failure (no WebView on this
  /// platform, no platform implementation in tests) lands in the
  /// fallback UI instead of crashing the app.
  Future<void> _initController() async {
    try {
      final WebViewController controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageFinished: (String url) => _onUrlChanged(url),
          onUrlChange: (UrlChange change) {
            final String? url = change.url;
            if (url != null) _onUrlChanged(url);
          },
          onWebResourceError: (_) {
            // Page-level errors (blocked resource, offline) are the
            // website's problem; the WebView itself stays usable.
          },
        ),
      );
      await controller.loadRequest(widget.adapter.config.homeUrl);
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (_) {
      if (!mounted) return;
      setState(() => _webViewUnavailable = true);
    }
  }

  /// External links stay outside the app: only the platform's own
  /// hosts may load inside the WebView.
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final Uri? uri = Uri.tryParse(request.url);
    if (uri == null || !widget.adapter.config.isAllowedUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).webViewExternalBlocked,
            ),
          ),
        );
      }
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  /// Reads the login state from the current URL and records it on the
  /// adapter (a hint only — the session lives in the cookies).
  void _onUrlChanged(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    final WebViewLoginState state =
        widget.adapter.config.detectLoginState(uri);
    if (state == WebViewLoginState.loggedIn) {
      unawaited(widget.adapter.markLoggedIn());
    } else if (state == WebViewLoginState.guest) {
      unawaited(widget.adapter.markLoggedOut());
    }
    unawaited(_refreshNavState());
    if (mounted && state != _loginState) {
      setState(() => _loginState = state);
    }
  }

  Future<void> _refreshNavState() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      final bool back = await controller.canGoBack();
      final bool forward = await controller.canGoForward();
      if (mounted && (back != _canGoBack || forward != _canGoForward)) {
        setState(() {
          _canGoBack = back;
          _canGoForward = forward;
        });
      }
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> _goHome() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.loadRequest(widget.adapter.config.homeUrl);
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> _reload() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.reload();
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> _goBack() async {
    final WebViewController? controller = _controller;
    if (controller == null || !await _canGoBackSafely(controller)) return;
    try {
      await controller.goBack();
    } catch (_) {
      // Best effort only.
    }
  }

  Future<void> _goForward() async {
    final WebViewController? controller = _controller;
    if (controller == null || !await _canGoForwardSafely(controller)) {
      return;
    }
    try {
      await controller.goForward();
    } catch (_) {
      // Best effort only.
    }
  }

  Future<bool> _canGoBackSafely(WebViewController controller) async {
    try {
      return await controller.canGoBack();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _canGoForwardSafely(WebViewController controller) async {
    try {
      return await controller.canGoForward();
    } catch (_) {
      return false;
    }
  }

  /// Logs out: clears the WebView's cookies and reloads the platform
  /// as a guest.
  Future<void> _logout() async {
    await widget.adapter.logout();
    await _goHome();
    if (mounted) {
      setState(() => _loginState = WebViewLoginState.guest);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final WebViewAdapter adapter = widget.adapter;
    return Scaffold(
      appBar: AppBar(
        title: Text(adapter.displayName),
        actions: <Widget>[
          _LoginStateChip(state: _loginState),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.webViewLogout,
            onPressed: _logout,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.webViewReload,
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              l10n.webViewDisclaimerFor(adapter.displayName),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_webViewUnavailable)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.web_asset_off, size: 48),
                      const SizedBox(height: 16),
                      Text(
                        l10n.webViewNotAvailable,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_controller == null)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Expanded(child: WebViewWidget(controller: _controller!)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: l10n.webViewBack,
                  onPressed: _canGoBack ? _goBack : null,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: l10n.webViewForward,
                  onPressed: _canGoForward ? _goForward : null,
                ),
                IconButton(
                  icon: const Icon(Icons.home),
                  tooltip: adapter.displayName,
                  onPressed: _goHome,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: l10n.webViewReload,
                  onPressed: _reload,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginStateChip extends StatelessWidget {
  const _LoginStateChip({required this.state});

  final WebViewLoginState state;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final (String label, IconData icon) = switch (state) {
      WebViewLoginState.loggedIn => (l10n.webViewLoggedIn, Icons.check_circle),
      WebViewLoginState.guest => (l10n.webViewGuest, Icons.person_outline),
      WebViewLoginState.unknown => (l10n.webViewUnknown, Icons.help_outline),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Chip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}
