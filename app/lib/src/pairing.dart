import 'dart:convert';
import 'dart:io';

import 'settings.dart';

/// What the bridge draws on the terminal, as read by the camera or typed in.
///
/// The shape is `HOST:PORT:CODE`, matching what `gather-app-bridge pair` prints.
/// Only the code is secret; the address is there because there is no relay in the
/// middle to look the Mac up, so the phone has to be told where to knock.
class PairPayload {
  const PairPayload({required this.code, this.host, this.port});

  final String code;
  final String? host;
  final int? port;

  bool get hasAddress => host != null && port != null;

  /// Reads a scanned or typed payload, or null when there is no pairing code in
  /// it at all — which is how a Wi-Fi label wandering through the viewfinder is
  /// told from a code worth acting on.
  static PairPayload? parse(String raw) {
    final parts = raw.trim().split(':');

    if (parts.length == 1) {
      final code = normaliseCode(parts.first);
      return code == null ? null : PairPayload(code: code);
    }
    if (parts.length != 3) return null;

    final code = normaliseCode(parts[2]);
    if (code == null) return null;

    final host = parts[0].trim().toLowerCase();
    final port = int.tryParse(parts[1].trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      // The code is still good — it is the address that is unreadable.
      return PairPayload(code: code);
    }
    return PairPayload(code: code, host: host, port: port);
  }

  /// Reads a typed `HOST:PORT`, accepting a bare host on the default port.
  static ({String host, int port})? parseAddress(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return null;
    final parts = text.split(':');
    if (parts.length > 2) return null;
    final host = parts.first.trim();
    if (host.isEmpty || host.contains(RegExp(r'[^a-z0-9._-]'))) return null;
    if (parts.length == 1) return (host: host, port: BridgeSettings.defaultPort);
    final port = int.tryParse(parts[1].trim());
    if (port == null || port < 1 || port > 65535) return null;
    return (host: host, port: port);
  }
}

/// The bridge's code alphabet, which excludes every character a person could
/// misread: no `0`/`O`, no `1`/`I`/`L`.
const _alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

/// Cleans a code up, or returns null when what is left cannot be one.
///
/// Spaces and dashes people add for readability are dropped. Characters outside
/// the alphabet are dropped too, which then fails the length check — deliberately,
/// because there is no sound way to guess whether a reported `O` meant `Q` or `D`,
/// and pairing on a guess would be worse than asking someone to look again.
String? normaliseCode(String raw) {
  final buffer = StringBuffer();
  for (final ch in raw.toUpperCase().split('')) {
    if (_alphabet.contains(ch)) buffer.write(ch);
  }
  final code = buffer.toString();
  return code.length == 8 ? code : null;
}

/// Result of trading a code for credentials.
sealed class PairResult {
  const PairResult();
}

class PairSuccess extends PairResult {
  const PairSuccess(this.settings, this.name);

  final BridgeSettings settings;

  /// What the Mac calls itself, for the "paired with…" line.
  final String name;
}

class PairFailure extends PairResult {
  const PairFailure(this.message);

  final String message;
}

/// Exchanges a pairing code for the bridge's token.
///
/// This is the one unauthenticated call in the API, for the obvious reason that
/// handing over the token is its whole purpose. The bridge only keeps a code
/// alive for fifteen minutes after somebody ran `pair`, burns it on use, and
/// throws it away after a few wrong guesses.
Future<PairResult> claimPairing({
  required String host,
  required int port,
  required String code,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final uri = Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: '/pair/claim',
      queryParameters: {'code': code},
    );
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 8));
    final body = await response.transform(utf8.decoder).join();

    Map<String, Object?> parsed;
    try {
      parsed = (jsonDecode(body) as Map).cast<String, Object?>();
    } catch (_) {
      return PairFailure(
        'Something answered at $host:$port, but it was not a Gather bridge.',
      );
    }

    if (response.statusCode == 200 && parsed['token'] is String) {
      return PairSuccess(
        BridgeSettings(
          host: host,
          // The bridge reports the port it actually serves on, which is the one
          // to keep — the address on screen could have come from an older run.
          port: (parsed['port'] as num?)?.toInt() ?? port,
          token: parsed['token'] as String,
        ),
        (parsed['name'] as String?) ?? host,
      );
    }

    return PairFailure(
      (parsed['detail'] as String?) ?? 'That code was refused (${response.statusCode}).',
    );
  } on SocketException {
    // The permission comes first on purpose. From iOS 14 the *first* connection
    // to a private address is what raises the "find devices on your network"
    // prompt, and that attempt fails while the prompt is still open — so the
    // honest first answer to this error is "allow it and tap pair again", not
    // "check your Wi-Fi". Once refused, the prompt never returns and only
    // Settings will do.
    return const PairFailure(
      'Could not reach that Mac. If iOS just asked whether this app may find '
      'devices on your network, allow it and pair again — the first try fails '
      'while that prompt is open. You can also turn it on under Settings › '
      'Privacy & Security › Local Network. Otherwise check that both devices '
      'are on the same Wi-Fi and that the bridge is running.',
    );
  } on HttpException {
    return const PairFailure('The bridge did not answer properly. Try pairing again.');
  } catch (error) {
    return PairFailure('Pairing failed: $error');
  } finally {
    client.close(force: true);
  }
}
