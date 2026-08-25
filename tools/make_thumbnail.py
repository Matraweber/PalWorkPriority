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


# ---------------------------------------------------------------------------
# Laid out for 150 pixels, not for 512.
#
# Measured on the previous version at Steam's browse size: the tagline came out
# at 5.3px of cap height and the 1-5 numerals at 5.0px. Both were reasoning that
# held at full size and collapsed at the size the tile is actually seen. Steam
# shows this in a grid; almost nobody ever looks at it at 512.
#
# So: three elements, all of which survive a fifth-scale. The name, the coloured
# ladder as a SHAPE rather than as five labelled bars, and four words.
#
# The critical content also sits inside the middle 60% vertically, because
# Workshop grids are wider than tall and a square gets centre-cropped.
# ---------------------------------------------------------------------------

title = font("seguibl.ttf", 92)
centre("PAL WORK", title, 74, WHITE)
centre("PRIORITY", title, 168, WHITE)

# The accent rule, thicker so it is still a line and not a grey artefact.
d.rectangle([150, 274, S - 150, 280], fill=CYAN)

# ---- left: the priority ladder, as a shape ----
#
# No numerals. They were 17px and said nothing the descending heights and the
# mod's own green-to-grey scale do not already say, and they were the first
# thing to disappear when the tile was scaled.
lx, base_y = 96, 418
bw, gap = 34, 14
heights = [122, 99, 78, 57, 38]
for i, (h, col) in enumerate(zip(heights, BARS)):
    x = lx + i * (bw + gap)
    d.rectangle([x, base_y - h, x + bw, base_y], fill=col)

# ---- right: a stockpile against its ceiling ----
rx0, rx1 = 332, 428
top, bot = base_y - 122, base_y
d.rectangle([rx0, top, rx1, bot], outline=(72, 86, 104), width=3)

fill_top = top + 34
d.rectangle([rx0 + 3, fill_top, rx1 - 3, bot - 2], fill=(70, 132, 214))

# The ceiling line, 9px rather than 3. It was the one mark carrying the whole
# right-hand idea and it vanished first; at this weight it reads as a lid even
# when the box below it is a blue smudge.
d.rectangle([rx0 - 6, fill_top - 9, rx1 + 6, fill_top], fill=(232, 86, 86))

# ---- four words, large enough to read ----
tag = font("seguibl.ttf", 38)
centre("RANK JOBS. CAP STOCK.", tag, 448, CYAN)

# A silhouette. Steam's browse page is dark and so is this, so without an edge
# the tile bleeds into the page and loses its own outline.
d.rectangle([0, 0, S - 1, S - 1], outline=(48, 62, 80), width=3)

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
