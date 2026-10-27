import 'dart:async';
import 'dart:ui' show FontFeature, ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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

// =====================================================================
//  واجهة المشغل — مطابقة لتصميم أزرار الويب (index.html)
//  نفس الأيقونات (SVG) ونفس الأحجام والألوان والخط (Cairo)
// =====================================================================

const _vcRed = Color(0xFF8B0000); // --brand-red
const _vcBar = Color(0xFFE50914); // شريط التقدم

// نفس أيقونات الويب بالضبط (الرقم 10 يُرسم كنص فوق الأيقونة)
const Map<String, String> _svg = {
  'play': '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>',
  'pause': '<svg viewBox="0 0 24 24"><path d="M6 5h4v14H6zM14 5h4v14h-4z"/></svg>',
  'fs': '<svg viewBox="0 0 24 24"><path d="M5 5h5v2H7v3H5V5zm9 0h5v5h-2V7h-3V5zM5 14h2v3h3v2H5v-5zm12 0h2v5h-5v-2h3v-3z"/></svg>',
  'fsExit': '<svg viewBox="0 0 24 24"><path d="M8 5v3H5v2h5V5H8zm6 0v5h5V8h-3V5h-2zM5 14v2h3v3h2v-5H5zm9 0v5h2v-3h3v-2h-5z"/></svg>',
  'back10': '<svg viewBox="0 0 24 24"><path d="M12 5V1L7 6l5 5V7a6 6 0 1 1-6 6H4a8 8 0 1 0 8-8z"/></svg>',
  'fwd10': '<svg viewBox="0 0 24 24"><path d="M12 5V1l5 5-5 5V7a6 6 0 1 0 6 6h2a8 8 0 1 1-8-8z"/></svg>',
  'swap': '<svg viewBox="0 0 24 24"><path d="M12 4a8 8 0 0 0-7.7 6h2.1A6 6 0 0 1 12 6c1.7 0 3.2.7 4.2 1.8L14 10h6V4l-2.4 2.4A8 8 0 0 0 12 4zm7.7 10a6 6 0 0 1-10.9 2.2L11 14H5v6l2.4-2.4A8 8 0 0 0 19.7 14z"/></svg>',
  'gear': '<svg viewBox="0 0 24 24"><path d="M19.4 13a7.9 7.9 0 0 0 0-2l2.1-1.6-2-3.5-2.5 1a7.6 7.6 0 0 0-1.7-1L15 3h-4l-.4 2.9a7.6 7.6 0 0 0-1.7 1l-2.5-1-2 3.5L6.6 11a7.9 7.9 0 0 0 0 2l-2.1 1.6 2 3.5 2.5-1a7.6 7.6 0 0 0 1.7 1L11 21h4l.4-2.9a7.6 7.6 0 0 0 1.7-1l2.5 1 2-3.5zM13 15.5A3.5 3.5 0 1 1 13 8.5a3.5 3.5 0 0 1 0 7z"/></svg>',
};

/// أيقونة بيضاء مع ظل خفيف (مثل drop-shadow في الويب)
class _VcIcon extends StatelessWidget {
  final String svg;
  final double size;
  final String? label;
  const _VcIcon(this.svg, this.size, {this.label});

  @override
  Widget build(BuildContext context) {
    Widget glyph(Color c) => SvgPicture.string(svg,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(c, BlendMode.srcIn));
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        Transform.translate(
          offset: const Offset(0, 1),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 1, sigmaY: 1),
            child: Opacity(opacity: 0.8, child: glyph(Colors.black)),
          ),
        ),
        glyph(Colors.white),
        if (label != null)
          Align(
            alignment: const Alignment(0, 0.17),
            child: Text(label!,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 7.5 / 24,
                    fontWeight: FontWeight.w700,
                    height: 1)),
          ),
      ]),
    );
  }
}

