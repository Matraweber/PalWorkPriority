import os
"""Build the Workshop thumbnail.

Two constraints drive the layout. It is judged in a Workshop grid at maybe a
fifth of its size, so anything that needs reading at 512 is wasted; and the
mod's headline feature is now Production Limits, which the old thumbnail did
not mention at all - its tagline described only the priority ordering.

So: the name large enough to survive downscaling, and two symbols side by side
that say the two things the mod does without needing their labels read.
"""

from PIL import Image, ImageDraw, ImageFont

S = 512
BG_TOP = (21, 27, 36)
BG_BOT = (12, 16, 22)
WHITE = (238, 242, 247)
DIM = (150, 163, 178)
CYAN = (107, 203, 255)

BARS = [
    (61, 220, 74),
    (255, 221, 51),
    (255, 140, 26),
    (255, 68, 68),
    (154, 163, 173),
]

F = "C:/Windows/Fonts/"


def font(name, size):
    return ImageFont.truetype(F + name, size)


img = Image.new("RGB", (S, S), BG_TOP)
d = ImageDraw.Draw(img)

# vertical gradient
for y in range(S):
    t = y / (S - 1)
    d.line(
        [(0, y), (S, y)],
        fill=(
            int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t),
            int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t),
            int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t),
        ),
    )


def centre(text, f, y, fill):
    w = d.textbbox((0, 0), text, font=f)[2]
    d.text(((S - w) / 2, y), text, font=f, fill=fill)


title = font("seguibl.ttf", 74)
centre("PAL WORK", title, 30, WHITE)
centre("PRIORITY", title, 108, WHITE)

# a hairline under the title, the same accent the panel uses for selection
d.rectangle([166, 200, S - 166, 203], fill=CYAN)

# ---- left symbol: ranked jobs, descending bars ----
lx, base_y = 74, 372
bw, gap = 26, 12
heights = [104, 84, 66, 48, 32]
for i, (h, col) in enumerate(zip(heights, BARS)):
    x = lx + i * (bw + gap)
    d.rectangle([x, base_y - h, x + bw, base_y], fill=col)

# ---- right symbol: a stockpile filled to its limit ----
rx0, rx1 = 300, 438
top, bot = base_y - 104, base_y
d.rectangle([rx0, top, rx1, bot], outline=(60, 72, 88), width=3)

# Contents up to the line, with air above so the line reads as a lid the
# stack has met rather than something drawn through it. The first version ran
# the rule past both edges of the box, which read as a strikethrough.
fill_top = top + 40
d.rectangle([rx0 + 5, fill_top + 7, rx1 - 5, bot - 4], fill=(61, 140, 220))
d.rectangle([rx0 + 3, fill_top, rx1 - 3, fill_top + 5], fill=(255, 68, 68))

# Numerals under the bars, in the bars' own colours.
#
# This is the mod's actual scale - 1 green through 5 grey - so the thumbnail
# teaches the thing the panel then uses, and a reader who has seen it once
# recognises the row of numbers on the Monitoring Stand.
#
# They replace the words PRIORITIES and LIMITS, which were 21pt on a 512
# square. Steam draws this at well under half that in a browse grid, where
# 21pt becomes about eight pixels and turns to mush. Shapes and numerals
# survive that scale; small words do not, and the tagline underneath already
# says which half is which.
num = font("seguibl.ttf", 24)
for i, col in enumerate(BARS):
    x = lx + i * (bw + gap)
    ch = str(i + 1)
    cw = d.textbbox((0, 0), ch, font=num)[2]
    d.text((x + (bw - cw) / 2, base_y + 12), ch, font=num, fill=col)

# A red lid on the stockpile, echoed as the one number that is not a rank:
# the limit. Same weight as the numerals opposite so the two symbols read as
# a pair rather than as a chart beside a diagram.
cap = font("seguibl.ttf", 24)
cw = d.textbbox((0, 0), "MAX", font=cap)[2]
d.text((rx0 + ((rx1 - rx0) - cw) / 2, base_y + 12), "MAX",
       font=cap, fill=(232, 86, 86))

# 25pt, not 27. At 27 the line ran to within 22 pixels of both edges, which
# reads as crowded at full size and as edge-to-edge noise once Steam scales it
# down. This leaves a margin the eye can find the block against.
tag = font("segoeuib.ttf", 25)
centre("RANK THE JOBS. CAP THE STOCKPILE.", tag, 452, CYAN)

# Written beside this script's repo rather than to an absolute path.
#
# It used to save to C:/Users/matra/Desktop/..., which is nobody else's
# directory and the last developer path left in the tree - an earlier commit
# removed exactly this class of thing an hour before this file was added.
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "thumbnail.png")
img.save(OUT)
print("wrote " + OUT)
print("written 512x512")
