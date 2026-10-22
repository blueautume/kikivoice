#!/usr/bin/env python3
"""Generate KikiTalk's original, deterministic GIF gift collection.

No downloaded artwork, fonts, or generative assets are used. The vector shapes,
particle choreography, gradients, and animation are authored here. Requires Pillow
and numpy. GIFs have a transparent palette entry, disposal=2, and no loop extension
(one play). PNG posters retain full alpha. Frames are rendered in memory only.
"""

from __future__ import annotations

import argparse
from functools import lru_cache
import json
import math
from pathlib import Path
import random

import numpy as np
from PIL import GifImagePlugin, Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ios/KikiTalk/Resources/Gifts"
S = 2
TAU = math.tau
GIF_ALPHA_CUTOFF = 40

GIFTS = [
    {"id": "heart", "name": "初见心动", "price": 1, "width": 192,
     "height": 192, "duration": 1.5, "frameCount": 24, "style": "simple"},
    {"id": "flower_rain", "name": "星光花雨", "price": 99, "width": 256,
     "height": 320, "duration": 2.2, "frameCount": 35, "style": "particles"},
    {"id": "aurora_car", "name": "极光跑车", "price": 999, "width": 320,
     "height": 240, "duration": 2.8, "frameCount": 45, "style": "object"},
    {"id": "galaxy_rocket", "name": "星河火箭", "price": 4999, "width": 320,
     "height": 480, "duration": 3.2, "frameCount": 51, "style": "luxury"},
    {"id": "cosmic_heart", "name": "宇宙之心", "price": 10000, "width": 360,
     "height": 540, "duration": 4.0, "frameCount": 64, "style": "fullscreen"},
]


def color(value, alpha=255):
    if isinstance(value, str):
        value = value.lstrip("#")
        return (*[int(value[i:i + 2], 16) for i in (0, 2, 4)], alpha)
    return (*value[:3], alpha) if len(value) == 3 else value


def ease(t):
    t = max(0, min(1, t))
    return t * t * (3 - 2 * t)


def fade(t, first=.1, last=.88):
    return ease(t / first) * (1 - ease((t - last) / (1 - last)))


def path_points(commands):
    """Flatten a small SVG-like path into antialiased drawing coordinates."""
    points = []
    cursor = (0, 0)
    for cmd in commands:
        op, *v = cmd
        if op in ("M", "L"):
            cursor = tuple(v)
            points.append(cursor)
        elif op == "C":
            x0, y0 = cursor
            x1, y1, x2, y2, x3, y3 = v
            distance = math.hypot(x3 - x0, y3 - y0)
            for t in np.linspace(0, 1, max(14, int(distance / 3)))[1:]:
                z = 1 - t
                points.append((z**3*x0+3*z*z*t*x1+3*z*t*t*x2+t**3*x3,
                               z**3*y0+3*z*z*t*y1+3*z*t*t*y2+t**3*y3))
            cursor = (x3, y3)
        elif op == "Q":
            x0, y0 = cursor
            x1, y1, x2, y2 = v
            for t in np.linspace(0, 1, 22)[1:]:
                z = 1 - t
                points.append((z*z*x0+2*z*t*x1+t*t*x2,
                               z*z*y0+2*z*t*y1+t*t*y2))
            cursor = (x2, y2)
    return [(round(x * S), round(y * S)) for x, y in points]


