/// Direct Deepgram WebSocket service for speech-to-text
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/conversation.dart';
import 'settings_service.dart';

class DeepgramService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;

  /// True between [connect] and [disconnect]. While it is set, a connection
  /// that drops (Deepgram closes idle or broken streams) is re-opened instead
  /// of leaving the app "listening" with nobody on the other end.
  bool _wantConnected = false;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  DateTime _connectedAt = DateTime.now();
  DateTime _lastAudioAt = DateTime.now();

  final String apiKey;
  final String language;
  final String encoding;
  final int sampleRate;
  final Function(List<TranscriptSegment>)? onTranscript;
  final Function(String)? onError;

  /// Called just before a dropped connection is re-opened. Deepgram's stream
  /// clock and "speaker N" numbering start over on a new connection, so
  /// anything keyed to them must be reset here.
  final void Function()? onReconnected;

  /// Streaming endpoint. Overridable so tests can point at a local server.
  final String baseUrl;

  /// How often to check whether a KeepAlive is needed.
  final Duration keepAliveInterval;

  /// First reconnect delay; doubles per failed attempt up to [reconnectMaxDelay].
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;

  DeepgramService({
    required this.apiKey,
    this.language = 'en',
    this.encoding = 'opus',
    this.sampleRate = 16000,
    this.onTranscript,
    this.onError,
    this.onReconnected,
    this.baseUrl = 'wss://api.deepgram.com/v1/listen',
    this.keepAliveInterval = const Duration(seconds: 3),
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 30),
  });

  bool get isConnected => _isConnected;

  Future<void> connect() async {
    if (_isConnected) return;
    _wantConnected = true;
    _reconnectAttempts = 0;
    _openSocket();
  }

  void _openSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      // Deepgram WebSocket URL with parameters
      final uri = Uri.parse(
        '$baseUrl'
        '?model=nova-2'
        '&language=$language'
        '&punctuate=true'
        '&diarize=true'
        '&sample_rate=$sampleRate'
        '&encoding=$encoding'
        '&channels=1'
      );

      final channel = WebSocketChannel.connect(
        uri,
        protocols: ['token', apiKey],
      );
      _channel = channel;

      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (error) {
          if (!identical(channel, _channel)) return; // an old connection
          debugPrint('Deepgram WebSocket error: $error');
          onError?.call(error.toString());
          _handleConnectionLost();
        },
        onDone: () {
          if (!identical(channel, _channel)) return; // an old connection
          debugPrint(
            'Deepgram WebSocket closed '
            '(code ${channel.closeCode}, reason "${channel.closeReason}")',
          );
          _handleConnectionLost();
        },
      );

      _isConnected = true;
      _connectedAt = DateTime.now();
      _lastAudioAt = _connectedAt;
      _startKeepAlive();
      debugPrint('Connected to Deepgram (encoding: $encoding, sampleRate: $sampleRate)');
    } catch (e) {
      debugPrint('Failed to connect to Deepgram: $e');
      onError?.call(e.toString());
      _handleConnectionLost();
    }
  }

  /// Tear down the dead connection and, if the caller still wants one, open a
  /// new one after a short back-off. Safe to call more than once.
  void _handleConnectionLost() {
    // A connection that stayed up for a while was healthy, so start the
    // back-off over; quick repeated failures keep backing off.
    if (_isConnected &&
        DateTime.now().difference(_connectedAt) > const Duration(seconds: 5)) {
      _reconnectAttempts = 0;
    }
    _isConnected = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    subscription?.cancel();
    if (channel != null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }

    if (_wantConnected) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive ?? false) return;
    final factor = 1 << math.min(_reconnectAttempts, 10);
    final delay = Duration(
      milliseconds: math.min(
        reconnectMaxDelay.inMilliseconds,
        reconnectBaseDelay.inMilliseconds * factor,
      ),
    );
    _reconnectAttempts++;
    debugPrint(
      'Deepgram connection lost - reconnecting in ${delay.inMilliseconds} ms '
      '(attempt $_reconnectAttempts)',
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_wantConnected) return;
      onReconnected?.call();
      _openSocket();
    });
  }

  /// Deepgram closes a stream that gets neither audio nor a KeepAlive for
  /// 10 seconds (documented at developers.deepgram.com/docs/audio-keep-alive,
  /// which asks for a KeepAlive text frame every 3-5 seconds). Audio normally
  /// flows constantly, but it can pause, e.g. while an AI query is processed.
  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      final channel = _channel;
      if (!_isConnected || channel == null) return;
      if (DateTime.now().difference(_lastAudioAt) < keepAliveInterval) return;
      try {
        channel.sink.add(jsonEncode({'type': 'KeepAlive'}));
      } catch (e) {
        debugPrint('Deepgram KeepAlive failed: $e');
      }
    });
  }

  void _handleMessage(dynamic message) {
    try {
      final json = jsonDecode(message as String);
      
      // Check if this is a transcript result
      if (json['type'] == 'Results') {
        final alternatives = json['channel']?['alternatives'] as List?;
        if (alternatives != null && alternatives.isNotEmpty) {
          final transcript = alternatives[0]['transcript'] as String?;
          final words = alternatives[0]['words'] as List?;
          
          // Track audio duration for cost calculation
          final duration = json['duration'] as num?;
          if (duration != null && duration > 0) {
            SettingsService.addDeepgramUsage(duration.toDouble() / 60.0); // Convert seconds to minutes
          }
          
          if (transcript != null && transcript.isNotEmpty) {
            // Convert to TranscriptSegment
            final segments = parseWords(words ?? []);
            if (segments.isNotEmpty) {
              onTranscript?.call(segments);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error parsing Deepgram message: $e');
    }
  }

  /// Split a result's words into segments, one per *consecutive run* of the
  /// same speaker. (Grouping all words by speaker, as this used to do, merged
  /// A-B-A turns into one A and one B segment, which scrambled the transcript
  /// order and made each segment span audio from several people.)
  @visibleForTesting
  List<TranscriptSegment> parseWords(List words) {
    if (words.isEmpty) return [];

    final segments = <TranscriptSegment>[];
    var run = <dynamic>[];
    int? runSpeaker;

    void flush() {
      if (run.isEmpty) return;
      // `punctuated_word` carries punctuation/capitalisation; fall back to the
      // bare word if a response does not include it.
      final text = run
          .map((w) => (w['punctuated_word'] ?? w['word'] ?? '').toString())
          .join(' ');
      segments.add(TranscriptSegment(
        text: text,
        speakerId: runSpeaker ?? 0,
        startTime: ((run.first['start'] as num?) ?? 0).toDouble(),
        endTime: ((run.last['end'] as num?) ?? 0).toDouble(),
      ));
      run = <dynamic>[];
    }

    for (final word in words) {
      final speaker = ((word['speaker'] as num?) ?? 0).toInt();
      if (runSpeaker != null && speaker != runSpeaker) flush();
      runSpeaker = speaker;
      run.add(word);
    }
    flush();

    return segments;
  }

  void sendAudio(Uint8List audioData) {
    final channel = _channel;
    if (!_isConnected || channel == null) return;
    _lastAudioAt = DateTime.now();
    try {
      channel.sink.add(audioData);
    } catch (e) {
      debugPrint('Deepgram send failed: $e');
      _handleConnectionLost();
    }
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    _isConnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    // Take the old connection out of the fields before awaiting anything: a
    // connect() that runs while we wait must not have its new socket cleared.
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    await channel?.sink.close();
    debugPrint('Disconnected from Deepgram');
  }
}
