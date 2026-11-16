/// Threads API client: plain HTTPS + JSON over
/// `package:http`.
///
/// Auth is per-user, from the user's own Meta app — Similar-X
/// ships no shared app ID, so one user's quota can never eat
/// another's:
///
/// 1. developers.facebook.com/apps > create app > use case
///    **Access the Threads API**. Copy the **Threads App ID**
///    (not the parent Meta App ID) and the **Threads App
///    Secret** (App settings > Basic) and paste them in
///    Similar-X. Add `http://127.0.0.1` as a redirect URI in
///    the app settings (the login uses a loopback listener on
///    an ephemeral port; the code can also be pasted manually).
/// 2. Login uses OAuth 2.0: authorize on threads.net, then the
///    code is exchanged for a short-lived token (1 hour), which
///    is immediately exchanged for a long-lived token (60
///    days). The long-lived token is stored encrypted
///    on-device. It is refreshed (once, on a 401) with the
///    current token — refresh only works while the token is
///    still valid, so a fully expired or revoked token means
///    logging in again.
/// 3. **Production use needs Meta App Review** for the
///    Threads use case. Before review, only the app's testers
///    can log in, and keyword search / mentions only cover the
///    app's own testers.
///
/// What the API can and cannot do (official API only):
///
/// * Own account only: own threads, replies to them,
///   mentions, keyword search, insights. There is **no public
///   timeline, no home feed, no way to read other people's
///   content** — Meta's own docs say apps may display posts
///   solely to the person who created them.
/// * Publish: text (<=500 chars), image, video, carousel
///   (2-20 items) via the two-step container + publish flow;
///   replies (`reply_to_id`, always the root post's id);
///   quotes (`quote_post_id`); reposts
///   (`POST /{media-id}/repost`, no container).
/// * Limits: 250 posts / 1,000 replies / 100 deletions per
///   account per 24 hours; keyword search 500 requests per
///   rolling 7 days (and before App Review it only searches
///   the account's own posts).
/// * **Liking has no endpoint in the official API** — the
///   like/unlike calls in some third-party libraries use
///   Threads' internal (unofficial) API, not this one. This
///   client does not fake it: like counts are readable
///   through insights, but there is no like action. The
///   adapter says so in its note.
///
/// Reference: developers.facebook.com/docs/threads.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'threads_models.dart';

/// Thrown when a Threads API call fails: missing app
/// credentials, wrong credentials, unapproved app, rate
/// limit, network error, or a non-2xx response. [statusCode]
/// is the HTTP status when the server answered, null when the
/// request never reached it.
class ThreadsApiException implements Exception {
  const ThreadsApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ThreadsApiException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// The Threads API host (v1.0).
const String threadsApiHost = 'graph.threads.net';

/// The OAuth authorize host.
const String threadsAuthHost = 'www.threads.net';

/// The OAuth scopes Similar-X asks for: basic profile + own
/// threads, publishing, reading replies, managing replies,
/// insights, mentions, keyword search and deleting. The
/// smallest set that covers the adapter's capabilities.
/// `threads_profile_discovery` and `threads_location_tagging`
/// are not requested — Similar-X does not use them.
const String threadsOAuthScope =
    'threads_basic,threads_content_publish,threads_read_replies,'
    'threads_manage_replies,threads_manage_insights,'
    'threads_manage_mentions,threads_keyword_search,threads_delete';

/// A text post may be at most 500 characters.
const int threadsTextMaxLength = 500;

/// Daily publishing limits per account (rolling 24 hours).
const int threadsPostsPerDay = 250;
const int threadsRepliesPerDay = 1000;
const int threadsDeletesPerDay = 100;

/// Keyword search: 500 requests per rolling 7 days.
const int threadsKeywordSearchPerWeek = 500;

/// A carousel holds 2-20 items.
const int threadsCarouselMinItems = 2;
const int threadsCarouselMaxItems = 20;

/// The long-lived token lives 60 days.
const int threadsLongLivedTokenDays = 60;

/// Media fields requested for a post. Only fields the API
/// documents — requesting a field that does not exist fails
/// the whole call, so engagement counts (which the media
/// object does not reliably carry) are read through the
/// insights endpoints instead.
const String threadsPostFields =
    'id,media_product_type,media_type,media_url,permalink,owner,'
    'username,text,timestamp,shortcode,thumbnail_url,children,'
    'link_attachment,is_quote_post,quoted_post,has_replies,'
    'is_reply,hide_status,is_verified';

/// Reply fields requested for replies and mentions.
const String threadsReplyFields =
    'id,text,username,permalink,timestamp,media_type,media_url,'
    'has_replies,hide_status,is_verified,profile_picture_url';

/// Profile fields requested for /me.
const String threadsUserFields =
    'id,username,name,threads_profile_picture_url,threads_biography';

/// Insight metrics for a post.
const String threadsPostInsightMetrics =
    'views,likes,replies,reposts,quotes';

/// Insight metrics for the account.
const String threadsAccountInsightMetrics =
    'views,likes,replies,reposts,quotes,followers_count';

/// A loopback listener for the OAuth redirect: binds 127.0.0.1
/// on an ephemeral port, waits for threads.net to redirect the
/// browser to `http://127.0.0.1:<port>/?code=...`, captures
/// the code, answers with a small success page and shuts down.
/// [cancel] closes the server without a code (the user closed
/// the browser).
class ThreadsLoopbackAuthListener {
  ThreadsLoopbackAuthListener._(this._server, this._completer);