class Art:
    def __init__(self, width, height):
        self.width, self.height = width, height
        self.image = Image.new("RGBA", (round(width*S), round(height*S)))

    def mask(self, commands=None, ellipse=None, rounded=None):
        mask = Image.new("L", self.image.size)
        d = ImageDraw.Draw(mask)
        if commands:
            d.polygon(path_points(commands), fill=255)
        if ellipse:
            d.ellipse(tuple(round(v*S) for v in ellipse), fill=255)
        if rounded:
            box, r = rounded
            d.rounded_rectangle(tuple(round(v*S) for v in box), round(r*S), fill=255)
        return mask

    def fill(self, mask, stops, horizontal=False, opacity=1):
        if isinstance(stops, str) or (isinstance(stops, tuple) and isinstance(stops[0], int)):
            layer = Image.new("RGBA", self.image.size, color(stops))
        else:
            line = np.linspace(0, 1, self.image.width if horizontal else self.image.height)
            channels = [np.interp(line, [p for p, _ in stops],
                                  [color(c)[i] for _, c in stops]) for i in range(3)]
            rgb = np.stack(channels, axis=-1).astype(np.uint8)
            if horizontal:
                rgb = np.broadcast_to(rgb[None, :, :], (self.image.height, self.image.width, 3))
            else:
                rgb = np.broadcast_to(rgb[:, None, :], (self.image.height, self.image.width, 3))
            layer = Image.fromarray(rgb.copy()).convert("RGBA")
        layer.putalpha(mask.point(lambda a: round(a*opacity)) if opacity != 1 else mask)
        self.image.alpha_composite(layer)

    def glow(self, mask, tint="#a56bff", radius=8, opacity=.55):
        m = mask.filter(ImageFilter.GaussianBlur(radius*S))
        m = m.point(lambda a: round(a*opacity))
        layer = Image.new("RGBA", self.image.size, color(tint))
        layer.putalpha(m)
        self.image.alpha_composite(layer)

    def path(self, commands, fill, stroke=None, width=1, glow=None):
        mask = self.mask(commands)
        if glow:
            self.glow(mask, *glow)
        self.fill(mask, fill)
        if stroke:
            pts = path_points(commands)
            ImageDraw.Draw(self.image).line(pts+[pts[0]], fill=color(stroke),
                                            width=max(1, round(width*S)), joint="curve")

    def line(self, pts, fill, width=1, opacity=1):
        overlay = Image.new("RGBA", self.image.size)
        ImageDraw.Draw(overlay).line([(round(x*S), round(y*S)) for x, y in pts],
                                     fill=color(fill, round(255*opacity)),
                                     width=max(1, round(width*S)), joint="curve")
        self.image.alpha_composite(overlay)

    def ellipse(self, box, fill, stroke=None, width=1, glow=None, opacity=1):
        mask = self.mask(ellipse=box)
        if glow:
            self.glow(mask, *glow)
        self.fill(mask, fill, opacity=opacity)
        if stroke:
            ImageDraw.Draw(self.image).ellipse(tuple(round(v*S) for v in box),
                                               outline=color(stroke), width=round(width*S))

    def sprite(self, sprite, cx, cy, scale=1, angle=0, opacity=1):
        if opacity <= .002 or scale <= .002:
            return
        if scale != 1:
            sprite = sprite.resize((max(1, round(sprite.width*scale)),
                                    max(1, round(sprite.height*scale))), Image.Resampling.LANCZOS)
        if angle:
            sprite = sprite.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
        if opacity < .999:
            sprite = sprite.copy()
            sprite.putalpha(sprite.getchannel("A").point(lambda a: round(a*opacity)))
        self.image.alpha_composite(sprite, (round(cx*S-sprite.width/2), round(cy*S-sprite.height/2)))

    def finished(self):
        return self.image.resize((self.width, self.height), Image.Resampling.LANCZOS)


@lru_cache(maxsize=32)
def star_sprite(size=24, tint="#fff1ac"):
    a = Art(size*2, size*2)
    c, r = size, size*.55
    pts = [(c, c-r), (c+r*.19, c-r*.19), (c+r, c),
           (c+r*.19, c+r*.19), (c, c+r), (c-r*.19, c+r*.19),
           (c-r, c), (c-r*.19, c-r*.19)]
    a.path([("M", *pts[0])]+[("L", *p) for p in pts[1:]], tint,
           glow=(tint, size*.17, .8))
    a.ellipse((c-1.2, c-1.2, c+1.2, c+1.2), "#ffffff")
    return a.image


def sparkle(a, x, y, size, phase, tint="#fff1ac", opacity=1):
    pulse = .48+.52*(math.sin(phase)*.5+.5)
    a.sprite(star_sprite(24, tint), x, y, scale=size/24*pulse, angle=phase*8,
             opacity=opacity)


HEART = [("M", 80, 137), ("C", 64, 124, 20, 96, 19, 60),
         ("C", 17, 29, 53, 14, 80, 46), ("C", 106, 14, 143, 29, 141, 60),
         ("C", 139, 94, 96, 125, 80, 137)]


@lru_cache(maxsize=8)
def heart_sprite(cosmic=False):
    a = Art(160, 160)
    a.path(HEART, [(0, "#ffe6f7"), (.20, "#ffb0ec"), (.45, "#ff61b1"),
                   (.72, "#e42e92"), (1, "#9338e0")],
           stroke="#ffd8f5", width=1.8, glow=("#ec66ef", 8, .62))
    a.path([("M", 80, 128), ("C", 59, 107, 33, 88, 31, 60),
            ("C", 27, 42, 45, 30, 59, 37), ("C", 37, 39, 33, 57, 41, 76),
            ("C", 49, 96, 66, 111, 80, 128)], [(0,"#fff7fe"),(1,"#f885d1")])
    a.path([("M", 84, 53), ("C", 104, 31, 123, 36, 129, 48),
            ("C", 110, 41, 102, 44, 84, 61)], "#ffe3f9")
    a.path([("M", 89, 120), ("C", 109, 104, 129, 83, 132, 64),
            ("C", 138, 88, 112, 113, 89, 120)], "#b631c3")
    a.ellipse((40, 40, 55, 49), "#fff5fe")
    if cosmic:
        # Inner cut-gem facets distinguish the full-screen gift from the small heart.
        a.path([("M",80,51),("L",56,77),("L",80,121),("L",106,77)],
               [(0,"#f2efff"),(.4,"#f5abf4"),(.7,"#a372ff"),(1,"#ff76c7")],
               stroke="#ffe7ff",width=1)
        a.line([(56,77),(106,77)], "#fff3ff", .8)
        a.line([(80,51),(80,121)], "#ffddfa", .8)
        a.line([(64,67),(96,67)], "#fef4ff", .6)
    return a.image


