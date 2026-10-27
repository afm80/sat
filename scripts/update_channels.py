#!/usr/bin/env python3
"""
جلب قنوات تلقائية من مصادر M3U وكتابتها في assets/auto_channels.json

- لا يلمس القنوات اليدوية (assets/channels.txt) ولا القائمة داخل index.html أبداً.
- يكتب فقط في assets/auto_channels.json
- يحذف أي قناة تلقائية تكرر قناة يدوية (نفس الرابط أو نفس الاسم).
- يفحص الروابط ويستبعد الميت منها.
- إذا فشلت كل المصادر أو خرجت النتيجة فارغة لا يستبدل الملف القديم.

للتشغيل يدوياً:  python3 scripts/update_channels.py
"""
import argparse
import concurrent.futures as cf
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANUAL_FILE = ROOT / "assets" / "channels.txt"
OUT_FILE = ROOT / "assets" / "auto_channels.json"

# ===================== الإعدادات (عدّل هنا) =====================
# كلمات الرياضة (تُستخدم لفصل القنوات الرياضية عن العربية العامة)
SPORT_KW = [
    "sport", "sports", "bein", "ssc", "alkass", "kass", "espn", "eurosport",
    "dazn", "red bull", "fox sports", "sky sports", "tnt sports", "supersport",
    "nba", "nfl", "ufc", "wwe", "f1", "motorsport", "golf", "tennis",
    "الرياضية", "رياضة", "رياضي", "الكأس", "كاس",
]

# ترتيب المصادر = ترتيب ظهور الأقسام. أول قسم يأخذ القناة إذا تكررت.
#   group   : عنوان القسم الظاهر في التطبيق والويب
#   include : (اختياري) اقبل فقط الأسماء التي تحتوي إحدى هذه الكلمات
#   exclude : (اختياري) استبعد الأسماء التي تحتوي إحدى هذه الكلمات
#   limit   : (اختياري) أقصى عدد قنوات من هذا القسم
SOURCES = [
    {"url": "https://iptv-org.github.io/iptv/countries/iq.m3u",
     "group": "قنوات عراقية", "exclude": SPORT_KW},
    {"url": "https://iptv-org.github.io/iptv/languages/ara.m3u",
     "group": "قنوات عربية", "exclude": SPORT_KW},

    {"url": "https://iptv-org.github.io/iptv/languages/ara.m3u",
     "group": "قنوات رياضية", "include": SPORT_KW},
    {"url": "https://iptv-org.github.io/iptv/categories/sports.m3u",
     "group": "قنوات رياضية", "include": SPORT_KW, "limit": 80},

    {"url": "https://iptv-org.github.io/iptv/categories/news.m3u",
     "group": "قنوات عالمية",
     "include": ["bbc", "cnn", "al jazeera", "aljazeera", "france 24", "france24",
                 "dw", "sky news", "euronews", "rt", "nhk", "bloomberg", "cnbc",
                 "cgtn", "trt world", "i24news", "abc news", "cbs news", "nbc news",
                 "fox news", "wion", "arirang", "al arabiya", "alarabiya", "alhurra"]},
    {"url": "https://iptv-org.github.io/iptv/categories/documentary.m3u",
     "group": "قنوات عالمية",
     "include": ["national geographic", "nat geo", "discovery", "animal planet",
                 "history", "bbc earth", "travel", "dmax"]},
]
ONLY_M3U8 = True        # اقبل روابط .m3u8 فقط (الأنسب لمشغل الويب والتطبيق)
CHECK_LINKS = True      # افحص أن الرابط يعمل قبل إضافته
TIMEOUT = 10            # مهلة فحص كل رابط (ثواني)
WORKERS = 60            # عدد الفحوصات المتوازية
MAX_CHANNELS = 0        # 0 = بدون حد أعلى كلي
DEFAULT_GROUP = "قنوات إضافية (تحديث تلقائي)"
# ================================================================

UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"


