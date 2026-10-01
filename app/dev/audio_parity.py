#!/usr/bin/env python3
"""The desktop app's sound parity check, web half: serves build/audio_parity (lib/dev/audio_parity.dart)
and runs it in headless Chromium, which renders the office's voices and music with Web Audio's
OfflineAudioContext. Writes test/audio/parity_web.json: name -> mean RMS, peak, spectral centroid and
left/right balance, which test/audio/parity_test.dart compares with the Dart synth's renders.

  flutter build web --release --no-web-resources-cdn -t lib/dev/audio_parity.dart -o build/audio_parity
  python3 dev/audio_parity.py
"""
import functools, http.server, json, os, re, statistics, sys, threading
from playwright.sync_api import sync_playwright

app = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
root = os.path.join(app, 'build', 'audio_parity')
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

handler = functools.partial(Quiet, directory=root)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

lines = []
done = threading.Event()
with sync_playwright() as p:
    exe = os.environ.get('CHROMIUM') or next((os.path.join('/opt/pw-browsers', d, 'chrome-linux', 'chrome') for d in sorted(os.listdir('/opt/pw-browsers'), reverse=True) if d.startswith('chromium-')), None) if os.path.isdir('/opt/pw-browsers') else None
    browser = p.chromium.launch(executable_path=exe, args=['--autoplay-policy=no-user-gesture-required'])
    page = browser.new_page()
    def on_console(m):
        t = m.text
        if t.startswith('CAL'):
            print(t)
        if t.startswith('PARITY'):
            lines.append(t)
            if t == 'PARITY done':
                done.set()
    page.on('console', on_console)
    page.goto(f'http://127.0.0.1:{server.server_port}/')
    page.wait_for_event('console', predicate=lambda m: m.text == 'PARITY done', timeout=600000) if not done.is_set() else None
    browser.close()
server.shutdown()

runs = {}
for t in lines:
    m = re.match(r'PARITY (\S+) left=(\S+) right=(\S+) mono=(\S+) centroid=(\S+) peak=(\S+)', t)
    if m:
        runs.setdefault(m[1], []).append([float(x) for x in m.groups()[1:]])

def mean(name, f):
    return statistics.mean(f(r) for r in runs[name])

# The office's renders all have the room tone under them (OfficeSound.offline starts it): take its
# power away (it's the same in both channels, and noise, so the powers add).
out = {}
for name in runs:
    if name.endswith('~room'):
        continue
    room = name + '~room'
    def less(f):
        return mean(name, f) - (mean(room, f) if room in runs else 0)
    pl = less(lambda r: r[0] ** 2)
    pr = less(lambda r: r[1] ** 2)
    pm = less(lambda r: r[2] ** 2)
    pc = less(lambda r: r[3] * r[2] ** 2)
    out[name] = {
        'rms': max(0, (pl + pr) / 2) ** 0.5,
        'lr': (max(pl, 0) ** 0.5) / max(1e-12, max(pr, 0) ** 0.5),
        'centroid': pc / pm if pm > 0 else 0,
        'peak': mean(name, lambda r: r[4]),
    }
path = os.path.join(app, 'test', 'audio', 'parity_web.json')
with open(path, 'w') as f:
    json.dump(out, f, indent=1, sort_keys=True)
for name, v in out.items():
    print(f"{name:24} rms {v['rms']:.5f}  peak {v['peak']:.3f}  centroid {v['centroid']:7.1f}  lr {v['lr']:.3f}")
print('wrote', path)