@lru_cache(maxsize=4)
def rose_sprite(tint=0):
    a = Art(112, 112)
    colors = ["#ab2589", "#dd338e", "#f75b9c", "#ff85b8", "#ffc2d6"] if tint == 0 else \
             ["#7739bc", "#a352e0", "#cb7afb", "#e7a9ff", "#f6d3ff"]
    a.path([("M",22,61),("C",7,43,27,25,40,24),("C",50,7,74,15,80,28),
            ("C",105,27,110,56,98,68),("C",104,88,82,104,65,97),
            ("C",45,107,21,91,22,73)],
           [(0,colors[4]),(.28,colors[2]),(.65,colors[1]),(1,colors[0])],
           stroke=colors[3],width=1,glow=(colors[2],4,.4))
    a.path([("M",25,55),("C",27,24,56,25,64,33),("C",50,32,42,43,46,54),
            ("C",38,44,31,47,25,55)],colors[4])
    a.path([("M",65,29),("C",93,25,103,52,88,63),("C",95,42,77,35,65,40)],colors[3])
    a.path([("M",91,66),("C",86,91,62,98,47,82),("C",67,89,77,75,77,67)],colors[2])
    a.path([("M",26,64),("C",35,89,61,81,61,69),("C",46,78,36,67,40,57)],colors[1])
    a.path([("M",43,48),("C",49,32,74,35,80,51),("C",85,68,64,79,53,68),
            ("C",65,71,77,59,68,50),("C",61,42,48,47,51,56)],
           [(0,colors[4]),(.5,colors[3]),(1,colors[0])],stroke=colors[3],width=.6)
    a.path([("M",53,56),("C",50,42,70,43,71,53),("C",73,62,61,68,57,61),
            ("C",65,64,70,54,63,52),("C",58,50,56,53,59,57)],colors[4])
    return a.image


@lru_cache(maxsize=2)
def petal_sprite(tint=0):
    a=Art(40,44)
    a.path([("M",12,35),("C",0,18,10,4,31,8),("C",40,24,29,39,12,35)],
           [(0,"#ffd0ec"),(.5,"#fd80be"),(1,"#cd398e")] if tint == 0 else
           [(0,"#f4d5ff"),(.5,"#d293ff"),(1,"#8f51e7")])
    a.path([("M",12,33),("C",18,28,24,21,29,10),("C",23,26,22,31,12,33)],"#ffe4fa")
    return a.image


@lru_cache(maxsize=1)
def bouquet_sprite():
    a=Art(224,242)
    # Stems and fresh leaves, visible through the translucent-style lilac wrap.
    for x,y in [(69,70),(111,45),(156,75),(88,105),(137,112)]:
        a.line([(x,y),(112,206)],"#62c9aa",3)
    for x,y,side in [(77,128,-1),(141,133,1),(95,154,-1),(132,165,1)]:
        a.path([("M",x,y),("C",x+side*29,y-30,x+side*46,y-25,x+side*38,y-7),
                ("C",x+side*33,y+4,x+side*10,y+6,x,y)],
               [(0,"#bafae0"),(.5,"#51bbab"),(1,"#257c88")])
    a.path([("M",44,103),("L",110,135),("L",183,106),("L",140,207),
            ("Q",114,232,91,208)],[(0,"#f0d5ff"),(.52,"#c39aef"),(1,"#8060c5")],
           stroke="#e5c8ff",width=1.2)
    a.path([("M",44,103),("L",110,135),("L",92,208)],
           [(0,"#ddbcff"),(1,"#a276d4")],stroke="#f4d8ff",width=1)
    a.path([("M",183,106),("L",110,135),("L",140,207)],
           [(0,"#e8c7ff"),(1,"#ac7edd")],stroke="#f4d8ff",width=1)
    for x,y,sc,ang,tint in [(63,79,.66,18,1),(112,49,.78,-8,0),
                            (161,78,.70,-20,1),(85,114,.69,10,0),(137,117,.67,-14,0)]:
        a.sprite(rose_sprite(tint),x,y,sc,ang)
    # Satin bow with two folded tails.
    a.path([("M",111,187),("C",81,155,60,174,76,189),("C",88,200,103,191,111,187)],
           [(0,"#fff4c3"),(.6,"#ffd887"),(1,"#e8a64b")],stroke="#ffeba4",width=1)
    a.path([("M",115,187),("C",142,159,166,177,151,191),("C",139,199,122,192,115,187)],
           [(0,"#fff4c3"),(.6,"#ffd887"),(1,"#e8a64b")],stroke="#ffeba4",width=1)
    a.path([("M",108,190),("L",87,223),("L",100,220),("L",107,230),("L",118,192)],"#ffd17d")
    a.path([("M",118,190),("L",137,224),("L",125,219),("L",120,230),("L",109,192)],"#ffdf9d")
    a.ellipse((105,180,121,196),[(0,"#fff0b7"),(.7,"#ffd67d"),(1,"#b77ad9")])
    sparkle(a,114,182,8,.4)
    return a.image


