import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

/// A single completed jam session entry.
class JamHistoryEntry {
  final String code;
  final bool wasHost;
  final DateTime startedAt;
  final Duration duration;

  JamHistoryEntry({
    required this.code,
    required this.wasHost,
    required this.startedAt,
    required this.duration,
  });

  Map<String, dynamic> toJson() => {
    'code': code,
    'wasHost': wasHost,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'durationMs': duration.inMilliseconds,
  };

  factory JamHistoryEntry.fromJson(Map<String, dynamic> j) => JamHistoryEntry(
    code: j['code'] as String,
    wasHost: j['wasHost'] as bool? ?? false,
    startedAt: DateTime.fromMillisecondsSinceEpoch(j['startedAt'] as int),
    duration: Duration(milliseconds: j['durationMs'] as int? ?? 0),
  );
}

class JamHistoryService {
  static const _boxName = 'JAM_HISTORY';
  static const _key = 'entries';
  static const _maxEntries = 30;

  static Box get _box => Hive.box(_boxName);

  /// Load all entries, newest first.
  static List<JamHistoryEntry> load() {
    final raw = _box.get(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw as String) as List<dynamic>;
    final entries = list
        .map((e) => JamHistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    return entries.reversed.toList(); // newest first
  }

  /// Save a new entry (appends, trims to limit).
  static void record(JamHistoryEntry entry) {
    final raw = _box.get(_key);
    final list = raw != null
        ? (jsonDecode(raw as String) as List<dynamic>)
              .map((e) => e as Map<String, dynamic>)
              .toList()
        : <Map<String, dynamic>>[];
    list.add(entry.toJson());
    if (list.length > _maxEntries) list.removeAt(0);
    _box.put(_key, jsonEncode(list));
  }

  /// Delete a single entry by code+startedAt.
  static void delete(JamHistoryEntry entry) {
    final raw = _box.get(_key);
    if (raw == null) return;
    final list = (jsonDecode(raw as String) as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .where(
          (e) =>
              !(e['code'] == entry.code &&
                  e['startedAt'] == entry.startedAt.millisecondsSinceEpoch),
        )
        .toList();
    _box.put(_key, jsonEncode(list));
  }

  /// Clear all history.
  static void clear() => _box.delete(_key);
}
