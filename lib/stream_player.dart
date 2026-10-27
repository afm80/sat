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

/// واجهة عرض الفيديو
class StreamView extends StatelessWidget {
  final StreamController2 ctrl;
  const StreamView({super.key, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: Stack(fit: StackFit.expand, children: [
          _video(),
          if (ctrl.status == PlayStatus.loading)
            const Center(child: CircularProgressIndicator(color: Color(0xFF8B0000))),
          if (ctrl.status == PlayStatus.idle)
            const Center(child: Text('اختر قناة', style: TextStyle(fontSize: 16))),
        ]),
      ),
    );
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