@lru_cache(maxsize=1)
def car_sprite():
    a=Art(312,180)
    # Road-going supercar, original side/three-quarter geometry.
    a.ellipse((19,132,299,161),"#9862f9",opacity=.2,glow=("#9b66ff",6,.35))
    a.path([("M",28,115),("Q",30,96,64,89),("L",103,63),("Q",115,55,152,60),
            ("L",206,83),("Q",252,84,280,102),("L",292,124),("L",280,140),
            ("L",40,145),("L",18,132)],
           [(0,"#e9ceff"),(.40,"#d3b4ff"),(.62,"#9f6ce8"),(.83,"#5c3da8"),(1,"#32216a")],
           stroke="#e3c4ff",width=1.5,glow=("#9870ff",7,.5))
    a.path([("M",81,88),("L",111,67),("Q",125,63,145,66),("L",187,86)],
           [(0,"#c8fbff"),(.48,"#81b8e5"),(.8,"#47396d"),(1,"#2a1c54")],stroke="#ecdaff",width=1)
    a.path([("M",149,66),("L",159,86),("L",188,86)],"#536080")
    a.line([(144,67),(151,86)],"#e0d2ff",2)
    a.path([("M",31,111),("C",91,93,169,89,225,97),("L",278,111),
            ("C",216,105,123,104,76,119)],
           [(0,"#fae8ff"),(.62,"#d3a8ff"),(1,"#ac73e7")])
    a.path([("M",87,116),("L",207,105),("L",175,135),("L",98,138)],
           [(0,"#a47be9"),(.65,"#7a4cb5"),(1,"#4c2b81")],stroke="#c28eea",width=.7)
    a.line([(104,115),(185,109)],"#f1d6ff",1.2)
    a.line([(195,107),(179,131)],"#eed3ff",.8)
    a.path([("M",164,116),("L",185,112),("L",176,120),("L",158,123)],"#38245b")
    a.path([("M",20,127),("L",39,125),("L",43,135),("L",21,134)],"#f78aa5",glow=("#ff73ba",3,.6))
    a.path([("M",249,108),("L",277,115),("L",285,122),("L",253,117)],"#fff2ba",glow=("#ffecb1",3,.8))
    a.path([("M",248,130),("L",284,127),("L",275,136),("L",244,138)],"#251744")
    a.line([(44,144),(259,140)],"#8ef9ff",2)
    a.path([("M",42,96),("L",23,86),("L",25,81),("L",58,89)],"#ae89e9",stroke="#dfbcff",width=1)
    a.path([("M",105,84),("Q",91,77,86,88),("L",96,93),("L",108,90)],"#cda5fa")
    # Wheels keep a dark tire and bright structural rim rather than a flat circle.
    for x,y,r in [(72,133,25),(234,131,25)]:
        a.ellipse((x-r,y-r,x+r,y+r),"#25143e",stroke="#dfbdf6",width=1.3)
        a.ellipse((x-r+5,y-r+5,x+r-5,y+r-5),[(0,"#bcacec"),(.5,"#674b93"),(1,"#332350")],stroke="#a2e9f7",width=1.4)
        for i in range(6):
            ang=i*TAU/6
            a.line([(x,y),(x+math.cos(ang)*15,y+math.sin(ang)*15)],"#c6b3f1",2)
        a.ellipse((x-4,y-4,x+4,y+4),"#fff2bd")
    return a.image


@lru_cache(maxsize=1)
def rocket_sprite():
    a=Art(184,284)
    # A pearlescent rocket with gold fittings, glass porthole and faceted fins.
    a.path([("M",61,154),("C",33,164,24,195,30,223),("L",63,209),("L",76,173)],
           [(0,"#d9bdff"),(.6,"#a470ea"),(1,"#5c399f")],stroke="#e8d0ff",width=1.2)
    a.path([("M",124,154),("C",152,164,161,195,155,223),("L",122,209),("L",109,173)],
           [(0,"#d9bdff"),(.6,"#a470ea"),(1,"#5c399f")],stroke="#e8d0ff",width=1.2)
    a.path([("M",92,24),("C",46,58,46,123,59,191),("Q",91,218,125,191),
            ("C",139,123,137,58,92,24)],
           [(0,"#fff6db"),(.22,"#f7e8ff"),(.47,"#d7d5f8"),(.7,"#b9a6e3"),(1,"#805aaf")],
           stroke="#f3e4ff",width=1.5,glow=("#b797ff",9,.6))
    a.path([("M",92,25),("C",76,36,65,53,60,75),("Q",91,89,125,75),
            ("C",119,53,108,35,92,25)],
           [(0,"#fff4ba"),(.24,"#ffe5a0"),(.49,"#d89d51"),(1,"#9b658a")],stroke="#ffefc6",width=1)
    a.path([("M",69,87),("C",58,123,62,165,72,187),("L",79,192),
            ("C",70,157,66,116,76,89)],"#ffffff")
    a.ellipse((64,94,122,152),[(0,"#fff1d7"),(.45,"#eac28c"),(1,"#a67774")],stroke="#fff4d4",width=1.4)
    a.ellipse((70,100,116,146),[(0,"#e2ffff"),(.34,"#89e4f6"),(.60,"#718de3"),(1,"#694db6")],stroke="#5f447d",width=1)
    a.path([("M",76,121),("Q",76,103,94,104),("Q",82,109,79,125)],"#f4ffff")
    a.ellipse((101,129,108,136),"#a9edff")
    a.path([("M",60,178),("Q",92,194,125,178),("L",124,194),
            ("Q",93,215,62,195)],[(0,"#fff0b3"),(.6,"#ebbc75"),(1,"#ae72ab")],stroke="#ffe3b0",width=1)
    a.path([("M",77,204),("L",108,204),("L",114,219),("Q",92,227,70,219)],
           [(0,"#755191"),(.75,"#b89ccc"),(1,"#e4d0f1")],stroke="#e7cbfa",width=1)
    a.path([("M",91,169),("L",99,211),("L",92,235),("L",84,211)],
           [(0,"#e9d0ff"),(.6,"#ad7be4"),(1,"#7852b5")],stroke="#f5ddff",width=.8)
    sparkle(a,91,59,8,0)
    return a.image


