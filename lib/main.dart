import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const AlfahamApp());
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
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: brandBg),
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
  List<Channel> channels = [];
  int current = -1;
  bool fullscreen = false;
  final ctrl = StreamController2();

  @override
  void initState() {
    super.initState();
    loadChannels().then((c) => setState(() => channels = c));
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
    ctrl.play(channels[i].url);
  }

  void openQuality() {
    showModalBottomSheet(
      context: context,
      backgroundColor: cardBg,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('الجودة',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          ),
          _qualityTile('تلقائي', -1),
          for (var i = 0; i < ctrl.qualities.length; i++)
            _qualityTile(ctrl.qualities[i].label, i),
        ]),
      ),
    );
  }

  Widget _qualityTile(String label, int index) {
    final active = ctrl.quality == index;
    return ListTile(
      title: Text(label),
      trailing: active ? const Icon(Icons.check, color: brandRed) : null,
      onTap: () {
        Navigator.pop(context);
        ctrl.setQuality(index);
      },
    );
  }

  /// قائمة القنوات: تمرير عمودي، والمشغل ثابت في الأعلى
  Widget channelList() {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: channels.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final active = i == current;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => select(i),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: active ? brandRed : cardBg,
              border: Border.all(color: active ? brandRed : cardBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(channels[i].name,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w900 : FontWeight.w700)),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = (current >= 0 && current < channels.length)
        ? channels[current].name
        : '';

    Widget player() => StreamView(
          ctrl: ctrl,
          title: title,
          fullscreen: fullscreen,
          onFullscreen: toggleFullscreen,
          onQuality: openQuality,
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
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Image.asset('assets/logo.png'),
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
                    builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
                      player(),
                      if (ctrl.message.isNotEmpty &&
                          ctrl.status != PlayStatus.error)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(ctrl.message,
                              style: const TextStyle(fontSize: 13)),
                        ),
                    ]),
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