def fetch_text(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def clean_name(name):
    name = re.sub(r"\[[^\]]*\]", "", name)            # [Not 24/7] ...
    name = re.sub(r"\(\s*\d{3,4}[pi]\s*\)", "", name)  # (720p)
    return re.sub(r"\s+", " ", name).strip()


def norm_name(name):
    return re.sub(r"[\W_]+", "", name, flags=re.UNICODE).lower()


def kw_match(name, keywords):
    n = name.lower()
    return any(re.search(r"(?<!\w)" + re.escape(k.lower()) + r"(?!\w)", n) for k in keywords)


def parse_m3u(text):
    """يرجع قائمة (name, url) ويتجاهل القنوات التي تحتاج Referer/User-Agent خاص."""
    out = []
    name = None
    needs_headers = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#EXTINF"):
            name = line.rsplit(",", 1)[-1] if "," in line else ""
            needs_headers = False
        elif line.startswith("#EXTVLCOPT"):
            low = line.lower()
            if "http-referrer" in low or "http-user-agent" in low or "http-origin" in low:
                needs_headers = True
        elif line.startswith("#"):
            continue
        elif line.lower().startswith("http"):
            if name is not None and not needs_headers:
                out.append((clean_name(name), line))
            name = None
            needs_headers = False
    return out


def link_alive(url):
    for _ in range(2):  # محاولتان
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                if r.status != 200:
                    continue
                head = r.read(4096)
                if b"#EXTM3U" in head:
                    return True
        except Exception:
            pass
    return False


def load_manual():
    urls, names = set(), set()
    if MANUAL_FILE.exists():
        lines = [l.strip() for l in MANUAL_FILE.read_text(encoding="utf-8").splitlines() if l.strip()]
        for i in range(0, len(lines) - 1, 2):
            names.add(norm_name(lines[i]))
            urls.add(lines[i + 1])
    return urls, names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", action="append", help="رابط M3U (يمكن تكراره) بدل المصادر الافتراضية")
    ap.add_argument("--no-check", action="store_true", help="تخطي فحص الروابط")
    args = ap.parse_args()

    if args.source:
        sources = [{"url": u, "group": DEFAULT_GROUP} for u in args.source]
    else:
        sources = SOURCES
    check = CHECK_LINKS and not args.no_check

    manual_urls, manual_names = load_manual()
    print(f"القنوات اليدوية: {len(manual_urls)} (لن تتغير)")

    cache = {}  # لا نحمّل نفس المصدر مرتين
    raw = []    # (name, url, group)
    ok_sources = 0
    for src in sources:
        url = src["url"]
        try:
            if url not in cache:
                cache[url] = parse_m3u(fetch_text(url))
            items = cache[url]
            inc, exc = src.get("include"), src.get("exclude")
            picked = [(n, u) for n, u in items
                      if (not inc or kw_match(n, inc)) and not (exc and kw_match(n, exc))]
            print(f"[مصدر] {src.get('group')}: {url} -> {len(picked)} من {len(items)}")
            ok_sources += 1
            if src.get("limit"):
                picked = picked[: src["limit"]]
            raw.extend((n, u, src.get("group", DEFAULT_GROUP)) for n, u in picked)
        except Exception as e:
            print(f"[فشل] {url}: {e}", file=sys.stderr)

    if ok_sources == 0:
        print("فشلت كل المصادر، لن يتم تعديل الملف.", file=sys.stderr)
        return 1

    # ترشيح أولي + إزالة التكرار
    candidates, seen_urls = [], set()
    for name, url, group in raw:
        if not name or not url:
            continue
        if ONLY_M3U8 and ".m3u8" not in url.lower():
            continue
        if url in manual_urls or url in seen_urls:
            continue
        if norm_name(name) in manual_names:
            continue
        seen_urls.add(url)
        candidates.append((name, url, group))
    print(f"مرشّحة للفحص: {len(candidates)}")

    # فحص الروابط (مع الحفاظ على الترتيب)
    if check:
        with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            alive = list(ex.map(lambda c: link_alive(c[1]), candidates))
        candidates = [c for c, ok in zip(candidates, alive) if ok]
        print(f"تعمل فعلياً: {len(candidates)}")

    # قناة واحدة لكل اسم (أول رابط يعمل)، وتجميع الأقسام بترتيب المصادر
    final, seen_names = [], set()
    for name, url, group in candidates:
        key = norm_name(name)
        if key in seen_names:
            continue
        seen_names.add(key)
        final.append({"name": name, "url": url, "group": group})
    order = []
    for src in sources:
        g = src.get("group", DEFAULT_GROUP)
        if g not in order:
            order.append(g)
    final.sort(key=lambda c: order.index(c["group"]))  # ترتيب مستقر
    if MAX_CHANNELS > 0:
        final = final[:MAX_CHANNELS]

    if not final:
        print("النتيجة فارغة، لن يتم تعديل الملف.", file=sys.stderr)
        return 1

    new_text = json.dumps(final, ensure_ascii=False, indent=1) + "\n"
    old_text = OUT_FILE.read_text(encoding="utf-8") if OUT_FILE.exists() else ""
    if new_text == old_text:
        print("لا تغييرات.")
    else:
        OUT_FILE.write_text(new_text, encoding="utf-8")
        print(f"تم الحفظ: {len(final)} قناة -> {OUT_FILE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