def orbit(a, cx, cy, rx, ry, phase, opacity=1, tint="#d8b2ff", tilt=0, front=None):
    pts=[]
    for i in range(121):
        ang=i*TAU/120
        if front is not None and (math.sin(ang)>0) != front:
            if len(pts)>1:
                a.line(pts,tint,1.3,opacity)
            pts=[]
            continue
        x,y=rx*math.cos(ang),ry*math.sin(ang)
        pts.append((cx+x*math.cos(tilt)-y*math.sin(tilt),
                    cy+x*math.sin(tilt)+y*math.cos(tilt)))
    if len(pts)>1:
        a.line(pts,tint,1.3,opacity)
    x,y=rx*math.cos(phase),ry*math.sin(phase)
    sparkle(a,cx+x*math.cos(tilt)-y*math.sin(tilt),
            cy+x*math.sin(tilt)+y*math.cos(tilt),10,phase,tint,opacity)


def stars(a, seed, count, t, region=None, strength=1):
    rng=random.Random(seed)
    left,top,right,bottom=region or (12,12,a.width-12,a.height-12)
    for i in range(count):
        x,y=rng.uniform(left,right),rng.uniform(top,bottom)
        r=rng.uniform(1.4,6.0)
        phase=rng.uniform(0,TAU)+t*TAU*(.5+i%3*.3)
        if i%3==0:
            sparkle(a,x,y,r,phase, "#d4c3ff" if i%2 else "#ffecae",strength)
        else:
            alpha=(.38+.5*(.5+.5*math.sin(phase)))*strength
            a.ellipse((x-r/3,y-r/3,x+r/3,y+r/3),"#e1d2ff",opacity=alpha)


def render_heart(t, poster=False):
    a=Art(192,192)
    f=1 if poster else fade(t,.08,.85)
    orbit(a,96,98,69,26,t*TAU,.50*f,"#d4a1ff",-.33)
    pulse=1 if poster else .94+.075*math.sin(t*TAU*2)
    a.sprite(heart_sprite(),96,92-4*math.sin(t*TAU),.86*pulse,opacity=f)
    for i,(x,y,r) in enumerate([(39,51,10),(151,46,13),(157,125,10),(47,140,8)]):
        sparkle(a,x,y-4*math.sin(t*TAU+i),r,t*TAU+i,opacity=f)
    for i in range(4):
        p=(t*1.1+i*.24)%1
        if poster:
            p=(.22+i*.19)%1
        x=54+i*29+8*math.sin(p*TAU+i)
        y=158-p*87
        a.sprite(heart_sprite(),x,y,.12+.06*(i%2),(-1 if i%2 else 1)*15,
                 f*math.sin(p*math.pi)*.8)
    return a.finished()


def render_flowers(t, poster=False):
    a=Art(256,320)
    f=1 if poster else fade(t,.08,.90)
    stars(a,23,18,t,(15,20,240,291),.9*f)
    orbit(a,128,192,105,29,t*TAU,.36*f,"#d9b3ff",.12,False)
    a.sprite(bouquet_sprite(),128,172+3*math.sin(t*TAU),.95,angle=2*math.sin(t*TAU),opacity=f)
    rng=random.Random(112)
    for i in range(20):
        phase=rng.random()
        p=(t*1.2+phase)%1
        x=rng.uniform(18,238)+12*math.sin(p*TAU+i)
        y=-20+p*330
        sc=rng.uniform(.22,.48)
        a.sprite(petal_sprite(i%2),x,y,sc,angle=p*180+i*28,
                 opacity=f*min(1,p*7,(1-p)*7)*.90)
    orbit(a,128,192,105,29,t*TAU,.36*f,"#ffe4b6",.12,True)
    for x,y,r,p in [(49,123,11,.4),(200,100,12,2),(170,261,10,1)]:
        sparkle(a,x,y,r,t*TAU+p,opacity=f)
    return a.finished()


