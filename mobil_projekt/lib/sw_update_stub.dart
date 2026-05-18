// Stub pro non-web platformy - service worker neexistuje na mobile.
void startVersionPolling(void Function(String version) onNewVersion) {
  // No-op
}

Future<void> applyUpdate() async {
  // No-op
}
