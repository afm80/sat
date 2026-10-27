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
SOURCES = [
    "https://iptv-org.github.io/iptv/countries/iq.m3u",   # قنوات عراقية
    "https://iptv-org.github.io/iptv/languages/ara.m3u",  # قنوات عربية
]
ONLY_M3U8 = True        # اقبل روابط .m3u8 فقط (الأنسب لمشغل الويب والتطبيق)
CHECK_LINKS = True      # افحص أن الرابط يعمل قبل إضافته
TIMEOUT = 10            # مهلة فحص كل رابط (ثواني)
WORKERS = 40            # عدد الفحوصات المتوازية
MAX_CHANNELS = 0        # 0 = بدون حد أعلى
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

    sources = args.source or SOURCES
    check = CHECK_LINKS and not args.no_check

    manual_urls, manual_names = load_manual()
    print(f"القنوات اليدوية: {len(manual_urls)} (لن تتغير)")

    raw = []
    ok_sources = 0
    for src in sources:
        try:
            items = parse_m3u(fetch_text(src))
            print(f"[مصدر] {src} -> {len(items)} قناة")
            raw.extend(items)
            ok_sources += 1
        except Exception as e:
            print(f"[فشل] {src}: {e}", file=sys.stderr)

    if ok_sources == 0:
        print("فشلت كل المصادر، لن يتم تعديل الملف.", file=sys.stderr)
        return 1

    # ترشيح أولي + إزالة التكرار
    candidates, seen_urls = [], set()
    for name, url in raw:
        if not name or not url:
            continue
        if ONLY_M3U8 and ".m3u8" not in url.lower():
            continue
        if url in manual_urls or url in seen_urls:
            continue
        if norm_name(name) in manual_names:
            continue
        seen_urls.add(url)
        candidates.append((name, url))
    print(f"مرشّحة للفحص: {len(candidates)}")

    # فحص الروابط (مع الحفاظ على الترتيب)
    if check:
        with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            alive = list(ex.map(lambda c: link_alive(c[1]), candidates))
        candidates = [c for c, ok in zip(candidates, alive) if ok]
        print(f"تعمل فعلياً: {len(candidates)}")

    # قناة واحدة لكل اسم (أول رابط يعمل)
    final, seen_names = [], set()
    for name, url in candidates:
        key = norm_name(name)
        if key in seen_names:
            continue
        seen_names.add(key)
        final.append({"name": name, "url": url})
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
