import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rj_music/services/jam_session_service.dart';

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

  Future<void> _startJam() async {
    setState(() => _isLoading = true);
    try {
      await jamSessionService.createSession();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _joinJam() async {
    final code = _codeController.text.trim().toUpperCase();
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: colorScheme.onSurface,
          ),
          onPressed: () => Navigator.pop(context),
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
    );
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
        ],
      ),
    );
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
                      color: colorScheme.primary.withOpacity(0.4),
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

          const SizedBox(height: 24),

          // Session code
          ValueListenableBuilder<String?>(
            valueListenable: jamSessionCode,
            builder: (context, code, _) {
              if (code == null) return const SizedBox.shrink();
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
