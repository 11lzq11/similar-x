import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../adapters/bluesky_adapter.dart';
import '../adapters/mastodon_adapter.dart';
import '../adapters/reddit_adapter.dart';
import '../adapters/telegram/tdlib_client.dart';
import '../adapters/telegram_adapter.dart';
import '../adapters/threads_adapter.dart';
import '../adapters/webview_adapter.dart';
import '../adapters/youtube_adapter.dart';
import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';

/// Login for one platform.
///
/// Each adapter's login is different (see the adapter docs): Telegram
/// is phone + code + 2FA, Mastodon is instance + OAuth, Bluesky is
/// handle + App Password, YouTube/Reddit/Threads are user-provided
/// app credentials + OAuth. This screen dispatches to the right form
/// for the adapter. On success it pops with `true` so the caller
/// reloads; on failure it shows the error and stays put.
///
/// WebView platforms never come here — their login lives inside the
/// WebView (see [WebViewAdapter.openWebView]).
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key, required this.adapter});

  final PlatformAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PlatformAdapter a = adapter;
    final Widget body;
    if (a is TelegramAdapter) {
      body = _TelegramLoginForm(adapter: a);
    } else if (a is MastodonAdapter) {
      body = _MastodonLoginForm(adapter: a);
    } else if (a is BlueskyAdapter) {
      body = _BlueskyLoginForm(adapter: a);
    } else if (a is YouTubeAdapter) {
      body = _YouTubeLoginForm(adapter: a);
    } else if (a is RedditAdapter) {
      body = _RedditLoginForm(adapter: a);
    } else if (a is ThreadsAdapter) {
      body = _ThreadsLoginForm(adapter: a);
    } else {
      body = _GenericLoginForm(adapter: a);
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.loginTitleFor(a.displayName))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: body,
      ),
    );
  }
}

/// Pops with `true` after a short success message.
void _finish(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).loginSuccess)),
  );
  Navigator.of(context).pop(true);
}

/// Shows a login failure inline (SnackBar, no navigation).
void _showLoginError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        AppLocalizations.of(context).loginFailedWith(error.toString()),
      ),
    ),
  );
}

/// Opens a URL in the system browser; when that fails, copies it to
/// the clipboard instead so the user can paste it manually.
Future<void> _openUrl(BuildContext context, Uri url) async {
  final bool launched = await launchUrl(
    url,
    mode: LaunchMode.externalApplication,
  );
  if (!launched) {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).copied)),
    );
  }
}

/// The authorize step shared by the OAuth adapters (Mastodon,
/// YouTube, Reddit, Threads): show the authorize URL, open it in a
/// browser, and either wait for the loopback redirect to deliver the
/// code automatically ([waitForLoopback]) or take a manually pasted
/// code ([submitCode]).
///
/// On any failure the error is shown and [onRestart] is called so the
/// parent resets to the prerequisites step (a fresh login gets a
/// fresh verifier). On success [onDone] is called.
class _AuthorizeStep extends StatefulWidget {
  const _AuthorizeStep({
    required this.authorizeUrl,
    this.waitForLoopback,
    required this.submitCode,
    required this.onDone,
    required this.onRestart,
  });

  final Uri authorizeUrl;
  final Future<void> Function()? waitForLoopback;
  final Future<void> Function(String code) submitCode;
  final VoidCallback onDone;
  final VoidCallback onRestart;

  @override
  State<_AuthorizeStep> createState() => _AuthorizeStepState();
}

class _AuthorizeStepState extends State<_AuthorizeStep> {
  final TextEditingController _codeController = TextEditingController();
  bool _waiting = false;
  bool _busy = false;
  bool _manualUsed = false;