def render_car(t, poster=False):
    a=Art(320,240)
    f=1 if poster else fade(t,.04,.95)
    stars(a,65,15,t,(20,15,305,216),.8*f)
    # Sweeping illuminated road and motion streaks, distinct from particle gifts.
    for j in range(5):
        pts=[]
        for u in np.linspace(0,1,72):
            pts.append((10+u*305,169+24*u-18*math.sin(u*math.pi)+j*3))
        a.line(pts,"#9866ff" if j%2 else "#e0c2ff",.8, (.38-j*.04)*f)
    if poster:
        offset=0
    elif t<.28:
        offset=-335*(1-ease(t/.28))
    elif t>.78:
        offset=350*ease((t-.78)/.22)
    else:
        offset=0
    for j in range(8):
        x=36+offset-(t*170+j*24)%125
        y=117+j*6
        a.line([(x-26,y),(x+14,y)],"#f4c5f6" if j%2 else "#89eefb",1,.52*f)
    a.sprite(car_sprite(),160+offset,129+1.5*math.sin(t*TAU*3),1,opacity=f)
    # Rim spokes animate while the body remains crisp during the centre hold.
    for cx,cy in [(76+offset,172),(238+offset,170)]:
        for j in range(3):
            ang=t*TAU*4+j*TAU/3
            a.line([(cx+math.cos(ang)*6,cy+math.sin(ang)*6),
                    (cx+math.cos(ang)*16,cy+math.sin(ang)*16)],"#d6d0ff",1.5,.75*f)
    for x,y,r,p in [(248,66,10,1),(104,61,8,2),(274,183,11,.2)]:
        sparkle(a,x,y,r,t*TAU+p,opacity=f)
    return a.finished()


def flame_sprite(phase):
    a=Art(110,136)
    spread=5*math.sin(phase*TAU*5)
    a.path([("M",31,12),("C",13,53,29,72,54+spread,126),
            ("C",71,94,99,51,79,13)],
           [(0,"#f8e4ff"),(.28,"#ffb7f2"),(.55,"#bd75f4"),(1,"#7f50e5")],
           glow=("#c37fff",9,.8))
    a.path([("M",43,11),("C",36,43,41,61,55,95+spread),
            ("C",68,65,75,40,67,11)],
           [(0,"#ffffff"),(.45,"#fff8d7"),(1,"#ffd098")],glow=("#ffe7bd",4,.7))
    return a.image


def firework(a,cx,cy,progress,scale=1,tint="#ffdb9d",opacity=1):
    if progress<0 or progress>1:
        return
    r=(9+57*ease(progress))*scale
    fadeout=math.sin(progress*math.pi)**.6*opacity
    for i in range(14):
        angle=i*TAU/14+.15
        tail=9*(1-progress)*scale
        x,y=cx+r*math.cos(angle),cy+r*math.sin(angle)+progress*progress*13
        a.line([(x-tail*math.cos(angle),y-tail*math.sin(angle)),(x,y)],tint,1.5,fadeout)
        a.ellipse((x-1.5,y-1.5,x+1.5,y+1.5),"#fff4df",opacity=fadeout)


def render_rocket(t, poster=False):
    a=Art(320,480)
    f=1 if poster else fade(t,.05,.92)
    stars(a,17,48,t,(10,15,310,461),.9*f)
    orbit(a,160,244,126,47,t*TAU,.34*f,"#b99dfb",-.32,False)
    for i in range(9):
        p=(t*1.8+i*.17)%1
        x=52+i*29
        y=(1-p)*390+30
        a.line([(x,y-27),(x,y+2)],"#a38bff",1,.32*f*math.sin(p*math.pi))
    if poster:
        cy=220
    elif t<.25:
        cy=380-150*ease(t/.25)
    elif t<.67:
        cy=230-(t-.25)*45
    else:
        cy=211-430*ease((t-.67)/.33)
    # Layered lilac launch clouds and a warm centre light.
    for i,(x,y,r) in enumerate([(106,405,31),(145,423,40),(192,413,33),
                               (232,428,27),(70,431,22),(158,389,25)]):
        scale=(.75+.3*ease(min(1,t*3))) if not poster else 1
        a.ellipse((x-r*scale,y-r*scale,x+r*scale,y+r*scale),
                  [(0,"#f2d9ff"),(.65,"#a58acc"),(1,"#7c5eae")],
                  glow=("#b78bff",7,.24),opacity=.43*f)
    a.sprite(flame_sprite(t),160,cy+138,1+.06*math.sin(t*TAU*9),opacity=f)
    a.sprite(rocket_sprite(),160,cy,1.08,opacity=f)
    for x,y,delay,tint in [(68,106,.15,"#ffdd9a"),(256,165,.42,"#f3b8ff"),
                           (52,272,.59,"#bdefff")]:
        progress=.48 if poster else (t-delay)/.40
        firework(a,x,y,progress,.60,tint,f)
    orbit(a,160,244,126,47,t*TAU,.42*f,"#ffe4b2",-.32,True)
    sparkle(a,235,64,12,t*TAU,opacity=f)
    return a.finished()


@lru_cache(maxsize=1)
def crown_sprite():
    a=Art(160,92)
    a.path([("M",28,30),("L",57,48),("L",80,18),("L",105,48),("L",134,30),
            ("L",121,73),("Q",81,88,40,73)],
           [(0,"#fff3c6"),(.4,"#ffdf91"),(.75,"#d59a54"),(1,"#ac6c93")],
           stroke="#fff0bc",width=1.3,glow=("#ffdfa4",6,.5))
    a.path([("M",40,67),("Q",80,81,122,67),("L",120,77),("Q",79,91,41,77)],"#ffe6a5")
    a.path([("M",80,47),("L",89,58),("L",80,69),("L",71,58)],"#c187ff",stroke="#ffefff",width=1)
    for x,y in [(28,29),(80,17),(134,29)]:
        a.ellipse((x-4,y-4,x+4,y+4),"#fff0bc",glow=("#ffdd92",3,.7))
    return a.image


