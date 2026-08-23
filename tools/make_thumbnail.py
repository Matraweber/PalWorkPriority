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

label = font("segoeuib.ttf", 21)
lw = d.textbbox((0, 0), "PRIORITIES", font=label)[2]
d.text((lx + (5 * bw + 4 * gap - lw) / 2, base_y + 16), "PRIORITIES",
       font=label, fill=DIM)
lw = d.textbbox((0, 0), "LIMITS", font=label)[2]
d.text((rx0 + ((rx1 - rx0) - lw) / 2, base_y + 16), "LIMITS",
       font=label, fill=DIM)

tag = font("segoeuib.ttf", 27)
centre("RANK THE JOBS. CAP THE STOCKPILE.", tag, 448, CYAN)

img.save("C:/Users/matra/Desktop/palworld-priority-mod/thumbnail.png")
print("written 512x512")