  static Future<ThreadsLoopbackAuthListener> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<String> completer = Completer<String>();
    final ThreadsLoopbackAuthListener listener =
        ThreadsLoopbackAuthListener._(server, completer);
    // A silent error handler: cancelling a login nobody is
    // awaiting must not surface as an unhandled async error.
    // Awaiting [code] elsewhere still receives the error.
    unawaited(completer.future.catchError((Object _) => ''));
    server.listen((HttpRequest request) async {
      final String? code = request.uri.queryParameters['code'];
      final String? state = request.uri.queryParameters['state'];
      final String? error = request.uri.queryParameters['error'];
      request.response.headers.contentType = ContentType.html;
      if (code != null && code.isNotEmpty) {
        request.response.write(
          '<html><body><h1>Similar-X</h1>'
          '<p>Threads login complete — you can close this tab and '
          'return to Similar-X.</p></body></html>',
        );
        await request.response.close();
        await server.close(force: true);
        if (!completer.isCompleted) {
          listener._state = state;
          completer.complete(code);
        }
      } else {
        request.response.write(
          '<html><body><h1>Similar-X</h1>'
          '<p>Threads login failed'
          '${error == null ? '' : ': $error'}. '
          'You can close this tab and try again in Similar-X.'
          '</p></body></html>',
        );
        await request.response.close();
        await server.close(force: true);
        if (!completer.isCompleted) {
          completer.completeError(
            ThreadsApiException(
              'Login failed: Threads returned '
              '${error ?? 'an unknown error'}.',
            ),
          );
        }
      }
    });
    return listener;
  }

  final HttpServer _server;
  final Completer<String> _completer;
  String? _state;

  /// The redirect URI the Meta app must have registered.
  /// Register `http://127.0.0.1` as a redirect URI in the
  /// app settings; the port is ephemeral and the listener
  /// reports it here.
  String get redirectUri => 'http://127.0.0.1:${_server.port}';

  /// Completes with the authorization code when Threads
  /// redirects here, or with a [ThreadsApiException] on
  /// error/cancel.
  Future<String> get code => _completer.future;

  /// The `state` value Threads echoed back with the code, or
  /// null when the redirect carried none. The adapter compares
  /// it with the state it sent, to prove the redirect belongs
  /// to this login attempt.
  String? get state => _state;