def cosmic_wings(a, cx, cy, scale=1, opacity=1):
    for side in [-1,1]:
        # Curving ribbons with layered feather facets, authored as mirrored paths.
        def flip(commands):
            out=[]
            for cmd in commands:
                op,*v=cmd
                out.append((op,*[cx+(v[i]*side*scale) if i%2==0 else cy+v[i]*scale
                                 for i in range(len(v))]))
            return out
        for i in range(5):
            y=i*12
            a.path(flip([("M",38,17+y*.3),("C",69,15+y,102,-30+y,133,-40+y),
                         ("C",121,-3+y,95,23+y,48,40+y*.3)]),
                   [(0,"#fce9ff"),(.35,"#dec2ff"),(.65,"#bc89ee"),(1,"#8c54c9")],
                   stroke="#f5dbff",width=.65)


def render_cosmic(t, poster=False):
    a=Art(360,540)
    f=1 if poster else fade(t,.08,.89)
    stars(a,309,83,t,(8,12,352,523),f)
    # Two nebula ribbons and individual stars preserve a transparent scene.
    for j in range(3):
        pts=[]
        for u in np.linspace(0,1,120):
            pts.append((30+u*300,390-u*264+math.sin(u*TAU+t*1.5+j*.22)*43+j*9))
        a.line(pts,"#a476f2" if j%2 else "#edb3ff",1+j*.25,.33*f)
    orbit(a,180,274,150,63,t*TAU*.6,.50*f,"#c9aeff",-.32,False)
    orbit(a,180,274,112,131,-t*TAU*.35,.34*f,"#e4a5df",.28,False)
    if poster:
        reveal=1
    else:
        reveal=.65+.35*ease(t/.25)
    cosmic_wings(a,180,271,scale=reveal,opacity=f)
    a.sprite(heart_sprite(True),180,265+4*math.sin(t*TAU),1.30*reveal,
             opacity=f)
    a.sprite(crown_sprite(),180,153+4*math.sin(t*TAU),.82*reveal,opacity=f)
    # Floating faceted gems reinforce the luxury tier without a paid-money label.
    for i in range(7):
        angle=i*TAU/7+t*.75
        x=180+math.cos(angle)*116
        y=268+math.sin(angle)*154
        w=5+(i%3)*1.6
        a.path([("M",x,y-w*1.8),("L",x+w,y),("L",x,y+w*1.8),("L",x-w,y)],
               [(0,"#fff0ff"),(.5,"#d8a2ff"),(1,"#9b60da")],stroke="#f4dfff",width=.7)
        sparkle(a,x,y,8,t*TAU+i,"#ffe6bd",.8*f)
    # A small ringed planet in the upper sky and an orbital moon at the bottom.
    orbit(a,77,104,37,10,t*TAU,.48*f,"#f0b3ff",-.35,False)
    a.ellipse((61,88,93,120),[(0,"#ead6ff"),(.5,"#bc8af2"),(1,"#7754b8")],opacity=f)
    a.path([("M",63,98),("Q",76,107,91,104),("L",91,109),("Q",76,111,63,104)],"#e4b7fb")
    orbit(a,77,104,37,10,t*TAU,.7*f,"#ffe4bb",-.35,True)
    a.ellipse((266,411,289,434),[(0,"#fff0cb"),(.6,"#bba4eb"),(1,"#7659ad")],opacity=f)
    for x,y,p,sc in [(71,205,.12,.68),(291,105,.4,.72),(103,435,.65,.6)]:
        progress=.55 if poster else (t-p)/.32
        firework(a,x,y,progress,sc,"#ffdfb0",f*.8)
    orbit(a,180,274,150,63,t*TAU*.6,.67*f,"#ffe9be",-.32,True)
    orbit(a,180,274,112,131,-t*TAU*.35,.44*f,"#f1c8ff",.28,True)
    for i,(x,y,r) in enumerate([(125,163,12),(273,239,14),(106,357,12),(215,403,11)]):
        sparkle(a,x,y,r,t*TAU+i,opacity=f)
    image=a.finished()
    # Feather and gem paths are fully opaque artwork, so apply the scene envelope
    # once more to these at the outer layer; first/last frames are truly clear.
    if f<1:
        image.putalpha(image.getchannel("A").point(lambda alpha:round(alpha*f)))
    return image


RENDERERS={"heart":render_heart,"flower_rain":render_flowers,
           "aurora_car":render_car,"galaxy_rocket":render_rocket,"cosmic_heart":render_cosmic}


def frame_durations(duration, count):
    # GIF timings are in 10ms units. Distribute rounding to preserve exact duration.
    ticks=round(duration*100)
    return [(round((i+1)*ticks/count)-round(i*ticks/count))*10 for i in range(count)]


