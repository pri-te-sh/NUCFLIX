# Renders the NUCFLIX wordmark launcher art (banner + icon) into res/drawable-xhdpi.
# Usage: python3 tools/make-logos.py   (needs Pillow; font is web/fonts/BebasNeue-Regular.ttf)
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, 'web', 'fonts', 'BebasNeue-Regular.ttf')
RED = (229, 9, 20, 255)
WORD = 'NUCFLIX'

def wordmark(height):
    """Letters get taller towards the ends, giving the curved 'smile' of a Netflix-style wordmark."""
    font = ImageFont.truetype(FONT, height)
    glyphs = []
    n = len(WORD)
    for i, ch in enumerate(WORD):
        l, t, r, b = font.getbbox(ch)
        g = Image.new('RGBA', (r - l + 2, b - t + 2), (0, 0, 0, 0))
        ImageDraw.Draw(g).text((-l + 1, -t + 1), ch, font=font, fill=RED)
        d = (i - (n - 1) / 2) / ((n - 1) / 2)
        scale = 1 + 0.17 * d * d
        g = g.resize((g.width, round(g.height * scale)), Image.LANCZOS)
        glyphs.append(g)
    gap = round(height * 0.035)
    w = sum(g.width for g in glyphs) + gap * (n - 1)
    h = max(g.height for g in glyphs)
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    x = 0
    for g in glyphs:
        out.alpha_composite(g, (x, (h - g.height) // 2))
        x += g.width + gap
    return out

def tile(size, word_h, radius=0):
    img = Image.new('RGBA', size, (0, 0, 0, 0))
    bg = Image.new('RGBA', size, (8, 8, 10, 255))
    mask = Image.new('L', size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    img.paste(bg, (0, 0), mask)
    wm = wordmark(word_h)
    if wm.width > size[0] * 0.86:
        wm = wm.resize((round(size[0] * 0.86), round(wm.height * size[0] * 0.86 / wm.width)), Image.LANCZOS)
    shadow = Image.new('RGBA', wm.size, (0, 0, 0, 0))
    shadow.putalpha(wm.getchannel('A').point(lambda a: a * 0.7))
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(2, word_h // 30)))
    x, y = (size[0] - wm.width) // 2, (size[1] - wm.height) // 2
    img.alpha_composite(shadow, (x, y + max(2, word_h // 40)))
    img.alpha_composite(wm, (x, y))
    return img

out = os.path.join(ROOT, 'res', 'drawable-xhdpi')
os.makedirs(out, exist_ok=True)
tile((640, 360), 190).save(os.path.join(out, 'banner.png'))
tile((216, 216), 80, radius=48).save(os.path.join(out, 'ic_launcher.png'))
print('wrote', out)
