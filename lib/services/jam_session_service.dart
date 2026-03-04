import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rj_music/services/jam_history_service.dart';
import 'package:rj_music/services/media_player.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ---------------------------------------------------------------------------
// ⚙️  SERVER URL
// ---------------------------------------------------------------------------
const String _jamServerUrl = 'wss://rahul.anikaizoku.com';
// ---------------------------------------------------------------------------

/// Web link used for sharing — server redirects to rjmusic://open/jam/<code>
const String jamDeepLinkBase = 'https://rahul.anikaizoku.com/join';

// Public state notifiers (reactive UI)
final ValueNotifier<bool> jamIsInSession = ValueNotifier(false);
final ValueNotifier<bool> jamIsHost = ValueNotifier(false);
final ValueNotifier<String?> jamSessionCode = ValueNotifier(null);
final ValueNotifier<List<String>> jamParticipants = ValueNotifier([]);
final ValueNotifier<String?> jamError = ValueNotifier(null);

/// Human-readable status message for reconnect feedback (null = connected/idle)
final ValueNotifier<String?> jamStatusNotifier = ValueNotifier(null);

class JamSessionService {
  JamSessionService._();
  static final JamSessionService instance = JamSessionService._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  // Heartbeat: keeps peers aligned every 2 s
  Timer? _heartbeatTimer;

  // Playback change listeners — auto-broadcast on local user actions
  StreamSubscription? _playbackStateSub;
  VoidCallback? _mediaItemSubListener;
  StreamSubscription? _positionSub;

  String? _myId;
  String? _currentRoom;
  bool _voluntaryLeave = false;
  bool _wasHost = false;
  DateTime? _sessionStart;

  // ---- Reconnect state ----
  int _reconnectAttempts = 0;
  static const int _maxReconnects = 3;
  bool _isReconnecting = false;
  Timer? _reconnectTimer;

  // ---- Echo-loop prevention ----
  int _applyTaskCount = 0;
  DateTime? _suppressBroadcastUntil;
  DateTime? _ignoreIncomingUntil;

  bool get _broadcastSuppressed =>
      _applyTaskCount > 0 ||
      (_suppressBroadcastUntil?.isAfter(DateTime.now()) ?? false);

  bool get _incomingSuppressed =>
      _ignoreIncomingUntil?.isAfter(DateTime.now()) ?? false;

  // Track last applied timestamp so we ignore stale messages
  // Allow up to 500ms clock skew between peers
  int _lastAppliedTs = 0;

  // Track the last ytid we commanded to play, to avoid re-triggering
  String? _lastCommandedYtid;

  // Track last known local position to detect manual seeks
  Duration _lastKnownPos = Duration.zero;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  Future<String> createSession() async {
    await leaveSession();
    _myId = _randomId(8);
    final code = _randomCode();
    _currentRoom = code;
    _voluntaryLeave = false;
    _wasHost = true;
    _sessionStart = DateTime.now();
    jamSessionCode.value = code;
    jamIsHost.value = true;
    jamParticipants.value = ['🎧 You (host)'];
    jamIsInSession.value = true;
    jamError.value = null;
    jamStatusNotifier.value = null;

    await _connect(code);
    _announceSelf('host');
    _startHeartbeat();
    _attachPlaybackListeners();
    return code;
  }

  Future<void> joinSession(String code) async {
    await leaveSession();
    _myId = _randomId(8);
    final normalized = code.toUpperCase();
    _currentRoom = normalized;
    _voluntaryLeave = false;
    _wasHost = false;
    _sessionStart = DateTime.now();
    jamSessionCode.value = normalized;
    jamIsHost.value = false;
    jamParticipants.value = ['🎧 You'];
    jamIsInSession.value = true;
    jamError.value = null;
    jamStatusNotifier.value = null;

    await _connect(normalized);
    _announceSelf('guest');
    _startHeartbeat();
    _attachPlaybackListeners();
  }

