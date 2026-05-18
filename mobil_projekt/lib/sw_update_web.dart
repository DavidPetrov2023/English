// Web-only: detekce nové verze přes polling version.json + unregister SW + reload.
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

String? _currentVersionString;

Future<String?> _fetchVersion() async {
  try {
    // Vytvoř URL s cache-buster aby se nečetlo z cache
    final base = html.window.location.href;
    final uri = Uri.parse(base).resolve('version.json').replace(
      queryParameters: {'ts': DateTime.now().millisecondsSinceEpoch.toString()},
    );
    final req = await html.HttpRequest.request(
      uri.toString(),
      method: 'GET',
      requestHeaders: {'Cache-Control': 'no-cache'},
    );
    final body = req.responseText;
    if (body == null || body.isEmpty) return null;
    final data = json.decode(body) as Map<String, dynamic>;
    final version = data['version'] ?? '';
    final buildNumber = data['build_number'] ?? '';
    return '$version+$buildNumber';
  } catch (_) {
    return null;
  }
}

void startVersionPolling(void Function(String version) onNewVersion) {
  _fetchVersion().then((initial) {
    _currentVersionString = initial;
    // Poll každou minutu
    Timer.periodic(const Duration(seconds: 60), (_) async {
      final latest = await _fetchVersion();
      if (latest != null &&
          _currentVersionString != null &&
          latest != _currentVersionString) {
        onNewVersion(latest);
      }
    });
  });
}

Future<void> applyUpdate() async {
  try {
    final sw = html.window.navigator.serviceWorker;
    if (sw != null) {
      final regs = await sw.getRegistrations();
      if (regs != null) {
        for (final reg in regs) {
          try {
            await reg.unregister();
          } catch (_) {}
        }
      }
    }
    // Vyčistit Cache API
    final caches = html.window.navigator;
    try {
      // ignore: avoid_dynamic_calls
      await (caches as dynamic).caches?.keys()?.then((keys) async {
        for (final key in keys) {
          // ignore: avoid_dynamic_calls
          await (caches as dynamic).caches?.delete(key);
        }
      });
    } catch (_) {}
  } catch (_) {}
  html.window.location.reload();
}