def save_gif(frames, path, duration):
    # A single palette across all frames avoids colour flicker. Index 0 is reserved
    # for transparency, including the clear canvas for disposal-to-background.
    stride=max(1,len(frames)//12)
    samples=frames[::stride]
    sw=max(im.width for im in samples)
    sh=sum(im.height for im in samples)
    contact=Image.new("RGB",(sw,sh))
    yy=0
    for im in samples:
        contact.paste(im.convert("RGB"),(0,yy))
        yy+=im.height
    base=contact.quantize(colors=255,method=Image.Quantize.MEDIANCUT,
                          dither=Image.Dither.NONE)
    pal=Image.new("P",(1,1))
    palette=[0,0,0]+base.getpalette()[:255*3]
    palette += [0]*(768-len(palette))
    pal.putpalette(palette)
    encoded=[]
    for frame in frames:
        quant=frame.convert("RGB").quantize(palette=pal,dither=Image.Dither.NONE)
        indices=np.asarray(quant).copy()
        indices[indices==0]=1
        indices[np.asarray(frame.getchannel("A"))<GIF_ALPHA_CUTOFF]=0
        quant=Image.fromarray(indices,"P")
        quant.putpalette(palette)
        quant.info["transparency"]=0
        encoded.append(quant)
    # Pillow's save_all compositor can omit a fully clear final frame and its
    # duration when disposal=2. Write each GIF image block explicitly, preserving
    # every frame (including the clear ending) and the exact playback duration.
    header,_=GifImagePlugin.getheader(encoded[0],info={"background":0,"transparency":0,
                                                     "optimize":False})
    with path.open("wb") as handle:
        for block in header:
            handle.write(block)
        for frame,milliseconds in zip(encoded,frame_durations(duration,len(frames))):
            for block in GifImagePlugin.getdata(frame,duration=milliseconds,
                                               transparency=0,disposal=2):
                handle.write(block)
        handle.write(b";")


def check_assets():
    total=0
    manifest=json.loads((OUTPUT/"manifest.json").read_text())
    assert manifest==GIFTS,"Gift manifest is stale; rerun the generator"
    for gift in GIFTS:
        path=OUTPUT/f"{gift['id']}.gif"
        with Image.open(path) as gif:
            assert gif.size==(gift["width"],gift["height"])
            assert gif.n_frames==gift["frameCount"]
            assert "loop" not in gif.info,"Gift GIFs must play once"
            assert gif.info.get("transparency")==0
            duration=0
            alpha_pixels=[]
            for i in range(gif.n_frames):
                gif.seek(i)
                assert gif.disposal_method==2
                duration+=gif.info["duration"]
                image=gif.convert("RGBA")
                alpha=np.asarray(image.getchannel("A"))
                assert alpha[0,0]==0,"GIF must have a transparent exterior"
                alpha_pixels.append(int(np.count_nonzero(alpha)))
            assert duration==round(gift["duration"]*1000)
            assert len(set(alpha_pixels))>3,"Gift must contain an actual animation"
        with Image.open(OUTPUT/f"{gift['id']}.png") as poster:
            assert poster.mode=="RGBA"
            assert poster.size==(gift["width"],gift["height"])
        size=path.stat().st_size
        total+=size
        print(f"{gift['id']}: {gift['frameCount']} frames, {duration}ms, {size/1024:.1f} KiB")
    assert total<8*1024*1024,"Gift GIF bundle must stay under 8 MiB"
    print(f"GIF bundle: {total/1024/1024:.2f} MiB; 5 originals, transparent, single play")


def preview(path):
    # Visual review sheet: posters and four actual decoded animation snapshots.
    cellw,cellh=220,290
    sheet=Image.new("RGB",(cellw*5,cellh*5),"#271c58")
    d=ImageDraw.Draw(sheet)
    for col,gift in enumerate(GIFTS):
        for row in range(5):
            if row==0:
                frame=Image.open(OUTPUT/f"{gift['id']}.png").convert("RGBA")
            else:
                with Image.open(OUTPUT/f"{gift['id']}.gif") as gif:
                    gif.seek(round((row*.2)* (gif.n_frames-1)))
                    frame=gif.convert("RGBA")
            frame.thumbnail((cellw-16,cellh-42),Image.Resampling.LANCZOS)
            x=col*cellw+(cellw-frame.width)//2
            y=row*cellh+18+(cellh-45-frame.height)//2
            sheet.paste(frame,(x,y),frame)
            d.text((col*cellw+12,row*cellh+cellh-22),
                   gift["id"]+(" / poster" if row==0 else f" / {row*20}%"),fill="#e6d6ff")
    path.parent.mkdir(parents=True,exist_ok=True)
    sheet.save(path)
    print(f"Visual review: {path}")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true",help="Validate existing assets without rewriting")
    parser.add_argument("--preview",type=Path,help="Optional PNG contact-sheet path")
    args=parser.parse_args()
    if not args.check:
        OUTPUT.mkdir(parents=True,exist_ok=True)
        for gift in GIFTS:
            render=RENDERERS[gift["id"]]
            render(.46,poster=True).save(OUTPUT/f"{gift['id']}.png",optimize=True)
            frames=[render(i/(gift["frameCount"]-1)) for i in range(gift["frameCount"])]
            save_gif(frames,OUTPUT/f"{gift['id']}.gif",gift["duration"])
        (OUTPUT/"manifest.json").write_text(json.dumps(GIFTS,ensure_ascii=False,indent=2)+"\n")
    check_assets()
    if args.preview:
        preview(args.preview)


if __name__=="__main__":
    main()
