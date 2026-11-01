import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A release a user's update feed names. Elarni only shows it; nothing installs.
typedef AvailableUpdate = ({String version, String url});

/// Reads Elarni's own feed, `{"version": "0.4.0", "url": "https://…"}`, or a
/// GitHub `releases/latest` reply, so a mirror can serve either.
AvailableUpdate? parseUpdateFeed(String body) {
  final Object? value;
  try {
    value = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (value is! Map) return null;
  // A GitHub reply's own url is its API address; html_url is the page.
  final github = value.containsKey('tag_name');
  final version = value[github ? 'tag_name' : 'version'];
  final url = value[github ? 'html_url' : 'url'];
  if (version is! String || url is! String) return null;
  if (compareVersions(version, '0') == null || !isHttpsURL(url)) return null;
  return (version: version.replaceFirst(RegExp('^[vV]'), ''), url: url);
}

bool isHttpsURL(String value) {
  final uri = Uri.tryParse(value);
  return value.length <= 2048 &&
      uri != null &&
      uri.isScheme('https') &&
      uri.host.isNotEmpty;
}

/// Dotted numbers, an optional leading v and an ignored `+build`; anything
/// else (a pre-release tag) is null, so it never raises a notice.
int? compareVersions(String a, String b) {
  List<int>? parts(String value) {
    final match = RegExp(
      r'^[vV]?(\d{1,9}(?:\.\d{1,9})*)(?:\+.*)?$',
    ).firstMatch(value);
    return match?.group(1)!.split('.').map(int.parse).toList();
  }

  final left = parts(a), right = parts(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < left.length || i < right.length; i++) {
    final difference =
        (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
    if (difference != 0) return difference;
  }
  return 0;
}

/// Tests swap the network for a fixed reply.
Future<String> Function(Uri url) updateFeedFetch = fetchUpdateFeed;

/// A plain GET that carries no device ID. It takes the system's route, so it
/// goes through the tunnel while the VPN is on.
Future<String> fetchUpdateFeed(Uri url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'Elarni';
  try {
    var target = url;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!isHttpsURL(target.toString()))
        throw const FormatException('The update feed must use https.');
      final request = await client.getUrl(target)
        ..followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (response.isRedirect && location != null) {
        await response.drain<void>();
        target = target.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: target);
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        body.add(chunk);
        // A GitHub release reply with its asset list runs past 64 KB.
        if (body.length > 1024 * 1024)
          throw const FormatException('The update feed is too large.');
      }
      return utf8.decode(body.takeBytes());
    }
    throw HttpException('Too many redirects', uri: url);
  } finally {
    client.close(force: true);
  }
}
