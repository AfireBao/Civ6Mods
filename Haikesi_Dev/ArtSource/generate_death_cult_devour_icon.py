from pathlib import Path
import math
import random

from PIL import Image, ImageDraw, ImageFilter


OUTPUT = Path(__file__).with_name("death_cult_devour_icon.png")
WORK_SIZE = 2048
FINAL_SIZE = 1024


def cubic(p0, p1, p2, p3, steps=32):
    points = []
    for i in range(steps):
        t = i / steps
        u = 1.0 - t
        points.append((
            u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1],
        ))
    return points


def path(*segments):
    points = []
    for segment in segments:
        points.extend(cubic(*segment))
    points.append(segments[-1][-1])
    return [(round(x * WORK_SIZE), round(y * WORK_SIZE)) for x, y in points]


def scaled(points):
    return [(round(x * WORK_SIZE), round(y * WORK_SIZE)) for x, y in points]


def make_gradient(mask, top, bottom):
    gradient = Image.new("RGBA", (WORK_SIZE, WORK_SIZE))
    pixels = gradient.load()
    for y in range(WORK_SIZE):
        t = y / (WORK_SIZE - 1)
        color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(4))
        for x in range(WORK_SIZE):
            pixels[x, y] = color
    gradient.putalpha(mask)
    return gradient


def main():
    random.seed(7319)
    canvas = Image.new("RGBA", (WORK_SIZE, WORK_SIZE), (0, 0, 0, 0))

    outer = path(
        ((0.10, 0.36), (0.15, 0.20), (0.31, 0.12), (0.48, 0.25)),
        ((0.48, 0.25), (0.49, 0.26), (0.51, 0.26), (0.52, 0.25)),
        ((0.52, 0.25), (0.69, 0.12), (0.85, 0.20), (0.90, 0.36)),
        ((0.90, 0.36), (0.96, 0.54), (0.88, 0.75), (0.75, 0.84)),
        ((0.75, 0.84), (0.66, 0.91), (0.57, 0.79), (0.50, 0.68)),
        ((0.50, 0.68), (0.43, 0.79), (0.34, 0.91), (0.25, 0.84)),
        ((0.25, 0.84), (0.12, 0.75), (0.04, 0.54), (0.10, 0.36)),
    )

    shadow_mask = Image.new("L", (WORK_SIZE, WORK_SIZE), 0)
    ImageDraw.Draw(shadow_mask).polygon(outer, fill=220)
    shadow = Image.new("RGBA", canvas.size, (43, 25, 15, 0))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(WORK_SIZE // 70)))
    canvas.alpha_composite(shadow)

    shell_mask = Image.new("L", canvas.size, 0)
    shell_draw = ImageDraw.Draw(shell_mask)
    shell_draw.polygon(outer, fill=255)
    shell_mask = shell_mask.filter(ImageFilter.GaussianBlur(1.2))
    canvas.alpha_composite(make_gradient(shell_mask, (248, 215, 113, 255), (143, 83, 25, 255)))

    draw = ImageDraw.Draw(canvas, "RGBA")
    outline = max(18, WORK_SIZE // 55)
    draw.line(outer + [outer[0]], fill=(73, 40, 18, 245), width=outline, joint="curve")

    mouth = path(
        ((0.20, 0.40), (0.28, 0.31), (0.42, 0.34), (0.50, 0.43)),
        ((0.50, 0.43), (0.58, 0.34), (0.72, 0.31), (0.80, 0.40)),
        ((0.80, 0.40), (0.86, 0.50), (0.80, 0.64), (0.71, 0.71)),
        ((0.71, 0.71), (0.63, 0.78), (0.56, 0.62), (0.50, 0.57)),
        ((0.50, 0.57), (0.44, 0.62), (0.37, 0.78), (0.29, 0.71)),
        ((0.29, 0.71), (0.20, 0.64), (0.14, 0.50), (0.20, 0.40)),
    )
    draw.polygon(mouth, fill=(47, 25, 22, 255))
    draw.line(mouth + [mouth[0]], fill=(91, 49, 25, 255), width=outline // 2, joint="curve")

    teeth = [
        [(0.25, 0.39), (0.37, 0.43), (0.32, 0.58)],
        [(0.38, 0.38), (0.48, 0.44), (0.43, 0.61)],
        [(0.62, 0.38), (0.57, 0.61), (0.52, 0.44)],
        [(0.75, 0.39), (0.68, 0.58), (0.63, 0.43)],
        [(0.31, 0.70), (0.40, 0.59), (0.43, 0.75)],
        [(0.69, 0.70), (0.57, 0.75), (0.60, 0.59)],
    ]
    for tooth in teeth:
        pts = scaled(tooth)
        draw.polygon(pts, fill=(255, 244, 191, 255))
        draw.line(pts + [pts[0]], fill=(118, 70, 25, 255), width=outline // 3, joint="curve")

    # Broad painted highlights keep the shell legible at Civ VI action-button sizes.
    highlight_width = WORK_SIZE // 38
    draw.arc((0.13 * WORK_SIZE, 0.16 * WORK_SIZE, 0.50 * WORK_SIZE, 0.58 * WORK_SIZE), 202, 315,
             fill=(255, 240, 166, 210), width=highlight_width)
    draw.arc((0.50 * WORK_SIZE, 0.16 * WORK_SIZE, 0.87 * WORK_SIZE, 0.58 * WORK_SIZE), 225, 338,
             fill=(255, 240, 166, 210), width=highlight_width)
    draw.arc((0.11 * WORK_SIZE, 0.47 * WORK_SIZE, 0.48 * WORK_SIZE, 0.89 * WORK_SIZE), 15, 128,
             fill=(207, 132, 43, 190), width=highlight_width)
    draw.arc((0.52 * WORK_SIZE, 0.47 * WORK_SIZE, 0.89 * WORK_SIZE, 0.89 * WORK_SIZE), 52, 165,
             fill=(207, 132, 43, 190), width=highlight_width)

    # Fine warm speckle gives the otherwise flat mark Civ VI's hand-painted finish.
    for _ in range(2600):
        x = random.randrange(WORK_SIZE)
        y = random.randrange(WORK_SIZE)
        if shell_mask.getpixel((x, y)) > 200 and random.random() < 0.8:
            radius = random.choice((1, 1, 2, 3, 4))
            shade = random.choice(((255, 234, 155, 22), (74, 39, 16, 18)))
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=shade)

    canvas = canvas.resize((FINAL_SIZE, FINAL_SIZE), Image.Resampling.LANCZOS)
    canvas.save(OUTPUT)
    print(OUTPUT)


if __name__ == "__main__":
    main()
