import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rj_music/services/jam_session_service.dart';

/// Transition page opened when a rjmusic://open/jam/<code> deep link is tapped.
/// Auto-joins the jam and navigates to JamSessionPage.
class JamDeepLinkPage extends StatefulWidget {
  final String code;
  const JamDeepLinkPage({super.key, required this.code});

  @override
  State<JamDeepLinkPage> createState() => _JamDeepLinkPageState();
}

class _JamDeepLinkPageState extends State<JamDeepLinkPage> {
  String _status = 'Joining Jam…';

  @override
  void initState() {
    super.initState();
    _join();
  }

  Future<void> _join() async {
    try {
      await jamSessionService.joinSession(widget.code);
      if (!mounted) return;
      // Replace this page with the full JamSessionPage
      context.pushReplacement('/jam_session');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not join Jam: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.headphones_rounded,
              size: 64,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            if (_status.startsWith('Joining'))
              const CircularProgressIndicator()
            else
              TextButton(
                onPressed: () => context.go('/'),
                child: const Text('Go Home'),
              ),
          ],
        ),
      ),
    );
  }
}