  @override
  void initState() {
    super.initState();
    if (widget.waitForLoopback != null) {
      _waiting = true;
      unawaited(_waitForLoopback());
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  /// The loopback wait: completes when the browser redirects back
  /// after approval. A failure here (denied, cancelled) resets the
  /// flow — unless the user already submitted a manual code, in
  /// which case the loopback was cancelled on purpose.
  Future<void> _waitForLoopback() async {
    try {
      await widget.waitForLoopback!();
      if (!mounted) return;
      widget.onDone();
    } catch (e) {
      if (!mounted || _manualUsed) return;
      _showLoginError(context, e);
      widget.onRestart();
    }
  }

  Future<void> _submitCode() async {
    final String code = _codeController.text.trim();
    if (code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _manualUsed = true;
      _waiting = false;
    });
    try {
      await widget.submitCode(code);
      if (!mounted) return;
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
      widget.onRestart();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.authorizeUrlLabel, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(widget.authorizeUrl.toString()),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => _openUrl(context, widget.authorizeUrl),
          icon: const Icon(Icons.open_in_browser),
          label: Text(l10n.openInBrowser),
        ),
        if (_waiting) ...<Widget>[
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(l10n.waitingApproval)),
            ],
          ),
        ],
        const SizedBox(height: 24),
        Text(l10n.pasteCode, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(l10n.manualCodeHint),
        const SizedBox(height: 8),
        TextField(
          controller: _codeController,
          decoration: InputDecoration(labelText: l10n.code),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitCode(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _submitCode,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.submit),
        ),
      ],
    );
  }
}

/// Mastodon: pick an instance, open the authorize URL, paste the code.
class _MastodonLoginForm extends StatefulWidget {
  const _MastodonLoginForm({required this.adapter});

  final MastodonAdapter adapter;

  @override
  State<_MastodonLoginForm> createState() => _MastodonLoginFormState();
}

class _MastodonLoginFormState extends State<_MastodonLoginForm> {
  final TextEditingController _instanceController = TextEditingController();
  Uri? _authorizeUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadInstance();
  }

  Future<void> _loadInstance() async {
    final String instance = await widget.adapter.instance;
    if (mounted) _instanceController.text = instance;
  }

  @override
  void dispose() {
    _instanceController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Uri url = await widget.adapter.beginLogin(
        instance: _instanceController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _authorizeUrl = url;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Uri? url = _authorizeUrl;
    if (url != null) {
      return _AuthorizeStep(
        authorizeUrl: url,
        submitCode: widget.adapter.submitAuthorizationCode,
        onDone: () => _finish(context),
        onRestart: () => setState(() => _authorizeUrl = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.mastodonInstanceHint),
        const SizedBox(height: 12),
        TextField(
          controller: _instanceController,
          decoration: InputDecoration(labelText: l10n.instance),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _begin(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _begin,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.login),
        ),
      ],
    );
  }
}

/// Bluesky: handle + App Password, no browser step.
class _BlueskyLoginForm extends StatefulWidget {
  const _BlueskyLoginForm({required this.adapter});

  final BlueskyAdapter adapter;

  @override
  State<_BlueskyLoginForm> createState() => _BlueskyLoginFormState();
}

class _BlueskyLoginFormState extends State<_BlueskyLoginForm> {
  final TextEditingController _handleController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _handleController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.loginWithAppPassword(
        handle: _handleController.text.trim(),
        appPassword: _passwordController.text.trim(),
      );
      if (!mounted) return;
      _finish(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.blueskyAppPasswordHint),
        const SizedBox(height: 12),
        TextField(
          controller: _handleController,
          decoration: InputDecoration(labelText: l10n.handle),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          decoration: InputDecoration(labelText: l10n.appPassword),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _login,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.login),
        ),
      ],
    );
  }
}

/// YouTube: API key + OAuth client ID, then Google OAuth.
class _YouTubeLoginForm extends StatefulWidget {
  const _YouTubeLoginForm({required this.adapter});

  final YouTubeAdapter adapter;

  @override
  State<_YouTubeLoginForm> createState() => _YouTubeLoginFormState();
}

class _YouTubeLoginFormState extends State<_YouTubeLoginForm> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _clientIdController = TextEditingController();
  Uri? _authorizeUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final String? apiKey = await widget.adapter.apiKey;
    final String? clientId = await widget.adapter.oauthClientId;
    if (!mounted) return;
    if (apiKey != null) _apiKeyController.text = apiKey;
    if (clientId != null) _clientIdController.text = clientId;
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _clientIdController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.setApiKey(_apiKeyController.text);
      await widget.adapter.setOAuthClientId(_clientIdController.text);
      final Uri url = await widget.adapter.beginOAuthLogin();
      if (!mounted) return;
      setState(() {
        _authorizeUrl = url;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Uri? url = _authorizeUrl;
    if (url != null) {
      return _AuthorizeStep(
        authorizeUrl: url,
        waitForLoopback: widget.adapter.completeOAuthLogin,
        submitCode: widget.adapter.completeOAuthLoginWithCode,
        onDone: () => _finish(context),
        onRestart: () => setState(() => _authorizeUrl = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.youtubeSetupHint),
        const SizedBox(height: 12),
        TextField(
          controller: _apiKeyController,
          decoration: InputDecoration(labelText: l10n.apiKey),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _clientIdController,
          decoration: InputDecoration(labelText: l10n.oauthClientId),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _begin(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _begin,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.login),
        ),
      ],
    );
  }
}

