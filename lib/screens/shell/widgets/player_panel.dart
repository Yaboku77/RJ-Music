import 'dart:math';
import 'dart:ui';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';
import 'package:text_scroll/text_scroll.dart';
import 'package:rj_music/screens/jam_session_page.dart' as jam;

import '../../../generated/l10n.dart';
import '../../../services/media_player.dart';
import '../../../themes/colors.dart';
import '../../../themes/dark.dart';
import '../../../themes/text_styles.dart';
import '../../../utils/bottom_modals.dart';
import '../../../utils/song_thumbnail.dart';
import '../../player/widgets/play_pause_buton.dart';
import '../../player/widgets/queue_list.dart';

/// Height of the mini-player bar. Also used by AppShell for content padding.
const double kMiniPlayerHeight = 72.0;

/// Unified player panel that morphs from a 72 px mini-bar to full screen.
/// Drop this inside a [Stack] in AppShell.
class PlayerPanel extends StatefulWidget {
  const PlayerPanel({super.key});

  @override
  State<PlayerPanel> createState() => PlayerPanelState();
}

class PlayerPanelState extends State<PlayerPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final PanelController _queueCtrl = PanelController();

  // drag tracking
  double _dragStartY = 0;
  double _ctrlAtDragStart = 0;

  // song swipe direction
  int _slideDir = 1;

  Color? _bgColor;
  MediaItem? _currentSong;

  bool get isExpanded => _ctrl.value > 0.5;

  void expand() => _ctrl.animateTo(
    1.0,
    duration: const Duration(milliseconds: 380),
    curve: Curves.easeOutCubic,
  );
  void collapse() => _ctrl.animateTo(
    0.0,
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, value: 0.0);
    _currentSong = GetIt.I<MediaPlayer>().currentSongNotifier.value;
    GetIt.I<MediaPlayer>().currentSongNotifier.addListener(_onSongChanged);
  }

  @override
  void dispose() {
    GetIt.I<MediaPlayer>().currentSongNotifier.removeListener(_onSongChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onSongChanged() {
    if (mounted)
      setState(
        () => _currentSong = GetIt.I<MediaPlayer>().currentSongNotifier.value,
      );
  }

  Future<void> _updateBg(ImageProvider img) async {
    final cs = await ColorScheme.fromImageProvider(provider: img);
    if (mounted) setState(() => _bgColor = cs.primary);
  }

  // ── drag handlers ──────────────────────────────────────────────────────────
  void _dragStart(DragStartDetails d, double screenH) {
    _dragStartY = d.globalPosition.dy;
    _ctrlAtDragStart = _ctrl.value;
  }

  void _dragUpdate(DragUpdateDetails d, double screenH) {
    final delta =
        -(d.globalPosition.dy - _dragStartY) / (screenH - kMiniPlayerHeight);
    _ctrl.value = (_ctrlAtDragStart + delta).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    final vel = d.primaryVelocity ?? 0;
    if (vel < -500) {
      expand();
    } else if (vel > 500) {
      collapse();
    } else if (_ctrl.value > 0.5) {
      expand();
    } else {
      collapse();
    }
  }

  void _hDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v < -300) {
      setState(() => _slideDir = 1);
      GetIt.I<MediaPlayer>().player.seekToNext();
    } else if (v > 300) {
      setState(() => _slideDir = -1);
      GetIt.I<MediaPlayer>().player.seekToPrevious();
    }
  }

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final song = _currentSong;
    if (song == null) return const SizedBox.shrink();

    final screen = MediaQuery.of(context).size;
    final safeB = MediaQuery.of(context).padding.bottom;
    final t = _ctrl.value;

    final panelH = lerpDouble(kMiniPlayerHeight + safeB, screen.height, t)!;
    final borderR = lerpDouble(0.0, 20.0, (t * 5).clamp(0, 1))!;
    final artSize = lerpDouble(
      48.0,
      min(screen.width - 48, screen.height * 0.42),
      t,
    )!;

    final baseBg = Theme.of(context).colorScheme.surfaceContainerLow;
    final bg = Color.lerp(baseBg, Colors.black87, t)!;
    final grad = _bgColor ?? Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: panelH,
          child: GestureDetector(
            // vertical drag — tracks finger in real time
            onVerticalDragStart: (d) => _dragStart(d, screen.height),
            onVerticalDragUpdate: (d) => _dragUpdate(d, screen.height),
            onVerticalDragEnd: _dragEnd,
            // horizontal drag — only changes song when expanded
            onHorizontalDragEnd: isExpanded ? _hDragEnd : null,
            // tap on mini → expand
            onTap: isExpanded ? null : expand,
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(borderR),
              ),
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: t > 0.5
                    ? const SystemUiOverlayStyle(
                        statusBarColor: Colors.transparent,
                        statusBarIconBrightness: Brightness.light,
                        statusBarBrightness: Brightness.dark,
                      )
                    : SystemUiOverlayStyle.dark,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: t > 0.05
                        ? LinearGradient(
                            colors: [
                              grad.withAlpha(210),
                              grad.withAlpha(60),
                              bg,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    color: t <= 0.05 ? baseBg : null,
                  ),
                  child: SafeArea(
                    top: t > 0.5,
                    bottom: true,
                    child: Stack(
                      children: [
                        // ── MINI layer ──────────────────────────────────────
                        Opacity(
                          opacity: (1 - t * 4).clamp(0.0, 1.0),
                          child: _buildMini(song, artSize),
                        ),
                        // ── FULL layer ──────────────────────────────────────
                        Opacity(
                          opacity: ((t - 0.3) / 0.7).clamp(0.0, 1.0),
                          child: IgnorePointer(
                            ignoring: !isExpanded,
                            child: _buildFull(song, screen),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Mini bar ───────────────────────────────────────────────────────────────
  Widget _buildMini(MediaItem song, double artSize) {
    return SizedBox(
      height: kMiniPlayerHeight,
      child: Row(
        children: [
          const SizedBox(width: 12),
          _artwork(song, artSize, mini: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                if (song.artist != null)
                  Text(
                    song.artist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
              ],
            ),
          ),
          ValueListenableBuilder(
            valueListenable: GetIt.I<MediaPlayer>().buttonState,
            builder: (_, state, __) => IconButton(
              icon: Icon(
                state == ButtonState.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 28,
              ),
              onPressed: () {
                GetIt.I<MediaPlayer>().player.playing
                    ? GetIt.I<MediaPlayer>().player.pause()
                    : GetIt.I<MediaPlayer>().player.play();
              },
            ),
          ),
          StreamBuilder(
            stream: GetIt.I<MediaPlayer>().player.sequenceStateStream,
            builder: (_, __) {
              if (!GetIt.I<MediaPlayer>().player.hasNext)
                return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(
                  Icons.skip_next_rounded,
                  color: Colors.white,
                  size: 24,
                ),
                onPressed: () => GetIt.I<MediaPlayer>().player.seekToNext(),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  // ── Full player ────────────────────────────────────────────────────────────
  Widget _buildFull(MediaItem song, Size screen) {
    return Theme(
      data: darkTheme(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.white,
          primary: Colors.white,
          brightness: Brightness.dark,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(
          preferredSize: AppBar().preferredSize,
          child: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
              onPressed: collapse,
            ),
            actions: [
              // Jam button
              IconButton(
                icon: const Icon(Icons.people_rounded),
                onPressed: () {
                  showGeneralDialog(
                    context: context,
                    useRootNavigator: true,
                    barrierDismissible: false,
                    barrierColor: Colors.transparent,
                    transitionDuration: const Duration(milliseconds: 350),
                    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
                      position:
                          Tween<Offset>(
                            begin: const Offset(0, 1),
                            end: Offset.zero,
                          ).animate(
                            CurvedAnimation(
                              parent: anim,
                              curve: Curves.easeOutCubic,
                            ),
                          ),
                      child: child,
                    ),
                    pageBuilder: (ctx, _, __) => jam.JamSessionPage(),
                  );
                },
              ),
              // Queue
              IconButton(
                icon: const Icon(Icons.queue_music_rounded),
                onPressed: () {
                  if (_queueCtrl.isAttached) {
                    _queueCtrl.isPanelOpen
                        ? _queueCtrl.close()
                        : _queueCtrl.open();
                  }
                },
              ),
              // More
              IconButton(
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () {
                  if (song.extras != null)
                    Modals.showPlayerOptionsModal(context, song.extras!);
                },
              ),
            ],
          ),
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            final isLand = w > h;
            final artW = isLand ? w / 2.3 : min(w, h / 2.2) - 24;

            final artWidget = ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                layoutBuilder: (cur, prev) => Stack(
                  alignment: Alignment.center,
                  children: [...prev, if (cur != null) cur],
                ),
                transitionBuilder: (child, anim) {
                  final incoming = child.key == ValueKey(_currentSong?.id);
                  final dir = incoming
                      ? _slideDir.toDouble()
                      : -_slideDir.toDouble();
                  return SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: Offset(dir, 0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: anim,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: child,
                  );
                },
                child: _artwork(
                  song,
                  artW,
                  key: ValueKey(_currentSong?.id),
                  mini: false,
                ),
              ),
            );

            if (isLand) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  artWidget,
                  _Controls(song: song, width: w - artW, height: h),
                ],
              );
            }

            return Stack(
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    artWidget,
                    _Controls(song: song, width: w, height: h - artW - 24),
                  ],
                ),
                SlidingUpPanel(
                  controller: _queueCtrl,
                  color: Colors.transparent,
                  padding: EdgeInsets.zero,
                  margin: EdgeInsets.zero,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                  boxShadow: const [],
                  minHeight: 50 + MediaQuery.of(context).padding.bottom,
                  panel: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                    child: Container(
                      width: w,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            height: 5,
                            width: 50,
                            decoration: BoxDecoration(
                              color: greyColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            S.of(context).Next_Up,
                            style: textStyle(context, bold: true),
                          ),
                        ],
                      ),
                    ),
                  ),
                  body: const QueueList(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Artwork helper ─────────────────────────────────────────────────────────
  Widget _artwork(MediaItem song, double size, {Key? key, bool mini = false}) {
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 300),
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(mini ? 8 : 16),
        child: SongThumbnail(
          song: song.extras ?? const {},
          dp: 2,
          height: size,
          width: size,
          fit: BoxFit.cover,
          onImageReady: mini ? null : _updateBg,
        ),
      ),
    );
  }
}

// ── Controls ───────────────────────────────────────────────────────────────────
class _Controls extends StatelessWidget {
  final MediaItem? song;
  final double width, height;

  const _Controls({
    required this.song,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    if (song == null) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Title + artist
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextScroll(
                  song!.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  velocity: const Velocity(pixelsPerSecond: Offset(30, 0)),
                ),
                if (song!.artist != null)
                  Text(
                    song!.artist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
              ],
            ),
            // Progress bar
            ValueListenableBuilder(
              valueListenable: GetIt.I<MediaPlayer>().progressBarState,
              builder: (_, ps, __) => ProgressBar(
                progress: ps.current,
                buffered: ps.buffered,
                total: ps.total,
                thumbColor: Colors.white,
                progressBarColor: Colors.white,
                baseBarColor: Colors.white24,
                bufferedBarColor: Colors.white38,
                timeLabelTextStyle: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
                onSeek: (d) => GetIt.I<MediaPlayer>().player.seek(d),
              ),
            ),
            // Transport controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Shuffle
                ValueListenableBuilder(
                  valueListenable: GetIt.I<MediaPlayer>().loopMode,
                  builder: (_, __, ___) => IconButton(
                    onPressed: () {
                      final mp = GetIt.I<MediaPlayer>();
                      mp.player.setShuffleModeEnabled(!mp.shuffleModeEnabled);
                    },
                    icon: Icon(
                      GetIt.I<MediaPlayer>().shuffleModeEnabled
                          ? Icons.shuffle_on_rounded
                          : Icons.shuffle_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
                // Previous
                IconButton(
                  icon: const Icon(
                    Icons.skip_previous_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                  onPressed: () =>
                      GetIt.I<MediaPlayer>().player.seekToPrevious(),
                ),
                // Play/pause
                const PlayPauseButton(size: 30),
                // Next
                IconButton(
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                  onPressed: () => GetIt.I<MediaPlayer>().player.seekToNext(),
                ),
                // Loop
                ValueListenableBuilder(
                  valueListenable: GetIt.I<MediaPlayer>().loopMode,
                  builder: (_, loopMode, __) => IconButton(
                    onPressed: () => GetIt.I<MediaPlayer>().changeLoopMode(),
                    icon: Icon(
                      loopMode == LoopMode.one
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                      color: loopMode != LoopMode.off
                          ? Colors.white
                          : Colors.white54,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
