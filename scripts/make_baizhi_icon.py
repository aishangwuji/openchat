"""生成百智云服务商图标（256x256 PNG，仓库内两端共用）。

用法：
    python scripts/make_baizhi_icon.py

产物：
    BalanceApp/entry/src/main/resources/base/media/baizhi.png
    mobile/assets/providers/baizhi.png

设计：品牌色圆角方块 + 白色「百」字，与其他服务商图标同为 256x256 方形 PNG。
Reason: 图标必需二进制资源，脚本化生成保证两端一致、可复现，避免手工作图。
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SIZE = 256
MARGIN = 4
RADIUS = 56
BRAND = (15, 164, 127)  # #0FA47F，与 ProviderRegistry.brandColor 一致
BRAND_DARK = (11, 127, 134)
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
]
GLYPH = "百"


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size)
    raise SystemExit("找不到中文字体，请安装 Microsoft YaHei 或 SimHei")


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        ratio = y / max(size - 1, 1)
        color = tuple(
            int(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3)
        )
        gradient.putpixel((0, y), color)
    return gradient.resize((size, size))


def main() -> None:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile = vertical_gradient(SIZE - MARGIN * 2, BRAND, BRAND_DARK).convert("RGBA")

    mask = Image.new("L", tile.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, tile.size[0] - 1, tile.size[1] - 1), radius=RADIUS, fill=255
    )
    canvas.paste(tile, (MARGIN, MARGIN), mask)

    draw = ImageDraw.Draw(canvas)
    font = load_font(150)
    box = draw.textbbox((0, 0), GLYPH, font=font)
    x = (SIZE - (box[2] - box[0])) / 2 - box[0]
    y = (SIZE - (box[3] - box[1])) / 2 - box[1]
    draw.text((x, y), GLYPH, font=font, fill=(255, 255, 255, 255))

    targets = [
        ROOT / "BalanceApp/entry/src/main/resources/base/media/baizhi.png",
        ROOT / "mobile/assets/providers/baizhi.png",
    ]
    for target in targets:
        target.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(target, format="PNG", optimize=True)
        print(f"written {target.relative_to(ROOT)} ({target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