/// Reddit: installed-app client ID, then OAuth.
class _RedditLoginForm extends StatefulWidget {
  const _RedditLoginForm({required this.adapter});

  final RedditAdapter adapter;

  @override
  State<_RedditLoginForm> createState() => _RedditLoginFormState();
}

class _RedditLoginFormState extends State<_RedditLoginForm> {
  final TextEditingController _clientIdController = TextEditingController();
  Uri? _authorizeUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final String? clientId = await widget.adapter.clientId;
    if (mounted && clientId != null) _clientIdController.text = clientId;
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.setClientId(_clientIdController.text);
      final Uri url = await widget.adapter.beginOAuthLogin();
      if (!mounted) return;
      setState(() {
        _authorizeUrl = url;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Uri? url = _authorizeUrl;
    if (url != null) {
      return _AuthorizeStep(
        authorizeUrl: url,
        waitForLoopback: widget.adapter.completeOAuthLogin,
        submitCode: widget.adapter.completeOAuthLoginWithCode,
        onDone: () => _finish(context),
        onRestart: () => setState(() => _authorizeUrl = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.redditSetupHint),
        const SizedBox(height: 12),
        TextField(
          controller: _clientIdController,
          decoration: InputDecoration(labelText: l10n.clientId),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _begin(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _begin,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.login),
        ),
      ],
    );
  }
}

/// Threads: Meta app credentials, then OAuth.
class _ThreadsLoginForm extends StatefulWidget {
  const _ThreadsLoginForm({required this.adapter});

  final ThreadsAdapter adapter;

  @override
  State<_ThreadsLoginForm> createState() => _ThreadsLoginFormState();
}

class _ThreadsLoginFormState extends State<_ThreadsLoginForm> {
  final TextEditingController _appIdController = TextEditingController();
  final TextEditingController _appSecretController = TextEditingController();
  Uri? _authorizeUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final String? appId = await widget.adapter.appId;
    final String? appSecret = await widget.adapter.appSecret;
    if (!mounted) return;
    if (appId != null) _appIdController.text = appId;
    if (appSecret != null) _appSecretController.text = appSecret;
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _appSecretController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.setAppCredentials(
        appId: _appIdController.text,
        appSecret: _appSecretController.text,
      );
      final Uri url = await widget.adapter.beginOAuthLogin();
      if (!mounted) return;
      setState(() {
        _authorizeUrl = url;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Uri? url = _authorizeUrl;
    if (url != null) {
      return _AuthorizeStep(
        authorizeUrl: url,
        waitForLoopback: widget.adapter.completeOAuthLogin,
        submitCode: widget.adapter.completeOAuthLoginWithCode,
        onDone: () => _finish(context),
        onRestart: () => setState(() => _authorizeUrl = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.threadsSetupHint),
        const SizedBox(height: 12),
        TextField(
          controller: _appIdController,
          decoration: InputDecoration(labelText: l10n.appId),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _appSecretController,
          decoration: InputDecoration(labelText: l10n.appSecret),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _begin(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _begin,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.login),
        ),
      ],
    );
  }
}

/// Telegram: API credentials, then phone + code + 2FA, driven by the
/// TDLib authorization state machine.
class _TelegramLoginForm extends StatefulWidget {
  const _TelegramLoginForm({required this.adapter});

  final TelegramAdapter adapter;

  @override
  State<_TelegramLoginForm> createState() => _TelegramLoginFormState();
}

class _TelegramLoginFormState extends State<_TelegramLoginForm> {
  final TextEditingController _apiIdController = TextEditingController();
  final TextEditingController _apiHashController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  StreamSubscription<TdlibAuthState>? _authSubscription;

