#!/usr/bin/env python3
"""Generate the XPAM brand kit (SVG sources). PNG/ICO/ICNS are rendered by make_brand.sh."""
TEAL, TEAL_L, TEAL_D, DARK = "#1ab394", "#3fe6bd", "#12a182", "#0b1823"

def emblem(x_fill, ring, hub_fill, hub_stroke, key, defs=True):
    return f'''
  <circle cx="256" cy="256" r="168" fill="none" stroke="{ring}" stroke-width="14"/>
  <g fill="{ring if ring.startswith('#') else 'currentColor'}">
    <rect x="243" y="50" width="26" height="40" rx="11"/><rect x="243" y="422" width="26" height="40" rx="11"/>
    <rect x="50" y="243" width="40" height="26" rx="11"/><rect x="422" y="243" width="40" height="26" rx="11"/>
  </g>
  <g stroke="{x_fill}" stroke-width="68" stroke-linecap="round">
    <line x1="146" y1="146" x2="366" y2="366"/><line x1="366" y1="146" x2="146" y2="366"/>
  </g>
  <circle cx="256" cy="256" r="58" fill="{hub_fill}" stroke="{hub_stroke}" stroke-width="9"/>
  <circle cx="256" cy="242" r="18" fill="{key}"/><path d="M246 250h20l8 42h-36z" fill="{key}"/>'''

DEFS = f'''<defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#16303f"/><stop offset="1" stop-color="{DARK}"/></linearGradient>
    <linearGradient id="x" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{TEAL_L}"/><stop offset="1" stop-color="{TEAL_D}"/></linearGradient>
  </defs>'''

def icon(pad=0, radius=112):
    s = (512 - 2 * pad) / 480
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="XPAM">
  {DEFS}
  <g transform="translate({pad} {pad}) scale({s}) translate(-16 -16)">
  <rect x="16" y="16" width="480" height="480" rx="{radius}" fill="url(#bg)"/>{emblem("url(#x)", "#1ab39499", DARK, TEAL_L, "#ffffff")}
  </g>
</svg>
'''

# Single-colour mark on a transparent background (headers, tray): hub is cut out with a mask
def mark(color):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 40 432 432" role="img" aria-label="XPAM">
  <defs><mask id="hub"><rect x="0" y="0" width="512" height="512" fill="#fff"/><circle cx="256" cy="256" r="66" fill="#000"/></mask></defs>
  <g mask="url(#hub)" fill="none" stroke="{color}">
    <circle cx="256" cy="256" r="168" stroke-width="14" stroke-opacity=".6"/>
    <g stroke-width="68" stroke-linecap="round"><line x1="146" y1="146" x2="366" y2="366"/><line x1="366" y1="146" x2="146" y2="366"/></g>
  </g>
  <g fill="{color}">
    <rect x="243" y="50" width="26" height="40" rx="11"/><rect x="243" y="422" width="26" height="40" rx="11"/>
    <rect x="50" y="243" width="40" height="26" rx="11"/><rect x="422" y="243" width="40" height="26" rx="11"/>
    <circle cx="256" cy="256" r="52" fill="none" stroke="{color}" stroke-width="9"/>
    <circle cx="256" cy="242" r="18"/><path d="M246 250h20l8 42h-36z"/>
  </g>
</svg>
'''

# Wordmark drawn as strokes, so it does not depend on installed fonts
WORD = '''<g fill="none" stroke="{c}" stroke-width="19" stroke-linecap="round" stroke-linejoin="round" transform="translate({x} {y}) scale({k})">
    <path d="M0 0L70 100M70 0L0 100"/>
    <path d="M108 100V0h36a28 28 0 0 1 0 56h-36"/>
    <path d="M200 100L239 0l39 100M214 66h50"/>
    <path d="M312 100V0l42 60 42-60v100"/>
  </g>'''

def logo_text(text_color, with_icon=True, height=512):
    k = 2.6
    x0 = 600 if with_icon else 30
    width = x0 + int(396 * k) + 60
    body = WORD.format(c=text_color, x=x0, y=(512 - 100 * k) / 2, k=k)
    ic = f'''{DEFS}
  <rect x="16" y="16" width="480" height="480" rx="112" fill="url(#bg)"/>{emblem("url(#x)", "#1ab39499", DARK, TEAL_L, "#ffffff")}''' if with_icon else ''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} 512" role="img" aria-label="XPAM">
  {ic}
  {body}
</svg>
'''

files = {
    "icon.svg": icon(),
    "icon-mac.svg": icon(pad=50, radius=108),
    "mark-teal.svg": mark(TEAL),
    "mark-white.svg": mark("#ffffff"),
    "mark-current.svg": mark("currentColor"),
    "logo-text-white.svg": logo_text("#ffffff"),
    "logo-text-teal.svg": logo_text(TEAL),
    "logo-text-dark.svg": logo_text("#12202b"),
}
for name, content in files.items():
    open(f"out/{name}", "w").write(content)
print("wrote", len(files), "svg files")
