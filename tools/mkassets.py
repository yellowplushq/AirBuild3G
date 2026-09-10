#!/usr/bin/env python3
"""Generate the iOS 4-era bundle artwork into Resources/.

Icon.png / Icon@2x.png / Icon-Small.png derive from the current AirBuild
AppIcon.icon (its blue gradient fill and white "Subtract" glyph), pre-rendered
the iOS 4 way — rounded corners and the top gloss baked in, UIPrerenderedIcon
set — because SpringBoard on 4.2.1 custom firmware does not mask third-party icons
reliably. Default.png / Default@2x.png reproduce the empty
navigation bar over the grouped-table pinstripes so launch looks like the app
loading instead of a splash screen, which is what the iOS 4 HIG asks for.
"""
import os
import subprocess
import sys
import tempfile
from PIL import Image, ImageDraw, ImageFilter

TOOLS = os.path.dirname(os.path.abspath(__file__))
GLYPH_SVG = os.path.join(TOOLS, "AirBuildGlyph.svg")  # the AirBuild mark, traced to a single path

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources")


def lerp(a, b, t):
	return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(img, box, top, bottom):
	d = ImageDraw.Draw(img)
	x0, y0, x1, y1 = box
	for y in range(y0, y1):
		d.line([(x0, y), (x1, y)], fill=lerp(top, bottom, (y - y0) / max(1, y1 - y0 - 1)))


def glyph(size):
	"""Rasterise the AirBuild glyph white at `size` px square via rsvg-convert."""
	with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
		path = tmp.name
	subprocess.check_call(["rsvg-convert", "-w", str(size), "-h", str(size), "-o", path, GLYPH_SVG])
	alpha = Image.open(path).convert("RGBA").split()[3]
	os.unlink(path)
	white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
	white.putalpha(alpha)
	return white


def icon(size):
	# Render at 8x and downsample so the corners and glyph edges stay clean.
	s = size * 8
	img = Image.new("RGB", (s, s))
	vertical_gradient(img, (0, 0, s, s), (4, 51, 255), (0, 136, 255))
	g = glyph(int(s * 0.62))
	offset = ((s - g.size[0]) // 2, (s - g.size[1]) // 2)
	shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
	shadow.paste((0, 30, 120, 110), (offset[0], offset[1] + s // 60), g.split()[3])
	shadow = shadow.filter(ImageFilter.GaussianBlur(s / 80))
	img = Image.alpha_composite(img.convert("RGBA"), shadow)
	img.paste(g, offset, g)
	# iOS 4 gloss: a bright ellipse clipped to the top half of the icon.
	gloss = Image.new("L", (s, s), 0)
	ImageDraw.Draw(gloss).ellipse([-s * 0.2, -s * 0.9, s * 1.2, s * 0.5], fill=255)
	gloss = Image.merge("RGBA", (Image.new("L", (s, s), 255),) * 3 + (gloss.point(lambda v: int(v * 0.28)),))
	img = Image.alpha_composite(img, gloss)
	# Rounded corners, the iOS 4 radius (10/57 of the side).
	mask = Image.new("L", (s, s), 0)
	ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 10 / 57), fill=255)
	img.putalpha(mask)
	return img.resize((size, size), Image.LANCZOS)


def launch(scale):
	w, h = 320 * scale, 480 * scale
	img = Image.new("RGB", (w, h), (197, 204, 211))
	d = ImageDraw.Draw(img)
	# Status bar: iOS 4 default (black gradient) style.
	vertical_gradient(img, (0, 0, w, 20 * scale), (74, 74, 74), (0, 0, 0))
	# Navigation bar: the stock blue tint with its top highlight and bottom rule.
	vertical_gradient(img, (0, 20 * scale, w, 42 * scale), (163, 188, 224), (112, 149, 204))
	vertical_gradient(img, (0, 42 * scale, w, 64 * scale), (95, 134, 193), (74, 111, 170))
	d.line([(0, 20 * scale), (w, 20 * scale)], fill=(210, 224, 245), width=scale)
	d.line([(0, 64 * scale - scale), (w, 64 * scale - scale)], fill=(42, 68, 116), width=scale)
	# Grouped table pinstripes: 7pt period, one lighter line.
	for y in range(64 * scale, h, 7 * scale):
		d.line([(0, y), (w, y)], fill=(206, 212, 218), width=scale)
	return img


def bar_glyph(draw_fn, size=20):
	"""A navigation-bar glyph: iOS 4 takes the image's alpha as a mask and
	draws it in the bar's own white, so only the shape matters. Drawn at 8x on
	an L mask and downsampled so the edges stay clean at 20 px."""
	s = size * 8
	mask = Image.new("L", (s, s), 0)
	draw_fn(ImageDraw.Draw(mask), s)
	mask = mask.resize((size, size), Image.LANCZOS)
	out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
	out.putalpha(mask)
	return out


def gear(d, s):
	import math
	c = s / 2
	teeth, outer, inner, hole = 6, s * 0.46, s * 0.29, s * 0.12
	# Six deep, narrow teeth as rotated bars, the wheel as a disc, the hub
	# punched out. Fewer, deeper and narrower than a drawn gear: at 20 px,
	# teeth that take more than a third of the rim blur into a disc.
	for i in range(teeth):
		a = i * math.pi / teeth
		dx, dy = math.cos(a), math.sin(a)
		w = s * 0.08
		pts = [(c + dx * outer - dy * w, c + dy * outer + dx * w),
		       (c + dx * outer + dy * w, c + dy * outer - dx * w),
		       (c - dx * outer + dy * w, c - dy * outer - dx * w),
		       (c - dx * outer - dy * w, c - dy * outer + dx * w)]
		d.polygon(pts, fill=255)
	d.ellipse((c - inner, c - inner, c + inner, c + inner), fill=255)
	d.ellipse((c - hole, c - hole, c + hole, c + hole), fill=0)


def bubble(d, s):
	# A speech bubble: rounded body with a tail at the bottom left.
	body = (s * 0.05, s * 0.12, s * 0.95, s * 0.72)
	d.rounded_rectangle(body, radius=s * 0.18, fill=255)
	d.polygon([(s * 0.22, s * 0.66), (s * 0.42, s * 0.66), (s * 0.18, s * 0.92)], fill=255)


def plus(d, s):
	t = s * 0.14
	c = s / 2
	d.rectangle((c - t / 2, s * 0.12, c + t / 2, s * 0.88), fill=255)
	d.rectangle((s * 0.12, c - t / 2, s * 0.88, c + t / 2), fill=255)


def main():
	os.makedirs(OUT, exist_ok=True)
	icon(57).save(os.path.join(OUT, "Icon.png"))
	icon(114).save(os.path.join(OUT, "Icon@2x.png"))
	icon(29).save(os.path.join(OUT, "Icon-Small.png"))
	launch(1).save(os.path.join(OUT, "Default.png"))
	launch(2).save(os.path.join(OUT, "Default@2x.png"))
	bar_glyph(gear).save(os.path.join(OUT, "BarGear.png"))
	bar_glyph(bubble).save(os.path.join(OUT, "BarChat.png"))
	bar_glyph(plus).save(os.path.join(OUT, "BarPlus.png"))
	print("wrote artwork to", OUT)


if __name__ == "__main__":
	sys.exit(main())
