import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi_local/services/settings_service.dart';
import 'package:omi_local/services/speaker_id_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('sha256OfFile matches the known digest of a small file', () async {
    final dir = Directory.systemTemp.createTempSync('sha_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/abc.bin')..writeAsStringSync('abc');
    expect(
      await SpeakerIdService.sha256OfFile(f),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.init();
  });

  group('SpeakerIdService.feedPcm', () {
    test('a failed first decode still advances the timeline by one frame', () {
      final svc = SpeakerIdService();
      svc.feedPcm(null);
      // Assumed 20 ms frame at 16 kHz.
      expect(svc.buffer.durationSeconds, closeTo(0.02, 1e-9));
    });

    test('a failed decode after a good frame repeats that frame length', () {
      final svc = SpeakerIdService();
      svc.feedPcm(Uint8List(1280)); // 640 samples = 40 ms
      svc.feedPcm(null);
      expect(svc.buffer.durationSeconds, closeTo(0.08, 1e-9));
    });

    test('resetStream starts the timeline again', () {
      final svc = SpeakerIdService();
      svc.feedPcm(Uint8List(640));
      svc.resetStream();
      expect(svc.buffer.durationSeconds, 0);
    });
  });

  group('SpeakerIdService.dispose', () {
    test('initialize after dispose fails instead of downloading again', () async {
      final svc = SpeakerIdService()..dispose();
      await expectLater(svc.initialize(), throwsA(isA<StateError>()));
    });
  });
}
