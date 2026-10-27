import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

enum Engine { exo, mpv }

enum PlayStatus { idle, loading, playing, error }

class Quality {
  final String label;
  final String url;
  Quality(this.label, this.url);
}

/// يدير المشغلين: ExoPlayer (الرئيسي) ثم MPV (الاحتياطي)
class StreamController2 extends ChangeNotifier {
  Engine engine = Engine.exo;
  PlayStatus status = PlayStatus.idle;
  String message = '';
  List<Quality> qualities = [];
  int quality = -1; // -1 = تلقائي
  bool paused = false;

  VideoPlayerController? exo;
  Player? mpv;
  VideoController? mpvVideo;
  final List<StreamSubscription> _subs = [];

  String? _url;
  int _token = 0;

  String? get currentUrl => _url;

  // ---------- تشغيل قناة جديدة ----------
  Future<void> play(String url) async {
    _url = url;
    quality = -1;
    qualities = [];
    engine = Engine.exo;
    final t = ++_token;
    _loadQualities(url, t);
    await _run(url, t, engine, canFallback: true);
  }

  // ---------- إعادة المحاولة ----------
  Future<void> retry() async {
    final u = _url;
    if (u != null) await play(u);
  }

  // ---------- تبديل المشغل يدوياً ----------
  Future<void> setEngine(Engine e) async {
    final u = _url;
    if (u == null) {
      engine = e;
      notifyListeners();
      return;
    }
    final t = ++_token;
    engine = e;
    await _run(_playUrl(), t, e, canFallback: true);
  }

  // ---------- إيقاف مؤقت / تشغيل ----------
  Future<void> togglePlay() async {
    if (status != PlayStatus.playing) return;
    paused = !paused;
    notifyListeners();
    try {
      if (engine == Engine.exo) {
        paused ? await exo?.pause() : await exo?.play();
      } else {
        paused ? await mpv?.pause() : await mpv?.play();
      }
    } catch (_) {}
  }

  // ---------- الموضع والتقديم / الرجوع ----------
  Duration get position {
    try {
      if (engine == Engine.exo && exo != null) return exo!.value.position;
      if (engine == Engine.mpv && mpv != null) return mpv!.state.position;
    } catch (_) {}
    return Duration.zero;
  }

  Duration get duration {
    try {
      if (engine == Engine.exo && exo != null) return exo!.value.duration;
      if (engine == Engine.mpv && mpv != null) return mpv!.state.duration;
    } catch (_) {}
    return Duration.zero;
  }

  /// هل يمكن التمرير داخل البث (مباشر مع DVR أو ملف)
  bool get canSeek => status == PlayStatus.playing && duration.inSeconds > 2;

