// Stub for non-web platforms. Web build uses web_audio_web.dart.
import 'dart:typed_data';

Future<void> playMp3Bytes(Uint8List bytes) async {
  throw UnimplementedError('Cloud audio is web-only');
}