  Future<void> leaveSession() async {
    // Record history before clearing state
    if (_currentRoom != null && _sessionStart != null) {
      JamHistoryService.record(
        JamHistoryEntry(
          code: _currentRoom!,
          wasHost: _wasHost,
          startedAt: _sessionStart!,
          duration: DateTime.now().difference(_sessionStart!),
        ),
      );
    }
    _voluntaryLeave = true;
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _applyTaskCount = 0;
    _suppressBroadcastUntil = null;
    _ignoreIncomingUntil = null;

    await _playbackStateSub?.cancel();
    _playbackStateSub = null;
    await _positionSub?.cancel();
    _positionSub = null;
    if (_mediaItemSubListener != null) {
      GetIt.I<MediaPlayer>().currentSongNotifier.removeListener(
        _mediaItemSubListener!,
      );
      _mediaItemSubListener = null;
    }

    if (_channel != null) {
      try {
        _send({'type': 'LEAVE', 'id': _myId});
      } catch (_) {}
    }

    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    jamIsInSession.value = false;
    jamIsHost.value = false;
    jamSessionCode.value = null;
    jamParticipants.value = [];
    jamError.value = null;
    jamStatusNotifier.value = null;
    _myId = null;
    _currentRoom = null;
    _wasHost = false;
    _sessionStart = null;
    _lastAppliedTs = 0;
    _lastCommandedYtid = null;
  }

  void broadcastNow() {
    if (jamIsInSession.value && !_broadcastSuppressed) _doBroadcast();
  }

  // -------------------------------------------------------------------------
  // Playback listeners — fire on local user actions to broadcast immediately
  // -------------------------------------------------------------------------

  void _attachPlaybackListeners() {
    final player = GetIt.I<MediaPlayer>().player;

    // Detect play/pause changes
    _playbackStateSub = player.playingStream
        .distinct()
        .skip(1) // skip initial value
        .listen((_) {
          if (!_broadcastSuppressed) _doBroadcast();
        });

    // Detect song changes
    _mediaItemSubListener = () {
      if (!_broadcastSuppressed) _doBroadcast();
    };
    GetIt.I<MediaPlayer>().currentSongNotifier.addListener(
      _mediaItemSubListener!,
    );

    // Detect manual user seeks (large jumps not caused by normal playback)
    _positionSub = player.positionStream.listen((pos) {
      if (_lastAppliedTs == 0 || _broadcastSuppressed) {
        _lastKnownPos = pos;
        return;
      }

      final diff = (pos - _lastKnownPos).abs();
      if (diff > const Duration(milliseconds: 1500)) {
        _doBroadcast();
        _ignoreIncomingUntil = DateTime.now().add(
          const Duration(milliseconds: 2500),
        );
        _suppressBroadcastUntil = DateTime.now().add(
          const Duration(milliseconds: 1000),
        );
      }
      _lastKnownPos = pos;
    });
  }

  // -------------------------------------------------------------------------
  // WebSocket connection
  // -------------------------------------------------------------------------