  /// false = credentials form, true = auth-state flow.
  bool _inAuthFlow = false;
  TdlibAuthState _authState = TdlibAuthState.unknown;
  bool _busy = false;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bool configured = await widget.adapter.credentialsConfigured;
    if (!mounted) return;
    if (configured) {
      setState(() => _inAuthFlow = true);
      await _startAuth();
    } else {
      setState(() => _starting = false);
    }
  }

  /// Initializes TDLib and drives the UI from the authorization
  /// state: the stream does not replay, so the current state is
  /// read once here and the stream is used for later transitions.
  Future<void> _startAuth() async {
    setState(() => _starting = true);
    try {
      await widget.adapter.login();
    } catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      _showLoginError(context, e);
      return;
    }
    if (!mounted) return;
    final bool loggedIn = await widget.adapter.isLoggedIn;
    if (!mounted) return;
    if (loggedIn) {
      _finish(context);
      return;
    }
    final TdlibAuthState current = widget.adapter.currentAuthState ??
        TdlibAuthState.waitPhoneNumber;
    setState(() {
      _authState = current;
      _starting = false;
    });
    await _authSubscription?.cancel();
    _authSubscription = widget.adapter.authState.listen(
      (TdlibAuthState state) {
        if (!mounted) return;
        if (state == TdlibAuthState.ready) {
          _finish(context);
          return;
        }
        setState(() => _authState = state);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _apiIdController.dispose();
    _apiHashController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _saveCredentials() async {
    if (_busy) return;
    final int? apiId = int.tryParse(_apiIdController.text.trim());
    if (apiId == null || _apiHashController.text.trim().isEmpty) {
      _showLoginError(
        context,
        'Enter a numeric api_id and a non-empty api_hash.',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.adapter.saveCredentials(
        apiId: apiId,
        apiHash: _apiHashController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _inAuthFlow = true;
        _busy = false;
      });
      await _startAuth();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  Future<void> _submitPhone() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.submitPhoneNumber(_phoneController.text.trim());
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  Future<void> _submitCode() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.submitCode(_codeController.text.trim());
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  Future<void> _submitPassword() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.submitPassword(_passwordController.text);
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (!_inAuthFlow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.telegramCredentialsHint),
          const SizedBox(height: 12),
          TextField(
            controller: _apiIdController,
            decoration: InputDecoration(labelText: l10n.apiId),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiHashController,
            decoration: InputDecoration(labelText: l10n.apiHash),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _saveCredentials,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.save),
          ),
        ],
      );
    }
    if (_starting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    switch (_authState) {
      case TdlibAuthState.waitPhoneNumber:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.telegramPhoneHint),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              decoration: InputDecoration(labelText: l10n.phoneNumber),
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitPhone(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submitPhone,
              child: Text(l10n.submit),
            ),
          ],
        );
      case TdlibAuthState.waitCode:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.telegramCodeHint),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: InputDecoration(labelText: l10n.code),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitCode(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submitCode,
              child: Text(l10n.submit),
            ),
          ],
        );
      case TdlibAuthState.waitPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.telegramPasswordHint),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(labelText: l10n.password),
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitPassword(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submitPassword,
              child: Text(l10n.submit),
            ),
          ],
        );
      case TdlibAuthState.waitRegistration:
        return const Text(
          'This phone number is not registered on Telegram yet — '
          'register it in the Telegram app first, then try again.',
        );
      case TdlibAuthState.waitOtherDeviceConfirmation:
        return const Text(
          'Confirm this login on another device where you are '
          'already logged in to Telegram.',
        );
      case TdlibAuthState.ready:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        );
      case TdlibAuthState.waitTdlibParameters:
      case TdlibAuthState.unknown:
      case TdlibAuthState.loggingOut:
      case TdlibAuthState.closing:
      case TdlibAuthState.closed:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        );
    }
  }
}

/// Fallback for adapter types without a dedicated form (used by
/// tests with fake adapters): just runs the adapter's own login().
class _GenericLoginForm extends StatefulWidget {
  const _GenericLoginForm({required this.adapter});

  final PlatformAdapter adapter;

  @override
  State<_GenericLoginForm> createState() => _GenericLoginFormState();
}

class _GenericLoginFormState extends State<_GenericLoginForm> {
  bool _busy = false;

  Future<void> _login() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.adapter.login();
      if (!mounted) return;
      _finish(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showLoginError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.adapter.note.isNotEmpty) Text(widget.adapter.note),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _login,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppLocalizations.of(context).login),
        ),
      ],
    );
  }
}