  Future<void> seekTo(Duration d) async {
    if (!canSeek) return;
    final max = duration;
    if (d < Duration.zero) d = Duration.zero;
    if (d > max) d = max;
    try {
      if (engine == Engine.exo) {
        await exo?.seekTo(d);
      } else {
        await mpv?.seek(d);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> seekBy(Duration delta) => seekTo(position + delta);

  /// تبديل المشغل (الرئيسي ⇄ الاحتياطي)
  Future<void> toggleEngine() =>
      setEngine(engine == Engine.exo ? Engine.mpv : Engine.exo);

  String get qualityLabel =>
      (quality >= 0 && quality < qualities.length) ? qualities[quality].label : 'تلقائي';

  // ---------- تبديل الجودة ----------
  Future<void> setQuality(int i) async {
    if (_url == null) return;
    quality = i;
    final t = ++_token;
    await _run(_playUrl(), t, engine, canFallback: true);
  }

  String _playUrl() {
    if (quality >= 0 && quality < qualities.length) return qualities[quality].url;
    return _url!;
  }

  // ---------- التشغيل مع الانتقال التلقائي ----------
  Future<void> _run(String url, int t, Engine e,
      {required bool canFallback}) async {
    status = PlayStatus.loading;
    message = '';
    paused = false;
    notifyListeners();
    await _disposeEngines();
    try {
      if (e == Engine.exo) {
        await _startExo(url, t);
      } else {
        await _startMpv(url, t);
      }
      if (t != _token) return;
      status = PlayStatus.playing;
      message = '';
      notifyListeners();
    } catch (_) {
      if (t != _token) return;
      await _fail(url, t, e, canFallback);
    }
  }

  Future<void> _fail(String url, int t, Engine e, bool canFallback) async {
    if (t != _token) return;
    if (canFallback) {
      final other = e == Engine.exo ? Engine.mpv : Engine.exo;
      engine = other;
      await _run(url, t, other, canFallback: false);
      if (t == _token && status == PlayStatus.playing) {
        message = 'تم الانتقال للمشغل ${other == Engine.mpv ? 'الاحتياطي' : 'الرئيسي'}';
        notifyListeners();
      }
    } else {
      await _disposeEngines();
      status = PlayStatus.error;
      message = '⚠ تعذر تشغيل القناة';
      notifyListeners();
    }
  }

  // ---------- ExoPlayer ----------
  Future<void> _startExo(String url, int t) async {
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize().timeout(const Duration(seconds: 20));
    } catch (e) {
      await c.dispose();
      rethrow;
    }
    if (t != _token) {
      await c.dispose();
      return;
    }
    exo = c;
    c.addListener(() {
      if (t == _token && exo == c && c.value.hasError &&
          status == PlayStatus.playing) {
        _fail(url, t, Engine.exo, true);
      }
    });
    await c.play();
  }

  // ---------- MPV ----------
  Future<void> _startMpv(String url, int t) async {
    final p = Player();
    final vc = VideoController(p);
    final done = Completer<void>();
    final subs = <StreamSubscription>[
      p.stream.error.listen((err) {
        if (!done.isCompleted) done.completeError(err);
      }),
      p.stream.width.listen((w) {
        if ((w ?? 0) > 0 && !done.isCompleted) done.complete();
      }),
      p.stream.buffering.listen((b) {
        if (!b && p.state.playing && !done.isCompleted) done.complete();
      }),
    ];
    try {
      await p.open(Media(url));
      await done.future.timeout(const Duration(seconds: 20));
    } catch (e) {
      for (final s in subs) {
        await s.cancel();
      }
      await p.dispose();
      rethrow;
    }
    for (final s in subs) {
      await s.cancel();
    }
    if (t != _token) {
      await p.dispose();
      return;
    }
    mpv = p;
    mpvVideo = vc;
    _subs.add(p.stream.error.listen((_) {
      if (t == _token && mpv == p && status == PlayStatus.playing) {
        _fail(url, t, Engine.mpv, false);
      }
    }));
  }

  // ---------- قراءة الجودات من ملف HLS ----------
  Future<void> _loadQualities(String url, int t) async {
    try {
      if (!url.contains('.m3u8')) return;
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final lines = r.body.split('\n').map((l) => l.trim()).toList();
      final base = Uri.parse(url);
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
        final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(lines[i]);
        final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        var j = i + 1;
        while (j < lines.length && (lines[j].isEmpty || lines[j].startsWith('#'))) {
          j++;
        }
        if (j >= lines.length) continue;
        final height = res != null ? int.parse(res.group(2)!) : 0;
        final bps = bw != null ? int.parse(bw.group(1)!) : 0;
        list.add({
          'h': height,
          'bw': bps,
          'url': base.resolve(lines[j]).toString(),
        });
      }
      if (list.length < 2 || t != _token) return;
      list.sort((a, b) {
        final c = (b['h'] as int).compareTo(a['h'] as int);
        return c != 0 ? c : (b['bw'] as int).compareTo(a['bw'] as int);
      });
      qualities = list.map((m) {
        final h = m['h'] as int;
        final label = h > 0 ? '${h}p' : '${((m['bw'] as int) / 1000).round()} kbps';
        return Quality(label, m['url'] as String);
      }).toList();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _disposeEngines() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final e = exo;
    final p = mpv;
    exo = null;
    mpv = null;
    mpvVideo = null;
    try {
      await e?.dispose();
    } catch (_) {}
    try {
      await p?.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _token++;
    _disposeEngines();
    super.dispose();
  }
}

/// واجهة عرض الفيديو مع أزرار التحكم (تشغيل/إيقاف، الجودة، ملء الشاشة)
class StreamView extends StatefulWidget {
  final StreamController2 ctrl;
  final String title;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final VoidCallback onQuality;
  const StreamView({
    super.key,
    required this.ctrl,
    required this.title,
    required this.fullscreen,
    required this.onFullscreen,
    required this.onQuality,
  });

  @override
  State<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends State<StreamView> {
  bool _visible = true;
  Timer? _timer;
  Timer? _tick;
  bool _dragging = false;
  double _dragFrac = 0;

  @override
  void initState() {
    super.initState();
    // تحديث شريط التقدم
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _visible && !_dragging && ctrl.status == PlayStatus.playing) {
        setState(() {});
      }
    });
  }

  StreamController2 get ctrl => widget.ctrl;

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () {
      if (mounted && ctrl.status == PlayStatus.playing && !ctrl.paused) {
        setState(() => _visible = false);
      }
    });
  }

  void _toggle() {
    setState(() => _visible = !_visible);
    if (_visible) _restartTimer();
  }

  void _touch(VoidCallback action) {
    action();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = ctrl.status == PlayStatus.playing;
    final showControls = _visible || !playing || ctrl.paused;

    final body = Container(
      color: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggle,
        child: Stack(fit: StackFit.expand, children: [
          _video(),
          if (ctrl.status == PlayStatus.loading)
            const Center(
                child: CircularProgressIndicator(color: Color(0xFF8B0000))),
          if (ctrl.status == PlayStatus.idle)
            const Center(child: Text('اختر قناة', style: TextStyle(fontSize: 16))),
          if (ctrl.status == PlayStatus.error)
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(ctrl.message, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                _roundBtn(Icons.refresh, ctrl.retry, size: 44),
              ]),
            ),
          if (ctrl.status != PlayStatus.idle)
            IgnorePointer(
              ignoring: !showControls,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: showControls ? 1 : 0,
                child: _overlay(playing),
              ),
            ),
        ]),
      ),
    );

    if (widget.fullscreen) return SizedBox.expand(child: body);
    return AspectRatio(aspectRatio: 16 / 9, child: body);
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap, {double size = 40}) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.6),
        ),
      ),
    );
  }

  Widget _overlay(bool playing) {
    return Stack(fit: StackFit.expand, children: [
      // شريط علوي: اسم القناة + مباشر
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 18),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF8B0000),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('مباشر',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      ),
      // شريط سفلي: أزرار التحكم + شريط التقدم (مثل مشغل ياسين تيفي)
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 4),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _iconBtn(Icons.replay_10, ctrl.canSeek
                      ? () => _touch(() => ctrl.seekBy(const Duration(seconds: -10)))
                      : null),
                  _iconBtn(
                    ctrl.paused ? Icons.play_arrow : Icons.pause,
                    playing ? () => _touch(ctrl.togglePlay) : null,
                    size: 32,
                  ),
                  _iconBtn(Icons.forward_10, ctrl.canSeek
                      ? () => _touch(() => ctrl.seekBy(const Duration(seconds: 10)))
                      : null),
                  const SizedBox(width: 14),
                  _iconBtn(Icons.sync_alt, () => _touch(ctrl.toggleEngine),
                      tooltip: ctrl.engine == Engine.exo
                          ? 'التبديل للمشغل الاحتياطي'
                          : 'التبديل للمشغل الرئيسي'),
                  _iconBtn(Icons.settings, () => _touch(widget.onQuality)),
                  _iconBtn(
                    widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    () => _touch(widget.onFullscreen),
                  ),
                ],
              ),
              if (ctrl.canSeek) _progress(),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _iconBtn(IconData icon, VoidCallback? onTap,
      {double size = 26, String? tooltip}) {
    final enabled = onTap != null;
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      icon: Icon(icon,
          size: size,
          color: enabled ? Colors.white : Colors.white30,
          shadows: const [Shadow(color: Colors.black87, blurRadius: 4)]),
    );
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Widget _progress() {
    final total = ctrl.duration;
    final totalMs = total.inMilliseconds <= 0 ? 1 : total.inMilliseconds;
    final double frac = _dragging
        ? _dragFrac
        : (ctrl.position.inMilliseconds / totalMs).clamp(0.0, 1.0).toDouble();
    final shown = Duration(milliseconds: (frac * totalMs).round());

    void seekFromDx(double dx, double width) {
      _dragFrac = (dx / width).clamp(0.0, 1.0).toDouble();
      setState(() {});
    }

    const labelStyle = TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        shadows: [Shadow(color: Colors.black87, blurRadius: 3)]);

    return Row(children: [
      SizedBox(
          width: 44,
          child: Text(_fmt(shown), textAlign: TextAlign.center, style: labelStyle)),
      Expanded(
        child: LayoutBuilder(builder: (_, c) {
          final w = c.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final double f = (d.localPosition.dx / w).clamp(0.0, 1.0).toDouble();
              _touch(() => ctrl.seekTo(Duration(milliseconds: (f * totalMs).round())));
            },
            onHorizontalDragStart: (d) {
              _dragging = true;
              seekFromDx(d.localPosition.dx, w);
            },
            onHorizontalDragUpdate: (d) => seekFromDx(d.localPosition.dx, w),
            onHorizontalDragEnd: (_) {
              final f = _dragFrac;
              _dragging = false;
              _touch(() => ctrl.seekTo(Duration(milliseconds: (f * totalMs).round())));
            },
            child: SizedBox(
              height: 24,
              child: Stack(alignment: Alignment.centerLeft, children: [
                Container(height: 3, color: Colors.white30),
                Container(height: 3, width: w * frac, color: const Color(0xFFE50914)),
                Positioned(
                  left: (w * frac - 6).clamp(0.0, w - 12).toDouble(),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                        color: Color(0xFFE50914), shape: BoxShape.circle),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
      SizedBox(
          width: 44,
          child: Text(_fmt(total), textAlign: TextAlign.center, style: labelStyle)),
    ]);
  }

  Widget _video() {
    if (ctrl.exo != null && ctrl.engine == Engine.exo) {
      final c = ctrl.exo!;
      return Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
          child: VideoPlayer(c),
        ),
      );
    }
    if (ctrl.mpvVideo != null && ctrl.engine == Engine.mpv) {
      return Video(controller: ctrl.mpvVideo!, controls: NoVideoControls);
    }
    return const SizedBox.shrink();
  }
}