  /// Closes the listener without a code (user gave up). The
  /// pending [code] future completes with an error.
  Future<void> cancel() async {
    await _server.close(force: true);
    if (!_completer.isCompleted) {
      _completer.completeError(
        const ThreadsApiException('Login cancelled.'),
      );
    }
  }
}

/// One Threads account's API client.
///
/// The client holds no credential by itself: [appId] /
/// [appSecret] / [accessToken] are set by the adapter after
/// the user enters them and cleared on logout. Every call
/// needs a user token — there is no guest mode, because the
/// official API exposes nothing without one.
class ThreadsClient {
  ThreadsClient({
    this.appId,
    this.appSecret,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// The user's Threads App ID (Meta app > Threads use case).
  /// Not the parent Meta App ID.
  String? appId;

  /// The user's Threads App Secret (App settings > Basic).
  /// Needed for the token exchange.
  String? appSecret;

  /// The long-lived OAuth access token (60 days). Set after
  /// login; cleared on logout.
  String? accessToken;

  /// The Threads user id the token belongs to. Set after
  /// login; cleared on logout.
  String? userId;

  /// Called after an access-token refresh so the adapter can
  /// persist the new token. Null in tests that do not care
  /// about persistence.
  Future<void> Function(ThreadsTokens tokens)? onTokensRefreshed;

  final http.Client _http;

  /// The URL the user opens in a browser to authorize
  /// Similar-X. Threads redirects to [redirectUri] with
  /// `?code=...` after approval; the adapter captures it with
  /// a [ThreadsLoopbackAuthListener].
  Uri buildAuthorizeUrl({
    required String appId,
    required String redirectUri,
    required String state,
  }) =>
      Uri.https(threadsAuthHost, '/oauth/authorize', <String, String>{
        'client_id': appId,
        'redirect_uri': redirectUri,
        'scope': threadsOAuthScope,
        'response_type': 'code',
        'state': state,
      });

  /// Exchanges the authorization code for a short-lived token
  /// (1 hour). Throws when Threads rejects the code — for
  /// example when the redirect URI is not registered in the
  /// Meta app, or the app has not passed App Review and the
  /// account is not a tester.
  Future<ThreadsTokens> exchangeCode({
    required String code,
    required String appId,
    required String appSecret,
    required String redirectUri,
  }) async {
    final http.Response response = await _postForm(
      Uri.https(threadsApiHost, '/oauth/access_token'),
      body: <String, String>{
        'client_id': appId,
        'client_secret': appSecret,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri,
        'code': code,
      },
    );
    final ThreadsTokens tokens = ThreadsTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const ThreadsApiException(
        'Token exchange failed: no access token returned.',
      );
    }
    accessToken = tokens.accessToken;
    if (tokens.userId.isNotEmpty) userId = tokens.userId;
    return tokens;
  }

  /// Exchanges a short-lived token for a long-lived one (60
  /// days). Call right after [exchangeCode].
  Future<ThreadsTokens> exchangeLongLived({
    required String appSecret,
    required String shortLivedToken,
  }) async {
    final http.Response response = await _getRaw(
      Uri.https(threadsApiHost, '/access_token', <String, String>{
        'grant_type': 'th_exchange_token',
        'client_secret': appSecret,
        'access_token': shortLivedToken,
      }),
      const <String, String>{},
    );
    final ThreadsTokens tokens = ThreadsTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const ThreadsApiException(
        'Long-lived token exchange failed: no access token '
        'returned.',
      );
    }
    accessToken = tokens.accessToken;
    if (tokens.userId.isNotEmpty) userId = tokens.userId;
    return tokens;
  }

