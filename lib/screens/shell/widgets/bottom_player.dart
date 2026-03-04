import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:rj_music/services/media_player.dart';
import 'package:rj_music/utils/adaptive_widgets/buttons.dart';
import 'package:rj_music/utils/adaptive_widgets/listtile.dart';
import 'package:rj_music/utils/song_thumbnail.dart';

class BottomPlayer extends StatefulWidget {
  const BottomPlayer({super.key});

  @override
  State<BottomPlayer> createState() => _BottomPlayerState();
}

class _BottomPlayerState extends State<BottomPlayer> {
  // Track slide direction for song-change transition
  int _slideDir = 1; // 1 = slide left (next), -1 = slide right (prev)

  @override
  Widget build(BuildContext context) {
    final mediaPlayer = GetIt.I<MediaPlayer>();
    return StreamBuilder(
      stream: mediaPlayer.currentTrackStream,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final currentSong = data?.currentItem;
        if (currentSong == null) return const SizedBox();

        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: GestureDetector(
              // Tap → open full player
              onTap: () => context.push('/player'),

              // Swipe UP → open full player
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) < -300) {
                  context.push('/player');
                }
              },

              // Swipe LEFT/RIGHT → change song with animated transition
              onHorizontalDragEnd: (details) {
                final v = details.primaryVelocity ?? 0;
                if (v < -300) {
                  setState(() => _slideDir = 1);
                  GetIt.I<MediaPlayer>().player.seekToNext();
                } else if (v > 300) {
                  setState(() => _slideDir = -1);
                  GetIt.I<MediaPlayer>().player.seekToPrevious();
                }
              },

              child: AdaptiveListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                // Artwork + song info slide when song changes
                leading: Hero(
                  tag: 'player-artwork',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _SlidingSongInfo(
                      song: currentSong,
                      slideDir: _slideDir,
                    ),
                  ),
                ),
                title: _SlidingText(
                  key: ValueKey('title-${currentSong.id}'),
                  text: currentSong.title,
                  slideDir: _slideDir,
                ),
                subtitle:
                    (currentSong.artist != null ||
                        currentSong.extras?['subtitle'] != null)
                    ? _SlidingText(
                        key: ValueKey('subtitle-${currentSong.id}'),
                        text:
                            currentSong.artist ??
                            currentSong.extras!['subtitle'],
                        slideDir: _slideDir,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                      )
                    : null,
                // Only play/pause — no next button, no transition
                trailing: ValueListenableBuilder(
                  valueListenable: GetIt.I<MediaPlayer>().buttonState,
                  builder: (context, buttonState, _) {
                    final isPlaying = buttonState == ButtonState.playing;
                    final isLoading = buttonState == ButtonState.loading;
                    return AdaptiveIconButton(
                      onPressed: isLoading
                          ? null
                          : () {
                              GetIt.I<MediaPlayer>().player.playing
                                  ? GetIt.I<MediaPlayer>().player.pause()
                                  : GetIt.I<MediaPlayer>().player.play();
                            },
                      icon: isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              isPlaying ? Icons.pause : Icons.play_arrow,
                              size: 30,
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Artwork thumbnail that animates on song change
class _SlidingSongInfo extends StatelessWidget {
  final MediaItem song;
  final int slideDir;

  const _SlidingSongInfo({required this.song, required this.slideDir});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        layoutBuilder: (cur, prev) => Stack(
          alignment: Alignment.center,
          children: [...prev, if (cur != null) cur],
        ),
        transitionBuilder: (child, anim) {
          final incoming = child.key == ValueKey(song.id);
          final dir = incoming ? slideDir.toDouble() : -slideDir.toDouble();
          return SlideTransition(
            position: Tween<Offset>(begin: Offset(dir, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
            child: child,
          );
        },
        child: SongThumbnail(
          key: ValueKey(song.id),
          song: song.extras!,
          dp: MediaQuery.of(context).devicePixelRatio,
          height: 50,
          width: 50,
          fit: BoxFit.fill,
        ),
      ),
    );
  }
}

/// Text that slides on song change
class _SlidingText extends StatelessWidget {
  final String text;
  final int slideDir;
  final TextStyle? style;

  const _SlidingText({
    super.key,
    required this.text,
    required this.slideDir,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        layoutBuilder: (cur, prev) => Stack(
          alignment: Alignment.centerLeft,
          children: [...prev, if (cur != null) cur],
        ),
        transitionBuilder: (child, anim) {
          final incoming = child.key == key;
          final dir = incoming ? slideDir.toDouble() : -slideDir.toDouble();
          return SlideTransition(
            position: Tween<Offset>(begin: Offset(dir, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
            child: child,
          );
        },
        child: Text(
          key: key,
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}
