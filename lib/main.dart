import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'stream_player.dart';

const brandRed = Color(0xFF8B0000);
const brandBg = Color(0xFF0F0F0F);
const cardBg = Color(0xFF1C1C1C);
const cardBorder = Color(0xFF2A2A2A);

class Channel {
  final String name;
  final String url;
  Channel(this.name, this.url);
}

Future<List<Channel>> loadChannels() async {
  final text = await rootBundle.loadString('assets/channels.txt');
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final out = <Channel>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    out.add(Channel(lines[i], lines[i + 1]));
  }
  return out;
}

/// رابط القنوات التلقائية (يحدّثه السكربت). عدّل اسم الحساب/الريبو إذا اختلف.
const autoChannelsUrl =
    'https://raw.githubusercontent.com/afm80/sat/main/assets/auto_channels.json';

/// القنوات التلقائية: من الإنترنت أولاً (محدّثة)، وإن تعذر فمن النسخة المدمجة.
Future<List<Channel>> loadAutoChannels() async {
  String? text;
  try {
    final r = await http
        .get(Uri.parse(autoChannelsUrl))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 200) text = utf8.decode(r.bodyBytes);
  } catch (_) {}
  if (text == null) {
    try {
      text = await rootBundle.loadString('assets/auto_channels.json');
    } catch (_) {
      return [];
    }
  }
  try {
    final list = jsonDecode(text ?? '[]') as List;
    return list
        .map((e) => Channel('${e['name']}', '${e['url']}'))
        .where((c) => c.name.isNotEmpty && c.url.startsWith('http'))
        .toList();
  } catch (_) {
    return [];
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const AlfahamApp());
}

/// نفس خط الويب: Cairo
ThemeData _buildTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    scaffoldBackgroundColor: brandBg,
    textTheme: GoogleFonts.cairoTextTheme(base.textTheme),
    primaryTextTheme: GoogleFonts.cairoTextTheme(base.primaryTextTheme),
  );
}

class AlfahamApp extends StatelessWidget {
  const AlfahamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alfaham Sat',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _buildTheme(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Channel> channels = []; // يدوية
  List<Channel> autoChannels = []; // تلقائية (تظهر تحت اليدوية)
  List<Channel> get allChannels => [...channels, ...autoChannels];
  int current = -1;
  bool fullscreen = false;
  final ctrl = StreamController2();

  @override
  void initState() {
    super.initState();
    loadChannels().then((c) => setState(() => channels = c));
    loadAutoChannels().then((c) {
      if (mounted) setState(() => autoChannels = c);
    });
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    ctrl.dispose();
    super.dispose();
  }

  void toggleFullscreen() {
    setState(() => fullscreen = !fullscreen);
    if (fullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // السماح بالتدوير التلقائي مجدداً بعد الرجوع
      Future.delayed(const Duration(milliseconds: 600), () {
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      });
    }
  }

  void select(int i) {
    setState(() => current = i);
    ctrl.play(allChannels[i].url);
  }

  /// قائمة القنوات: اليدوية أولاً ثم التلقائية تحتها بعنوان فاصل
  Widget channelList() {
    final all = allChannels;
    final hasAuto = autoChannels.isNotEmpty;
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: all.length + (hasAuto ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, pos) {
        // عنوان القسم التلقائي
        if (hasAuto && pos == channels.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Row(children: [
              const Expanded(child: Divider(color: cardBorder)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'قنوات إضافية (تحديث تلقائي)',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF9A9A9A),
                  ),
                ),
              ),
              const Expanded(child: Divider(color: cardBorder)),
            ]),
          );
        }
        final i = (hasAuto && pos > channels.length) ? pos - 1 : pos;
        final active = i == current;
        return Material(
          color: active ? brandRed : cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: active ? brandRed : cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            hoverColor: const Color(0xFF2A2A2A),
            onTap: () => select(i),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${i + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: active ? Colors.white : const Color(0xFF9A9A9A),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      all[i].name,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: active ? Colors.white : const Color(0xFFF1F1F1),
                        fontWeight: active ? FontWeight.w900 : FontWeight.w700,
                        shadows: const [
                          Shadow(
                              color: Color(0xE6000000),
                              blurRadius: 3,
                              offset: Offset(0, 1)),
                        ],
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = allChannels;
    final title =
        (current >= 0 && current < all.length) ? all[current].name : '';

    Widget player() => StreamView(
          ctrl: ctrl,
          title: title,
          fullscreen: fullscreen,
          onFullscreen: toggleFullscreen,
        );

    return PopScope(
      canPop: !fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && fullscreen) toggleFullscreen();
      },
      child: Scaffold(
        body: fullscreen
            ? AnimatedBuilder(animation: ctrl, builder: (_, __) => player())
            : SafeArea(
                child: Column(children: [
                  // الهيدر
                  Container(
                    height: 52,
                    width: double.infinity,
                    color: brandBg,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                    // نفس شعار الويب (من الرابط نفسه)، ويرجع للشعار المحلي إذا لم يتوفر الإنترنت
                    child: Image.network(
                      'https://raw.githubusercontent.com/afm80/img/refs/heads/main/Alfaham%20sat.png',
                      height: 40,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Image.asset(
                        'assets/logo.png',
                        height: 40,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  Container(
                    height: 3,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          colors: [Colors.transparent, brandRed, Colors.transparent]),
                    ),
                  ),
                  // المشغل ثابت (لا يتحرك مع تمرير القنوات)
                  AnimatedBuilder(
                    animation: ctrl,
                    builder: (_, __) => player(),
                  ),
                  const SizedBox(height: 4),
                  // كروت القنوات: هي فقط التي تتمرر عمودياً
                  Expanded(child: channelList()),
                ]),
              ),
      ),
    );
  }
}