/// زر دائري مثل .vc-btn في الويب: 40px (34px على الشاشات الضيقة)،
/// شفاف، ويصبح أحمر عند اللمس، وبـ opacity 35% عند التعطيل
class _VcBtn extends StatefulWidget {
  final String svg;
  final VoidCallback? onTap;
  final double scale;
  final String? label;
  final String? tooltip;
  const _VcBtn({
    required this.svg,
    required this.onTap,
    this.scale = 0.62,
    this.label,
    this.tooltip,
  });

  @override
  State<_VcBtn> createState() => _VcBtnState();
}

class _VcBtnState extends State<_VcBtn> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final d = MediaQuery.of(context).size.width <= 400 ? 34.0 : 40.0;
    final enabled = widget.onTap != null;
    Widget btn = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: d,
        height: d,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _down ? _vcRed : Colors.transparent,
        ),
        child: _VcIcon(widget.svg, d * widget.scale, label: widget.label),
      ),
    );
    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return Opacity(opacity: enabled ? 1 : 0.35, child: btn);
  }
}

/// واجهة عرض الفيديو مع أزرار التحكم
class StreamView extends StatefulWidget {
  final StreamController2 ctrl;
  final String title;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  const StreamView({
    super.key,
    required this.ctrl,
    required this.title,
    required this.fullscreen,
    required this.onFullscreen,
  });