  Future<void> _connect(String code) async {
    final sanitized = _sanitize(code);
    final uri = Uri.parse('$_jamServerUrl/$sanitized');

    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
    } catch (e) {
      jamError.value = 'Could not connect to Jam server: $e';
      jamIsInSession.value = false;
      debugPrint('JamSession connect error: $e');
      return;
    }

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (e) {
        debugPrint('JamSession stream error: $e');
        if (!_voluntaryLeave) _scheduleReconnect();
      },
      onDone: () {
        if (!_voluntaryLeave && jamIsInSession.value) {
          debugPrint(
            'JamSession: connection closed unexpectedly — trying to reconnect',
          );
          _scheduleReconnect();
        }
      },
    );
  }

  // -------------------------------------------------------------------------
  // Reconnect logic
  // -------------------------------------------------------------------------

  void _scheduleReconnect() {
    if (_isReconnecting) return;
    if (_reconnectAttempts >= _maxReconnects) {
      jamError.value = 'Disconnected from Jam session.';
      jamIsInSession.value = false;
      jamStatusNotifier.value = null;
      _isReconnecting = false;
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;
    final delaySeconds = pow(2, _reconnectAttempts - 1).toInt(); // 1s, 2s, 4s
    jamStatusNotifier.value =
        'Reconnecting... ($_reconnectAttempts/$_maxReconnects)';

    debugPrint(
      'JamSession: reconnect attempt $_reconnectAttempts in ${delaySeconds}s',
    );

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      if (_voluntaryLeave || _currentRoom == null) {
        _isReconnecting = false;
        return;
      }

      // Clean up old channel before reconnecting
      await _sub?.cancel();
      _sub = null;
      try {
        await _channel?.sink.close();
      } catch (_) {}
      _channel = null;

      await _connect(_currentRoom!);

      if (_channel != null) {
        // Successfully reconnected
        _reconnectAttempts = 0;
        _isReconnecting = false;
        jamStatusNotifier.value = null;
        _announceSelf(jamIsHost.value ? 'host' : 'guest');
        debugPrint('JamSession: reconnected to $_currentRoom');
      } else {
        _isReconnecting = false;
        _scheduleReconnect(); // try again
      }
    });
  }

  // -------------------------------------------------------------------------
  // Message handling
  // -------------------------------------------------------------------------

  void _onMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String?;
      final senderId = data['id'] as String?;

      if (senderId == _myId) return; // ignore own echo

      switch (type) {
        case 'ANNOUNCE':
          _handleAnnounce(data);
        case 'STATE':
          _applyRemoteState(data);
        case 'LEAVE':
          _handleLeave(data);
        case 'END':
          jamError.value = 'A peer ended the session.';
          leaveSession();
      }
    } catch (e) {
      debugPrint('JamSession message parse error: $e');
    }
  }

  void _handleAnnounce(Map<String, dynamic> data) {
    final role = data['role'] as String? ?? 'guest';
    final peerId = (data['id'] as String? ?? '????');
    final short = peerId.length >= 4 ? peerId.substring(0, 4) : peerId;
    final label = role == 'host' ? '👑 Host' : '🎵 Listener';
    final current = List<String>.from(jamParticipants.value);
    if (!current.any((p) => p.contains(short))) {
      current.add('$label ($short)');
      jamParticipants.value = current;
    }
    // Reply immediately so the new peer syncs fast.
    // Send twice with a gap to handle the first packet being lost.
    broadcastNow();
    Future.delayed(const Duration(milliseconds: 500), broadcastNow);
  }

  void _handleLeave(Map<String, dynamic> data) {
    final peerId = data['id'] as String? ?? '';
    if (peerId.isEmpty) return;
    final short = peerId.length >= 4 ? peerId.substring(0, 4) : peerId;
    final current = List<String>.from(jamParticipants.value);
    current.removeWhere((p) => p.contains(short));
    jamParticipants.value = current;
  }

  void _applyRemoteState(Map<String, dynamic> data) {
    try {
      if (_incomingSuppressed) return;

      final remoteTs = data['ts'] as int? ?? 0;

      // Ignore stale messages (allow 500ms clock skew between peers)
      if (remoteTs < _lastAppliedTs - 500) return;
      if (remoteTs > _lastAppliedTs) _lastAppliedTs = remoteTs;

      final ytid = data['ytid'] as String?;
      final posMs = data['positionMs'] as int? ?? 0;
      final isPlaying = data['isPlaying'] as bool? ?? false;
      final songMap = data['song'] as Map<String, dynamic>?;

      if (ytid == null) return;

      _applyAsync(ytid, posMs, isPlaying, songMap);
    } catch (e) {
      debugPrint('JamSession applyRemoteState error: $e');
    }
  }

  Future<void> _applyAsync(
    String ytid,
    int posMs,
    bool isPlaying,
    Map<String, dynamic>? songMap,
  ) async {
    _applyTaskCount++;
    try {
      final mediaPlayer = GetIt.I<MediaPlayer>();
      final currentItem = mediaPlayer.currentSongNotifier.value;
      final currentYtid = currentItem?.extras?['videoId'] as String?;

      // ── Song sync ─────────────────────────────────────────────────────────
      if (currentYtid != ytid && _lastCommandedYtid != ytid) {
        _lastCommandedYtid = ytid;

        if (songMap != null && songMap.isNotEmpty) {
          await mediaPlayer.playSong(Map<String, dynamic>.from(songMap));
          // Poll for the player to be ready (up to 3s) instead of fixed delay
          await _waitForPlayerReady(mediaPlayer.player);
        } else {
          final queue = mediaPlayer.songList;
          final idx = queue.indexWhere((s) {
            final tag = s.tag;
            return tag is MediaItem && tag.extras?['videoId'] == ytid;
          });
          if (idx >= 0) {
            await mediaPlayer.player.seek(Duration.zero, index: idx);
            await _waitForPlayerReady(mediaPlayer.player);
          } else {
            return;
          }
        }
      }

      // ── Position sync ─────────────────────────────────────────────────────
      final currentPos = mediaPlayer.player.position;
      final targetPos = Duration(milliseconds: posMs);
      final drift = (currentPos - targetPos).abs();

      if (drift > const Duration(milliseconds: 1500)) {
        await mediaPlayer.player.seek(targetPos);
      }

      // ── Play/pause sync ───────────────────────────────────────────────────
      final playing = mediaPlayer.player.playing;
      if (isPlaying && !playing) {
        await mediaPlayer.player.play();
      } else if (!isPlaying && playing) {
        await mediaPlayer.player.pause();
      }
    } catch (e) {
      debugPrint('JamSession _applyAsync error: $e');
    } finally {
      _applyTaskCount--;
      _suppressBroadcastUntil = DateTime.now().add(
        const Duration(milliseconds: 1500),
      );
    }
  }

  /// Waits until the player is in a ready state (loading/buffering → ready).
  /// Polls every 100ms for up to 3 seconds.
  Future<void> _waitForPlayerReady(AudioPlayer player) async {
    const maxWait = Duration(seconds: 3);
    const poll = Duration(milliseconds: 100);
    final deadline = DateTime.now().add(maxWait);
    while (DateTime.now().isBefore(deadline)) {
      final state = player.processingState;
      if (state == ProcessingState.ready ||
          state == ProcessingState.completed) {
        return;
      }
      await Future.delayed(poll);
    }
    // Timed out — proceed anyway (better to seek at a wrong point than not at all)
  }

  // -------------------------------------------------------------------------
  // Heartbeat & broadcast
  // -------------------------------------------------------------------------

  void _startHeartbeat() {
    // 2s heartbeat — smaller drift, faster recovery
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_broadcastSuppressed) _doBroadcast();
    });
  }

  void _doBroadcast() {
    if (!jamIsInSession.value) return;
    try {
      final mediaPlayer = GetIt.I<MediaPlayer>();
      final item = mediaPlayer.currentSongNotifier.value;
      final ytid = item?.extras?['videoId'];
      if (ytid == null) return;

      final songMap = item?.extras ?? {};

      _send({
        'type': 'STATE',
        'id': _myId,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ytid': ytid,
        'positionMs': mediaPlayer.player.position.inMilliseconds,
        'isPlaying': mediaPlayer.player.playing,
        if (songMap.isNotEmpty) 'song': songMap,
      });
    } catch (e) {
      debugPrint('JamSession broadcast error $e');
    }
  }

  void _announceSelf(String role) {
    _send({'type': 'ANNOUNCE', 'id': _myId, 'role': role});
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('JamSession send error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Utilities
  // -------------------------------------------------------------------------

  static String _randomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  static String _randomId(int len) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(len, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  static String _sanitize(String code) =>
      code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
}

final jamSessionService = JamSessionService.instance;
