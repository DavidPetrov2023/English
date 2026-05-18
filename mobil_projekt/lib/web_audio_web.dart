// Web-only implementation using dart:html AudioElement.
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

Future<void> playMp3Bytes(Uint8List bytes) async {
  final blob = html.Blob([bytes], 'audio/mpeg');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final audio = html.AudioElement(url);
  final completer = Completer<void>();
  audio.onEnded.listen((_) {
    html.Url.revokeObjectUrl(url);
    if (!completer.isCompleted) completer.complete();
  });
  audio.onError.listen((e) {
    html.Url.revokeObjectUrl(url);
    if (!completer.isCompleted) completer.completeError('audio error');
  });
  await audio.play();
  // Don't await completer - return immediately so UI is responsive.
  // The blob URL is cleaned up on ended/error.
}