  @override
  State<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends State<StreamView> {
  bool _visible = true;
  bool _menu = false; // قائمة الجودة
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
    _timer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && ctrl.status == PlayStatus.playing && !ctrl.paused && !_menu) {
        setState(() => _visible = false);
      }
    });
  }

  // لمس الفيديو: إظهار / إخفاء الأزرار (وإغلاق القائمة إن كانت مفتوحة)
  void _onVideoTap() {
    if (_menu) {
      setState(() {
        _menu = false;
        _visible = true;
      });
      _restartTimer();
      return;
    }
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
      child: LayoutBuilder(builder: (context, box) {
        final upper = (box.maxHeight - 90).clamp(0.0, double.infinity).toDouble();
        final menuMaxH = (box.maxHeight * 0.7).clamp(0.0, upper).toDouble();
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _onVideoTap,
          child: Stack(fit: StackFit.expand, children: [
            _video(),
            if (ctrl.status == PlayStatus.loading)
              const Center(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    color: _vcRed,
                    backgroundColor: Color(0x40FFFFFF),
                  ),
                ),
              ),
            if (ctrl.status == PlayStatus.idle)
              const Center(
                  child: Text('اختر قناة',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            if (ctrl.status != PlayStatus.idle)
              IgnorePointer(
                ignoring: !showControls,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: showControls ? 1 : 0,
                  child: _overlay(playing),
                ),
              ),
            // زر إعادة المحاولة (مثل .retry-btn)
            if (ctrl.status == PlayStatus.error)
              Center(
                child: Material(
                  color: const Color(0xA6000000),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    highlightColor: _vcRed,
                    splashColor: _vcRed,
                    onTap: ctrl.retry,
                    child: const SizedBox(
                      width: 52,
                      height: 52,
                      child: Center(
                        child: Text('↻',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                height: 1)),
                      ),
                    ),
                  ),
                ),
              ),
            // رسالة الحالة (مثل #msg)
            if (ctrl.message.isNotEmpty && ctrl.status != PlayStatus.idle)
              Positioned(
                left: 0,
                right: 0,
                bottom: 78,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * 0.9),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xD9000000),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(ctrl.message,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              shadows: [
                                Shadow(
                                    color: Color(0xE6000000),
                                    blurRadius: 3,
                                    offset: Offset(0, 1))
                              ])),
                    ),
                  ),
                ),
              ),
            // قائمة الجودة (مثل .vc-menu)
            if (_menu && showControls && playing)
              Positioned(bottom: 82, right: 12, child: _menuWidget(menuMaxH)),
          ]),
        );
      }),
    );

    if (widget.fullscreen) return SizedBox.expand(child: body);
    return AspectRatio(aspectRatio: 16 / 9, child: body);
  }

  // ---------- قائمة الجودة ----------
  Widget _menuWidget(double maxH) {
    final items = <MapEntry<int, String>>[
      const MapEntry(-1, 'تلقائي'),
      for (var i = 0; i < ctrl.qualities.length; i++)
        MapEntry(i, ctrl.qualities[i].label),
    ];
    return Container(
      constraints: BoxConstraints(minWidth: 130, maxHeight: maxH),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xF5141414),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final it in items) _menuItem(it)],
          ),
        ),
      ),
    );
  }

  Widget _menuItem(MapEntry<int, String> it) {
    final on = ctrl.quality == it.key;
    return Material(
      color: on ? _vcRed : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: const Color(0xFF2A2A2A),
        onTap: () {
          setState(() => _menu = false);
          ctrl.setQuality(it.key);
          _restartTimer();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(on ? '${it.value} ✓' : it.value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  // ---------- الطبقة العلوية (شريط علوي + أزرار سفلية) ----------
  Widget _overlay(bool playing) {
    final narrow = MediaQuery.of(context).size.width <= 400;
    final gap = narrow ? 3.0 : 6.0;
    final sep = narrow ? 8.0 : 14.0;

    final controls = <Widget>[
      _VcBtn(
        svg: _svg['back10']!,
        label: '10',
        onTap: ctrl.canSeek
            ? () => _touch(() => ctrl.seekBy(const Duration(seconds: -10)))
            : null,
      ),
      _VcBtn(
        svg: ctrl.paused ? _svg['play']! : _svg['pause']!,
        scale: 0.74,
        onTap: playing ? () => _touch(ctrl.togglePlay) : null,
      ),
      _VcBtn(
        svg: _svg['fwd10']!,
        label: '10',
        onTap: ctrl.canSeek
            ? () => _touch(() => ctrl.seekBy(const Duration(seconds: 10)))
            : null,
      ),
      SizedBox(width: sep),
      _VcBtn(
        svg: _svg['swap']!,
        tooltip: 'تبديل المشغل',
        onTap: () => _touch(ctrl.toggleEngine),
      ),
      _VcBtn(
        svg: _svg['gear']!,
        onTap: () => _touch(() => setState(() => _menu = !_menu)),
      ),
      _VcBtn(
        svg: widget.fullscreen ? _svg['fsExit']! : _svg['fs']!,
        onTap: () => _touch(widget.onFullscreen),
      ),
    ];
    final row = <Widget>[];
    for (var i = 0; i < controls.length; i++) {
      if (i > 0) row.add(SizedBox(width: gap));
      row.add(controls[i]);
    }

    return Stack(fit: StackFit.expand, children: [
      // الشريط العلوي: مباشر + اسم القناة
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 22),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xD9000000), Colors.transparent],
            ),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _vcRed,
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
                      fontWeight: FontWeight.w900,
                      shadows: [
                        Shadow(
                            color: Colors.black,
                            blurRadius: 3,
                            offset: Offset(0, 1))
                      ])),
            ),
          ]),
        ),
      ),
      // الشريط السفلي: الأزرار + شريط التقدم
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            padding: const EdgeInsets.only(top: 26),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xD9000000), Colors.transparent],
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: row,
                ),
              ),
              if (ctrl.canSeek)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  child: _progress(),
                ),
            ]),
          ),
        ),
      ),
    ]);
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
        fontFeatures: [FontFeature.tabularFigures()],
        shadows: [Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1))]);

    Widget time(Duration d) => ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 38),
          child: Text(_fmt(d), textAlign: TextAlign.center, style: labelStyle),
        );

    return Row(children: [
      time(shown),
      const SizedBox(width: 8),
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
              height: 22,
              child: Stack(alignment: Alignment.centerLeft, children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: const Color(0x4DFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  height: 3,
                  width: w * frac,
                  decoration: BoxDecoration(
                    color: _vcBar,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Positioned(
                  left: w * frac - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                        color: _vcBar, shape: BoxShape.circle),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
      const SizedBox(width: 8),
      time(total),
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
