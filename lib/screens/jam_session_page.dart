import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rj_music/services/jam_history_service.dart';
import 'package:rj_music/services/jam_session_service.dart';
import 'package:share_plus/share_plus.dart';

class JamSessionPage extends StatefulWidget {
  const JamSessionPage({super.key});

  @override
  State<JamSessionPage> createState() => _JamSessionPageState();
}

class _JamSessionPageState extends State<JamSessionPage>
    with SingleTickerProviderStateMixin {
  final _codeController = TextEditingController();
  bool _isLoading = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  List<JamHistoryEntry> _history = [];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    jamError.addListener(_onError);
    _loadHistory();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _codeController.dispose();
    jamError.removeListener(_onError);
    super.dispose();
  }

  void _onError() {
    final err = jamError.value;
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _loadHistory() {
    setState(() => _history = JamHistoryService.load());
  }

  Future<void> _startJam() async {
    setState(() => _isLoading = true);
    try {
      await jamSessionService.createSession();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _joinJam([String? prefillCode]) async {
    final code = (prefillCode ?? _codeController.text).trim().toUpperCase();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid 6-character session code')),
      );
      return;
    }
    setState(() => _isLoading = true);
    try {
      await jamSessionService.joinSession(code);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _leaveJam() async {
    setState(() => _isLoading = true);
    try {
      await jamSessionService.leaveSession();
    } finally {
      if (mounted) {
        _loadHistory();
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // No PopScope here — when shown as a dialog via showGeneralDialog
    // (useRootNavigator: true), the root navigator handles back presses
    // cleanly. PopScope(canPop: false) was causing two bugs:
    // 1. It blocked the root nav pop → dialog stuck
    // 2. Back event fell through to GoRouter → player got closed
    return GestureDetector(
      // Swipe down to dismiss
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 400) {
          _safeBack(context);
        }
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: colorScheme.onSurface,
            ),
            onPressed: () => _safeBack(context),
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.headphones_rounded,
                color: colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                'Jam Session',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          centerTitle: true,
        ),
        body: ValueListenableBuilder<bool>(
          valueListenable: jamIsInSession,
          builder: (context, inSession, _) => inSession
              ? _buildActiveSession(colorScheme)
              : _buildLobby(colorScheme),
        ),
      ),
    );
  }

  /// Works whether opened via context.push('/jam') or showGeneralDialog.
  void _safeBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    }
  }

  Widget _buildLobby(ColorScheme colorScheme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.primaryContainer,
              ),
              child: Icon(
                Icons.headphones_rounded,
                size: 60,
                color: colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Listen Together',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Everyone in the Jam can control the music — play, pause, and change songs together.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),

          // Feature chips
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _FeatureChip(
                icon: Icons.play_circle_rounded,
                label: 'Sync Play/Pause',
                colorScheme: colorScheme,
              ),
              _FeatureChip(
                icon: Icons.skip_next_rounded,
                label: 'Change Songs',
                colorScheme: colorScheme,
              ),
              _FeatureChip(
                icon: Icons.people_rounded,
                label: 'Everyone Controls',
                colorScheme: colorScheme,
              ),
            ],
          ),
          const SizedBox(height: 40),

          FilledButton.icon(
            onPressed: _isLoading ? null : _startJam,
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: const Text('Start a Jam'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 16),
            ),
          ),

          const SizedBox(height: 16),

          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'or join',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),

          const SizedBox(height: 16),

          TextField(
            controller: _codeController,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              letterSpacing: 8,
              fontWeight: FontWeight.bold,
            ),
            decoration: InputDecoration(
              hintText: 'XXXXXX',
              hintStyle: TextStyle(
                letterSpacing: 8,
                color: colorScheme.outline,
              ),
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest,
            ),
          ),

          const SizedBox(height: 16),

          OutlinedButton.icon(
            onPressed: _isLoading ? null : _joinJam,
            icon: const Icon(Icons.group_add_rounded),
            label: const Text('Join Jam'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 16),
            ),
          ),

          // ── Recent sessions ──────────────────────────────────────────────
          if (_history.isNotEmpty) ..._buildHistory(colorScheme),
        ],
      ),
    );
  }

  List<Widget> _buildHistory(ColorScheme colorScheme) {
    String formatDuration(Duration d) {
      if (d.inMinutes < 1) return '${d.inSeconds}s';
      if (d.inHours < 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
      return '${d.inHours}h ${d.inMinutes % 60}m';
    }

    String formatDate(DateTime dt) {
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inHours < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays < 1) return '${diff.inHours}h ago';
      if (diff.inDays == 1) return 'Yesterday';
      return '${diff.inDays}d ago';
    }

    return [
      const SizedBox(height: 36),
      Row(
        children: [
          Text(
            'Recent Sessions',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              JamHistoryService.clear();
              _loadHistory();
            },
            child: Text(
              'Clear',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      ...List.generate(_history.length, (i) {
        final entry = _history[i];
        return Dismissible(
          key: ValueKey(
            '${entry.code}_${entry.startedAt.millisecondsSinceEpoch}',
          ),
          direction: DismissDirection.endToStart,
          onDismissed: (_) {
            JamHistoryService.delete(entry);
            _loadHistory();
          },
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.delete_rounded,
              color: colorScheme.onErrorContainer,
            ),
          ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: CircleAvatar(
                backgroundColor: entry.wasHost
                    ? colorScheme.primaryContainer
                    : colorScheme.secondaryContainer,
                child: Icon(
                  entry.wasHost ? Icons.star_rounded : Icons.person_rounded,
                  color: entry.wasHost
                      ? colorScheme.primary
                      : colorScheme.onSecondaryContainer,
                  size: 20,
                ),
              ),
              title: Text(
                entry.code,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                ),
              ),
              subtitle: Text(
                '${entry.wasHost ? 'Host' : 'Guest'} · '
                '${formatDuration(entry.duration)} · '
                '${formatDate(entry.startedAt)}',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: IconButton(
                tooltip: 'Rejoin',
                icon: Icon(Icons.login_rounded, color: colorScheme.primary),
                onPressed: _isLoading ? null : () => _joinJam(entry.code),
              ),
            ),
          ),
        );
      }),
    ];
  }

  Widget _buildActiveSession(ColorScheme colorScheme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pulsing live indicator
          Center(
            child: ScaleTransition(
              scale: _pulseAnimation,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primaryContainer,
                  boxShadow: [
                    BoxShadow(
                      color: colorScheme.primary.withValues(alpha: 0.4),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.headphones_rounded,
                  size: 48,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // LIVE badge
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fiber_manual_record,
                    color: Colors.white,
                    size: 10,
                  ),
                  SizedBox(width: 4),
                  Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          Text(
            'Listening Together',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Everyone can control the music',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),

          // Reconnect status banner
          ValueListenableBuilder<String?>(
            valueListenable: jamStatusNotifier,
            builder: (context, status, _) {
              if (status == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        status,
                        style: TextStyle(
                          color: colorScheme.onTertiaryContainer,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 24),

          // Session code
          ValueListenableBuilder<String?>(
            valueListenable: jamSessionCode,
            builder: (context, code, _) {
              if (code == null) return const SizedBox.shrink();
              final shareLink = '$jamDeepLinkBase/$code';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Session Code',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Code copied to clipboard!'),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            code,
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 8,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.copy_rounded,
                            color: colorScheme.onPrimaryContainer,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Share link button
                  OutlinedButton.icon(
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text:
                            'Join my RJ Music Jam! Tap the link to join: $shareLink',
                        subject: 'Join my Jam on RJ Music',
                      ),
                    ),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Share Invite Link'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 24),

          // Participants
          Text(
            'Listeners',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          ValueListenableBuilder<List<String>>(
            valueListenable: jamParticipants,
            builder: (context, participants, _) {
              return Column(
                children: participants.map((p) {
                  final isHostEntry = p.contains('host');
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: isHostEntry
                          ? colorScheme.primary
                          : colorScheme.secondaryContainer,
                      child: Icon(
                        isHostEntry ? Icons.star_rounded : Icons.person_rounded,
                        color: isHostEntry
                            ? colorScheme.onPrimary
                            : colorScheme.onSecondaryContainer,
                        size: 18,
                      ),
                    ),
                    title: Text(p),
                  );
                }).toList(),
              );
            },
          ),

          const SizedBox(height: 32),

          FilledButton.tonal(
            onPressed: _isLoading ? null : _leaveJam,
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.errorContainer,
              foregroundColor: colorScheme.onErrorContainer,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Leave Session', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.colorScheme,
  });
  final IconData icon;
  final String label;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