  /// Refreshes the long-lived token with the current one and
  /// applies the new token. Only works while the current
  /// token is still valid — an expired or revoked token throws
  /// and the user has to log in again.
  Future<ThreadsTokens> refreshAccessToken() async {
    final String? current = accessToken;
    if (current == null || current.isEmpty) {
      throw const ThreadsApiException(
        'Session expired: log in again.',
      );
    }
    final http.Response response = await _getRaw(
      Uri.https(
        threadsApiHost,
        '/refresh_access_token',
        <String, String>{
          'grant_type': 'th_refresh_token',
          'access_token': current,
        },
      ),
      const <String, String>{},
    );
    final ThreadsTokens tokens = ThreadsTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const ThreadsApiException(
        'Session refresh failed: log in again.',
      );
    }
    accessToken = tokens.accessToken;
    if (tokens.userId.isNotEmpty) userId = tokens.userId;
    await onTokensRefreshed?.call(tokens);
    return tokens;
  }

  /// The logged-in user's profile. OAuth only.
  Future<ThreadsUser> getMe() async {
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/me', <String, String>{
        'fields': threadsUserFields,
      }),
    );
    return ThreadsUser.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// The account's own threads, newest first. This is the
  /// closest thing the API has to a timeline — it only ever
  /// contains the account's own posts.
  Future<List<ThreadsPost>> listMyThreads({int limit = 25}) async {
    final String uid = _requireUserId();
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$uid/threads',
          <String, String>{
            'fields': threadsPostFields,
            'limit': limit.toString(),
          }),
    );
    return _decodePosts(response);
  }

  /// One post by media id.
  Future<ThreadsPost> getThread(String mediaId) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$mediaId', <String, String>{
        'fields': threadsPostFields,
      }),
    );
    final ThreadsPost post = ThreadsPost.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!post.isValid) {
      throw const ThreadsApiException(
        'Threads returned no post for that id.',
      );
    }
    return post;
  }

  /// Top-level replies to a post, newest first by default
  /// ([reverse] flips to oldest first).
  Future<List<ThreadsPost>> listReplies(
    String mediaId, {
    int limit = 25,
    bool reverse = true,
  }) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(
        threadsApiHost,
        '/v1.0/$mediaId/replies',
        <String, String>{
          'fields': threadsReplyFields,
          'limit': limit.toString(),
          'reverse': reverse.toString(),
        },
      ),
    );
    return _decodePosts(response);
  }

  /// The full conversation tree under a post.
  Future<List<ThreadsPost>> listConversation(
    String mediaId, {
    int limit = 25,
  }) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(
        threadsApiHost,
        '/v1.0/$mediaId/conversation',
        <String, String>{
          'fields': threadsReplyFields,
          'limit': limit.toString(),
        },
      ),
    );
    return _decodePosts(response);
  }

  /// Posts that mention the account, newest first. Needs the
  /// `threads_manage_mentions` scope; before App Review it
  /// only covers the app's own testers.
  Future<List<ThreadsPost>> listMentions({int limit = 25}) async {
    final String uid = _requireUserId();
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$uid/mentions',
          <String, String>{
            'fields': threadsReplyFields,
            'limit': limit.toString(),
          }),
    );
    return _decodePosts(response);
  }

  /// Searches public posts by keyword or topic tag. 500
  /// requests per rolling 7 days; before App Review (without
  /// the `threads_keyword_search` permission) it only searches
  /// the account's own posts. [searchType] is `TOP` (most
  /// relevant) or `RECENT` (newest first).
  Future<List<ThreadsPost>> searchKeyword(
    String query, {
    String searchType = 'TOP',
    int limit = 25,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) {
      throw const ThreadsApiException(
        'Search query must not be empty.',
      );
    }
    if (searchType != 'TOP' && searchType != 'RECENT') {
      throw ThreadsApiException(
        'Invalid search type: "$searchType".',
      );
    }
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/keyword_search',
          <String, String>{
            'q': q,
            'search_type': searchType,
            'limit': limit.toString(),
          }),
    );
    return _decodePosts(response);
  }

  /// Creates a media container for a text post. Returns the
  /// creation id — publish it with [publishContainer].
  /// [replyToId] must be the **root** post's id (every reply
  /// in a thread targets the root, not the previous reply).
  /// [quotePostId] makes this post a quote of that post.
  Future<String> createTextContainer({
    required String text,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final String body = text.trim();
    if (body.isEmpty) {
      throw const ThreadsApiException('Post text must not be empty.');
    }
    if (body.length > threadsTextMaxLength) {
      throw ThreadsApiException(
        'Post text is ${body.length} characters — Threads allows '
        'at most $threadsTextMaxLength.',
      );
    }
    final String uid = _requireUserId();
    final Map<String, String> fields = <String, String>{
      'media_type': 'TEXT',
      'text': body,
    };
    if (replyToId != null && replyToId.isNotEmpty) {
      fields['reply_to_id'] = replyToId;
    }
    if (quotePostId != null && quotePostId.isNotEmpty) {
      fields['quote_post_id'] = quotePostId;
    }
    if (topicTag != null && topicTag.isNotEmpty) {
      fields['topic_tag'] = topicTag;
    }
    return _createContainer(uid, fields);
  }

  /// Creates a media container for a single image post.
  /// [imageUrl] must be publicly reachable — Threads fetches
  /// the image from the URL; there is no direct upload.
  Future<String> createImageContainer({
    required String text,
    required String imageUrl,
    String? altText,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    _checkText(text);
    if (imageUrl.trim().isEmpty) {
      throw const ThreadsApiException('Image posts need an image URL.');
    }
    final String uid = _requireUserId();
    final Map<String, String> fields = <String, String>{
      'media_type': 'IMAGE',
      'text': text.trim(),
      'image_url': imageUrl.trim(),
    };
    if (altText != null && altText.isNotEmpty) {
      fields['alt_text'] = altText;
    }
    if (replyToId != null && replyToId.isNotEmpty) {
      fields['reply_to_id'] = replyToId;
    }
    if (quotePostId != null && quotePostId.isNotEmpty) {
      fields['quote_post_id'] = quotePostId;
    }
    if (topicTag != null && topicTag.isNotEmpty) {
      fields['topic_tag'] = topicTag;
    }
    return _createContainer(uid, fields);
  }

  /// Creates a media container for a single video post.
  /// [videoUrl] must be publicly reachable. Video containers
  /// process asynchronously — poll [getContainerStatus] until
  /// it reports `FINISHED` before publishing.
  Future<String> createVideoContainer({
    required String text,
    required String videoUrl,
    String? altText,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    _checkText(text);
    if (videoUrl.trim().isEmpty) {
      throw const ThreadsApiException('Video posts need a video URL.');
    }
    final String uid = _requireUserId();
    final Map<String, String> fields = <String, String>{
      'media_type': 'VIDEO',
      'text': text.trim(),
      'video_url': videoUrl.trim(),
    };
    if (altText != null && altText.isNotEmpty) {
      fields['alt_text'] = altText;
    }
    if (replyToId != null && replyToId.isNotEmpty) {
      fields['reply_to_id'] = replyToId;
    }
    if (quotePostId != null && quotePostId.isNotEmpty) {
      fields['quote_post_id'] = quotePostId;
    }
    if (topicTag != null && topicTag.isNotEmpty) {
      fields['topic_tag'] = topicTag;
    }
    return _createContainer(uid, fields);
  }

  /// Creates a media container for a carousel (2-20 images).
  /// Each item is `{'image_url': ..., 'alt_text': ...}`.
  Future<String> createCarouselContainer({
    required String text,
    required List<Map<String, String>> items,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    _checkText(text);
    if (items.length < threadsCarouselMinItems ||
        items.length > threadsCarouselMaxItems) {
      throw ThreadsApiException(
        'A carousel needs $threadsCarouselMinItems-'
        '$threadsCarouselMaxItems images.',
      );
    }
    for (final Map<String, String> item in items) {
      final String? url = item['image_url'];
      if (url == null || url.trim().isEmpty) {
        throw const ThreadsApiException(
          'Every carousel item needs an image URL.',
        );
      }
    }
    final String uid = _requireUserId();
    final Map<String, String> fields = <String, String>{
      'media_type': 'CAROUSEL',
      'text': text.trim(),
      'children': json.encode(items),
    };
    if (replyToId != null && replyToId.isNotEmpty) {
      fields['reply_to_id'] = replyToId;
    }
    if (quotePostId != null && quotePostId.isNotEmpty) {
      fields['quote_post_id'] = quotePostId;
    }
    if (topicTag != null && topicTag.isNotEmpty) {
      fields['topic_tag'] = topicTag;
    }
    return _createContainer(uid, fields);
  }

  Future<String> _createContainer(
    String userId,
    Map<String, String> fields,
  ) async {
    final http.Response response = await _postAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$userId/threads'),
      body: fields,
    );
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? id = decoded['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    throw const ThreadsApiException(
      'Container creation failed: Threads returned no id.',
    );
  }

  /// The processing status of a media container: `FINISHED`,
  /// `IN_PROGRESS`, `ERROR` or `EXPIRED`. Video containers
  /// must read `FINISHED` before publishing.
  Future<String> getContainerStatus(String creationId) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$creationId', <String, String>{
        'fields': 'status',
      }),
    );
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? status = decoded['status'];
      if (status is String && status.isNotEmpty) return status;
    }
    throw const ThreadsApiException(
      'Container status check failed: Threads returned no status.',
    );
  }

  /// Waits until a container reports `FINISHED`, polling every
  /// 5 seconds. Throws on `ERROR`/`EXPIRED` or when
  /// [timeout] runs out.
  Future<void> waitForContainerReady(
    String creationId, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (true) {
      final String status = await getContainerStatus(creationId);
      if (status == 'FINISHED') return;
      if (status == 'ERROR' || status == 'EXPIRED') {
        throw ThreadsApiException(
          'Media container failed with status $status.',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const ThreadsApiException(
          'Media container did not finish processing in time.',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  /// Publishes a finished container. Returns the published
  /// post's media id.
  Future<String> publishContainer(String creationId) async {
    final String uid = _requireUserId();
    final http.Response response = await _postAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$uid/threads_publish'),
      body: <String, String>{'creation_id': creationId},
    );
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? id = decoded['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    throw const ThreadsApiException(
      'Publish failed: Threads returned no post id.',
    );
  }

  /// Posts a text thread (container + publish in one call).
  /// Returns the published post's media id.
  Future<String> postText(
    String text, {
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final String creationId = await createTextContainer(
      text: text,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
    return publishContainer(creationId);
  }

  /// Posts a single-image thread (container + publish).
  Future<String> postImage(
    String text, {
    required String imageUrl,
    String? altText,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final String creationId = await createImageContainer(
      text: text,
      imageUrl: imageUrl,
      altText: altText,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
    return publishContainer(creationId);
  }

  /// Posts a single-video thread: creates the container, waits
  /// for processing to finish, then publishes.
  Future<String> postVideo(
    String text, {
    required String videoUrl,
    String? altText,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final String creationId = await createVideoContainer(
      text: text,
      videoUrl: videoUrl,
      altText: altText,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
    await waitForContainerReady(creationId);
    return publishContainer(creationId);
  }

  /// Reposts a post. No container — the repost fires directly
  /// and lands under the profile's Reposts tab (its
  /// `media_product_type` is `REPOST_FACADE`). Returns the
  /// repost's id.
  Future<String> repost(String mediaId) async {
    final http.Response response = await _postAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$mediaId/repost'),
      body: const <String, String>{},
    );
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? id = decoded['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    throw const ThreadsApiException(
      'Repost failed: Threads returned no id.',
    );
  }

  /// Hides a reply to one of the account's posts. Needs the
  /// `threads_manage_replies` scope.
  Future<void> hideReply(String mediaId) async {
    await _postAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$mediaId/hide'),
      body: const <String, String>{},
    );
  }

  /// Unhides a reply hidden with [hideReply].
  Future<void> unhideReply(String mediaId) async {
    await _postAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$mediaId/unhide'),
      body: const <String, String>{},
    );
  }

  /// Deletes one of the account's posts (100 per 24 hours).
  /// Needs the `threads_delete` scope.
  Future<void> deleteThread(String mediaId) async {
    final http.Response response = await _deleteAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$mediaId'),
    );
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? success = decoded['success'];
      if (success == true) return;
    }
    throw const ThreadsApiException(
      'Delete failed: Threads returned no success flag.',
    );
  }

  /// Insights for one of the account's posts: views, likes,
  /// replies, reposts and quotes. Needs the
  /// `threads_manage_insights` scope.
  Future<ThreadsInsights> getThreadInsights(
    String mediaId, {
    String metrics = threadsPostInsightMetrics,
  }) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(threadsApiHost, '/v1.0/$mediaId/insights',
          <String, String>{'metric': metrics}),
    );
    return ThreadsInsights.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Insights for the account: views, likes, replies,
  /// reposts, quotes and follower count. Needs the
  /// `threads_manage_insights` scope. [since] and [until]
  /// are Unix timestamps bounding the period.
  Future<ThreadsInsights> getAccountInsights({
    String metrics = threadsAccountInsightMetrics,
    int? since,
    int? until,
  }) async {
    final String uid = _requireUserId();
    final Map<String, String> params = <String, String>{
      'metric': metrics,
    };
    if (since != null) params['since'] = since.toString();
    if (until != null) params['until'] = until.toString();
    final http.Response response = await _getAuthenticated(
      Uri.https(
        threadsApiHost,
        '/v1.0/$uid/threads_insights',
        params,
      ),
    );
    return ThreadsInsights.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// The publishing quota: how many of the 250 posts and
  /// 1,000 replies per 24 hours the account has used.
  Future<ThreadsPublishingLimit> getPublishingLimit() async {
    final http.Response response = await _getAuthenticated(
      Uri.https(
        threadsApiHost,
        '/v1.0/threads_publishing_limit',
        <String, String>{'fields': 'quota_usage,reply_quota_usage,config'},
      ),
    );
    return ThreadsPublishingLimit.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  void _checkText(String text) {
    final String body = text.trim();
    if (body.isEmpty) {
      throw const ThreadsApiException('Post text must not be empty.');
    }
    if (body.length > threadsTextMaxLength) {
      throw ThreadsApiException(
        'Post text is ${body.length} characters — Threads allows '
        'at most $threadsTextMaxLength.',
      );
    }
  }

  String _requireUserId() {
    final String? uid = userId;
    if (uid == null || uid.isEmpty) {
      throw const ThreadsApiException(
        'No Threads user id known: log in first.',
      );
    }
    return uid;
  }

  void _requireAccessToken() {
    final String? token = accessToken;
    if (token == null || token.isEmpty) {
      throw const ThreadsApiException(
        'Log in to Threads first (OAuth).',
      );
    }
  }

  /// An OAuth-authenticated GET: on a 401 the access token is
  /// refreshed once and the request retried.
  Future<http.Response> _getAuthenticated(Uri uri) async {
    _requireAccessToken();
    http.Response response = await _getRaw(uri, _bearerHeaders());
    if (response.statusCode == 401) {
      await _refreshOnce();
      response = await _getRaw(uri, _bearerHeaders());
    }
    return _check(response);
  }

  /// An OAuth-authenticated POST (form-encoded, like Threads
  /// expects): on a 401 the access token is refreshed once and
  /// the request retried.
  Future<http.Response> _postAuthenticated(
    Uri uri, {
    required Map<String, String> body,
  }) async {
    _requireAccessToken();
    http.Response response = await _sendAuthenticated(uri, body);
    if (response.statusCode == 401) {
      await _refreshOnce();
      response = await _sendAuthenticated(uri, body);
    }
    return _check(response);
  }

  /// An OAuth-authenticated DELETE: on a 401 the access token
  /// is refreshed once and the request retried.
  Future<http.Response> _deleteAuthenticated(Uri uri) async {
    _requireAccessToken();
    http.Response response = await _deleteRaw(uri);
    if (response.statusCode == 401) {
      await _refreshOnce();
      response = await _deleteRaw(uri);
    }
    return _check(response);
  }

  Future<http.Response> _getRaw(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      return await _http.get(uri, headers: headers);
    } catch (e) {
      throw ThreadsApiException('Network error: $e');
    }
  }

  Future<http.Response> _sendAuthenticated(
    Uri uri,
    Map<String, String> body,
  ) async {
    try {
      return await _http.post(uri, headers: _bearerHeaders(), body: body);
    } catch (e) {
      throw ThreadsApiException('Network error: $e');
    }
  }

  Future<http.Response> _deleteRaw(Uri uri) async {
    try {
      return await _http.delete(uri, headers: _bearerHeaders());
    } catch (e) {
      throw ThreadsApiException('Network error: $e');
    }
  }

  /// A form-encoded POST without a bearer token (the OAuth
  /// token exchange). No refresh retry — a failure here means
  /// the code or the app credentials are wrong.
  Future<http.Response> _postForm(
    Uri uri, {
    required Map<String, String> body,
  }) async {
    try {
      final http.Response response = await _http.post(uri, body: body);
      return _check(response);
    } catch (e) {
      if (e is ThreadsApiException) rethrow;
      throw ThreadsApiException('Network error: $e');
    }
  }

  Map<String, String> _bearerHeaders() {
    final String? token = accessToken;
    return <String, String>{
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  /// Refreshes the access token once. Throws when the token
  /// is expired or revoked — the user has to log in again.
  Future<void> _refreshOnce() async {
    await refreshAccessToken();
  }

  http.Response _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw _errorFrom(response);
  }

  ThreadsApiException _errorFrom(http.Response response) {
    String message =
        'Threads API error (HTTP ${response.statusCode}).';
    if (response.statusCode == 401) {
      message =
          'Threads rejected the request (HTTP 401). The token may '
          'be expired or revoked — or the Meta app may still be '
          'waiting for App Review.';
    } else if (response.statusCode == 403) {
      message =
          'Threads refused the request (HTTP 403). The app may '
          'lack App Review approval for the permission this call '
          'needs, or the account may not have access to this '
          'content.';
    } else if (response.statusCode == 429) {
      message =
          'Threads rate limit hit (HTTP 429). The publishing '
          'limits are 250 posts and 1,000 replies per account '
          'per 24 hours; keyword search is 500 requests per '
          'rolling 7 days.';
    }
    try {
      final Object? decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) {
        final Object? error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final Object? msg = error['message'];
          if (msg is String && msg.isNotEmpty) message = msg;
          final Object? code = error['code'];
          if (code is int) message = '$message (code $code)';
        } else {
          final Object? msg = decoded['message'];
          if (msg is String && msg.isNotEmpty) message = msg;
        }
      }
    } catch (_) {
      // Unparseable body: keep the message above.
    }
    return ThreadsApiException(message, statusCode: response.statusCode);
  }

  dynamic _decode(http.Response response) {
    final http.Response checked = _check(response);
    try {
      return json.decode(checked.body);
    } catch (_) {
      throw const ThreadsApiException(
        'Threads API returned an unparseable response.',
      );
    }
  }

  /// Posts of a `{"data": [...]}` response, skipping
  /// malformed entries.
  List<ThreadsPost> _decodePosts(http.Response response) {
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? data = decoded['data'];
      if (data is List<Object?>) {
        return data
            .whereType<Map<String, dynamic>>()
            .map(ThreadsPost.fromJson)
            .where((ThreadsPost p) => p.isValid)
            .toList();
      }
    }
    return <ThreadsPost>[];
  }
}
