import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

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
  final text = await rootBundle.loadString('assets/channels.json');
  final list = jsonDecode(text) as List;
  return list.map((e) => Channel(e['name'], e['url'])).toList();
}

void main() => runApp(const AlfahamApp());

class AlfahamApp extends StatelessWidget {
  const AlfahamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'الفحام سات',
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
  bool primary = true; // الرئيسي ExoPlayer / الاحتياطي MPV (الخطوة 2)

  @override
  void initState() {
    super.initState();
    loadChannels().then((c) => setState(() => channels = c));
  }

  void select(int i) => setState(() => current = i);

  void openMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardBg,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('☰ قائمة القنوات',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('إغلاق ✕')),
              ],
            ),
          ),
          Expanded(child: channelList(closeOnTap: true)),
        ]),
      ),
    );
  }

  Widget channelList({bool closeOnTap = false}) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: channels.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final active = i == current;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            select(i);
            if (closeOnTap) Navigator.pop(context);
          },
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

  Widget modeButton(String label, bool isPrimary) {
    final active = primary == isPrimary;
    return ElevatedButton(
      onPressed: () => setState(() => primary = isPrimary),
      style: ElevatedButton.styleFrom(
        backgroundColor: active ? brandRed : const Color(0xFF2A2A2A),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
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
          // المشغل (مكان مؤقت للخطوة 2)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: Text(
                current < 0 ? 'اختر قناة' : channels[current].name,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          // شريط الأزرار
          Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cardBg,
              border: Border.all(color: cardBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                modeButton('المشغل الرئيسي', true),
                modeButton('المشغل الاحتياطي', false),
                ElevatedButton(
                  onPressed: openMenu,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2A2A2A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('☰ قائمة القنوات',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          // كروت القنوات
          Expanded(child: channelList()),
        ]),
      ),
    );
  }
}
