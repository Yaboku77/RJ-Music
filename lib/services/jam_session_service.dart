import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:rj_music/services/media_player.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ---------------------------------------------------------------------------
// ⚙️  SERVER URL
// ---------------------------------------------------------------------------
const String _jamServerUrl = 'wss://rahul.anikaizoku.com';
// ---------------------------------------------------------------------------

// Public state notifiers (reactive UI)
final ValueNotifier<bool> jamIsInSession = ValueNotifier(false);
final ValueNotifier<bool> jamIsHost = ValueNotifier(false);
final ValueNotifier<String?> jamSessionCode = ValueNotifier(null);
final ValueNotifier<List<String>> jamParticipants = ValueNotifier([]);
final ValueNotifier<String?> jamError = ValueNotifier(null);

class JamSessionService {
  JamSessionService._();
  static final JamSessionService instance = JamSessionService._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  // Heartbeat: keeps peers aligned every 3 s
  Timer? _heartbeatTimer;

  // Playback change listeners — auto-broadcast on local user actions
  StreamSubscription? _playbackStateSub;
  VoidCallback? _mediaItemSubListener;

  String? _myId;

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
    jamSessionCode.value = code;
    jamIsHost.value = true;
    jamParticipants.value = ['🎧 You (host)'];
    jamIsInSession.value = true;
    jamError.value = null;

    await _connect(code);
    _announceSelf('host');
    _startHeartbeat();
    _attachPlaybackListeners();
    return code;
  }

  Future<void> joinSession(String code) async {
    await leaveSession();
    _myId = _randomId(8);
    jamSessionCode.value = code.toUpperCase();
    jamIsHost.value = false;
    jamParticipants.value = ['🎧 You'];
    jamIsInSession.value = true;
    jamError.value = null;

    await _connect(code.toUpperCase());
    _announceSelf('guest');
    _startHeartbeat();
    _attachPlaybackListeners();
  }

  Future<void> leaveSession() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _applyTaskCount = 0;
    _suppressBroadcastUntil = null;
    _ignoreIncomingUntil = null;

    await _playbackStateSub?.cancel();
    _playbackStateSub = null;
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
    _myId = null;
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

    // Detect manual user seeks (large jumps not caused by normal 1s ticks)
    player.positionStream.listen((pos) {
      if (_lastAppliedTs == 0 || _broadcastSuppressed) {
        _lastKnownPos = pos;
        return; // ignore startup or if we are currently handling a remote command
      }

      final diff = (pos - _lastKnownPos).abs();
      // If position jumped by more than 1.5 seconds unexpectedly (not normal playback sliding)
      if (diff > const Duration(milliseconds: 1500)) {
        _doBroadcast();

        // Suppress incoming state temporarily so we don't snap back to the remote's old state
        _ignoreIncomingUntil = DateTime.now().add(
          const Duration(milliseconds: 2500),
        );

        // Suppress our own outgoing broadcasts that might be triggered by UI state changes
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
        jamError.value = 'Connection error: $e';
        debugPrint('JamSession stream error: $e');
      },
      onDone: () {
        if (jamIsInSession.value) {
          jamError.value = 'Disconnected from Jam session.';
          jamIsInSession.value = false;
        }
      },
    );
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
    // Reply immediately so the new peer syncs fast
    broadcastNow();
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
      if (_incomingSuppressed) {
        return; // We recently initiated an action locally, ignore incoming to prevent snap-back
      }

      final remoteTs = data['ts'] as int? ?? 0;

      // Ignore stale messages (only apply newer state)
      if (remoteTs <= _lastAppliedTs) return;
      _lastAppliedTs = remoteTs;

      final ytid = data['ytid'] as String?;
      final posMs = data['positionMs'] as int? ?? 0;
      final isPlaying = data['isPlaying'] as bool? ?? false;
      // Full song map sent by broadcaster — needed to load song on this device
      final songMap = data['song'] as Map<String, dynamic>?;

      if (ytid == null) return;

      // Run async operations without blocking
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

      // ── Song sync ───────────────────────────────────────────────────────
      if (currentYtid != ytid && _lastCommandedYtid != ytid) {
        _lastCommandedYtid = ytid;

        if (songMap != null && songMap.isNotEmpty) {
          // Best path: we have the full song data, play it directly
          await mediaPlayer.playSong(Map<String, dynamic>.from(songMap));
          // Wait for it to start loading before seeking
          await Future.delayed(const Duration(milliseconds: 1200));
        } else {
          // Fallback: try to find it in the local queue
          final queue = mediaPlayer.songList;
          final idx = queue.indexWhere((s) {
            final tag = s.tag;
            return tag is MediaItem && tag.extras?['videoId'] == ytid;
          });
          if (idx >= 0) {
            await mediaPlayer.player.seek(Duration.zero, index: idx);
            await Future.delayed(const Duration(milliseconds: 800));
          } else {
            // Can't load song — nothing we can do without song data
            return;
          }
        }
      }

      // ── Position sync ───────────────────────────────────────────────────
      final currentPos = mediaPlayer.player.position;
      final targetPos = Duration(milliseconds: posMs);
      final drift = (currentPos - targetPos).abs();

      // Only seek if drift is meaningful (>1.5 s) and song is ready
      if (drift > const Duration(milliseconds: 1500)) {
        await mediaPlayer.player.seek(targetPos);
      }

      // ── Play/pause sync ─────────────────────────────────────────────────
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
      // Keep it suppressed for 1.5 seconds AFTER the async operations complete
      // to absorb any lingering event streams from the seek/buffering.
      _suppressBroadcastUntil = DateTime.now().add(
        const Duration(milliseconds: 1500),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Heartbeat & broadcast
  // -------------------------------------------------------------------------

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
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

      // Get the current song map from the queue so peers can load it directly
      final songMap = item?.extras ?? {};

      _send({
        'type': 'STATE',
        'id': _myId,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ytid': ytid,
        'positionMs': mediaPlayer.player.position.inMilliseconds,
        'isPlaying': mediaPlayer.player.playing,
        // Send full song map so receiving peers can load song directly
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
