import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi_local/services/deepgram_service.dart';

/// A stand-in for Deepgram's streaming endpoint that records what clients send.
class FakeDeepgram {
  late final HttpServer _server;
  final connections = <WebSocket>[];

  /// Messages per connection: binary frames as `List<int>`, text as `String`.
  final received = <List<dynamic>>[];

  static Future<FakeDeepgram> start() async {
    final f = FakeDeepgram();
    f._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    f._server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(
        req,
        protocolSelector: (p) => p.first,
      );
      final log = <dynamic>[];
      f.connections.add(ws);
      f.received.add(log);
      ws.listen(log.add, onError: (_) {}, onDone: () {});
    });
    return f;
  }

  String get url => 'ws://127.0.0.1:${_server.port}/v1/listen';

  Future<void> stop() async {
    for (final c in connections) {
      await c.close();
    }
    await _server.close(force: true);
  }
}

/// The binary (audio) frames in [log], leaving out KeepAlive text frames.
List<List<int>> audioFrames(List<dynamic> log) =>
    log.whereType<List<int>>().toList();

/// Polls until [test] is true or [timeout] passes.
Future<bool> waitFor(bool Function() test,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return test();
}

Uint8List frame() => Uint8List.fromList([1, 2, 3, 4]);

void main() {
  late FakeDeepgram server;
  setUp(() async => server = await FakeDeepgram.start());
  tearDown(() async => server.stop());

  DeepgramService make({void Function()? onReconnected}) => DeepgramService(
        apiKey: 'k',
        baseUrl: server.url,
        encoding: 'linear16',
        keepAliveInterval: const Duration(milliseconds: 100),
        reconnectBaseDelay: const Duration(milliseconds: 50),
        reconnectMaxDelay: const Duration(milliseconds: 200),
        onReconnected: onReconnected,
      );

  test('connect() during a slow disconnect() keeps the new connection', () async {
    final dg = make();
    await dg.connect();
    await waitFor(() => server.received.isNotEmpty);

    // disconnect() awaits closing the old socket; connect() runs meanwhile.
    final closing = dg.disconnect();
    await dg.connect();
    await closing;

    expect(await waitFor(() => server.received.length >= 2), isTrue);
    dg.sendAudio(frame());
    expect(await waitFor(() => audioFrames(server.received[1]).isNotEmpty), isTrue,
        reason: 'audio must reach the second connection');
    await dg.disconnect();
  });

  test('audio reaches the server', () async {
    final dg = make();
    await dg.connect();
    await waitFor(() => server.received.isNotEmpty);
    dg.sendAudio(frame());
    expect(
        await waitFor(() => audioFrames(server.received.first).isNotEmpty),
        isTrue);
    await dg.disconnect();
  });

  test('a connection closed by the server is re-opened and audio flows again',
      () async {
    var reconnects = 0;
    final dg = make(onReconnected: () => reconnects++);
    await dg.connect();
    await waitFor(() => server.connections.length == 1);

    // Deepgram drops the stream (e.g. idle timeout).
    await server.connections.first.close(4000, 'simulated drop');

    expect(await waitFor(() => server.connections.length == 2), isTrue,
        reason: 'client should open a second connection');
    expect(reconnects, 1);
    expect(await waitFor(() => dg.isConnected), isTrue);

    dg.sendAudio(frame());
    expect(await waitFor(() => audioFrames(server.received[1]).isNotEmpty), isTrue,
        reason: 'audio must reach the new connection');
    await dg.disconnect();
  });

  test('audio sent while disconnected is dropped, not queued or thrown', () async {
    final dg = make();
    await dg.connect();
    await waitFor(() => server.connections.length == 1);
    await server.connections.first.close();
    expect(await waitFor(() => !dg.isConnected), isTrue,
        reason: 'the client should notice the closed connection');
    expect(() => dg.sendAudio(frame()), returnsNormally);
    await dg.disconnect();
  });

  test('keeps reconnecting after repeated drops', () async {
    final dg = make();
    await dg.connect();
    for (var i = 1; i <= 3; i++) {
      await waitFor(() => server.connections.length == i);
      await server.connections[i - 1].close();
    }
    expect(await waitFor(() => server.connections.length == 4), isTrue);
    await dg.disconnect();
  });

  test('disconnect() stops any further reconnecting', () async {
    final dg = make();
    await dg.connect();
    await waitFor(() => server.connections.length == 1);
    await dg.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(server.connections.length, 1);
    expect(dg.isConnected, isFalse);
  });

  test('sends KeepAlive text frames when no audio is flowing', () async {
    final dg = make();
    await dg.connect();
    await waitFor(() => server.connections.length == 1);
    final ok = await waitFor(
        () => server.received.first.contains('{"type":"KeepAlive"}'));
    expect(ok, isTrue);
    await dg.disconnect();
  });

  test('does not send KeepAlive while audio is flowing', () async {
    final dg = make();
    await dg.connect();
    await waitFor(() => server.connections.length == 1);
    final stop = DateTime.now().add(const Duration(milliseconds: 600));
    while (DateTime.now().isBefore(stop)) {
      dg.sendAudio(frame());
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(server.received.first.whereType<String>(), isEmpty);
    await dg.disconnect();
  });
}
