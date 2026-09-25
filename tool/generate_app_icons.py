#!/usr/bin/env python3
"""Generate Rillight desktop icons through the active Codex image provider.

The script reads the selected OpenAI-compatible provider, bearer token, and
Responses model from the local Codex config. It invokes the provider's
Responses image-generation tool, then derives the native macOS PNG set and the
Windows multi-resolution ICO from the returned source image.

Requirements:
    Python 3.11+
    Pillow (``python -m pip install pillow``)

Example:
    python tool/generate_app_icons.py --force
    python tool/generate_app_icons.py --reuse-source --force
    python tool/generate_app_icons.py --dmg-background --force
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
from io import BytesIO
import json
import os
from pathlib import Path
import tempfile
import tomllib
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


REPO_ROOT = Path(__file__).resolve().parents[1]
MAC_ICON_DIR = REPO_ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
WINDOWS_ICON = REPO_ROOT / "windows/runner/resources/app_icon.ico"
DMG_BACKGROUND = REPO_ROOT / "macos/dmg_assets/background.png"
DEFAULT_MODEL = "gpt-image-2.5"
SOURCE_SIZE = (1024, 1024)
MAC_SIZES = (16, 32, 64, 128, 256, 512, 1024)
WINDOWS_SIZES = (16, 24, 32, 48, 64, 128, 256)

# The DMG install window is 660x400 with two 128px icon slots; these
# coordinates mirror macos/package_dmg.py so the drawn slots sit exactly
# behind the Finder icons positioned by the generated .DS_Store.
DMG_BACKGROUND_SIZE = (660, 400)
DMG_BACKGROUND_BASE = (16, 25, 30)
DMG_SLOT_SIZE = 144
DMG_APP_SLOT_CENTER = (160, 200)
DMG_APPLICATIONS_SLOT_CENTER = (500, 200)

PROMPT = """Use case: logo-brand
Asset type: production-ready square desktop application icon for the Chinese Emby client "灯川 Rillight"
Primary request: create a clean original 2D anime-inspired app icon with a new silhouette: one compact folded anime ribbon/wing sigil with a pointed upper tip, a soft curved body, and two short tapered tails. It should feel like a polished anime game logo, while remaining as simple and recognizable as the reference aesthetic of a single flowing mark.
Scene/backdrop: a perfectly flat warm cream square background, like soft ivory paper; no blue background, no texture, no frame, no pre-rounded outer corners.
Subject: one centered glyph only, occupying about 55–65% of the canvas with generous breathing room; no face or character, just one elegant stylized ribbon/wing symbol with a clean contour.
Style/medium: crisp 2D Japanese anime logo art, clean ink-like outline, flat cel-shaded color blocks, slightly playful tapered tips, polished and charming, clearly illustrated rather than 3D or photorealistic.
Composition/framing: strict software-app-icon composition, straight-on front view, one focal element, graceful asymmetry, no badge, no secondary objects, no perspective, no tiny details.
Lighting/mood: one restrained cel-shaded highlight along the ribbon; calm, airy, youthful, refined.
Color palette: warm cream background, bright aqua/cyan main shape, pale mint highlight, and a very restrained deep teal outline; no red, orange, green, purple, or neon rainbow colors.
Materials/textures: flat fills with clean edges and one or two deliberate anime highlight planes; no glass, grain, paper texture, or realistic material.
Text (verbatim): none
Constraints: original abstract anime emblem only; no typography or readable letter; no human or animal face; the mark must remain clear at 16px; preserve a simple silhouette and generous empty space.
Avoid: blue background, navy background, red, orange, green, purple, rainbow, generic infinity loop, generic wave icon, literal lantern, water drop, leaf, flame, screen, play button, film reel, poster, portrait, person, character, animal, face, eyes, mouth, diamond, star, particles, scenery, complex gradients, 3D render, photorealism, multiple objects, text, Chinese characters, English characters, logos, trademarks, watermark, UI screenshot, device mockup, clutter."""

BRAND_PRIMARY = (77, 207, 216)
BRAND_SECONDARY = (202, 246, 235)
BRAND_OUTLINE = (25, 99, 113)


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--android-only", action="store_true",
        help="Build Android launcher icons/banner from the committed macOS brand icon, offline.",
    )
    parser.add_argument(
        "--dmg-background", action="store_true",
        help="Draw the DMG install-window background offline and commit it to "
             "macos/dmg_assets/background.png.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
        / "config.toml",
        help="Codex config.toml path (defaults to CODEX_HOME/config.toml).",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("IMAGE_MODEL", DEFAULT_MODEL),
        help="Image model exposed by the configured provider.",
    )
    parser.add_argument(
        "--quality",
        default="high",
        choices=("low", "medium", "high", "xhigh", "max", "auto"),
        help="Image generation quality.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=REPO_ROOT / "build/imagegen/rillight-icon-source.png",
        help="Where to retain the generated square source image.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Replace existing icon files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the resolved provider and request without making an API call.",
    )
    parser.add_argument(
        "--reuse-source",
        action="store_true",
        help="Reuse the existing source image and only rebuild transparent native icons.",
    )
    parser.add_argument(
        "--keep-background",
        action="store_true",
        help="Keep the generated background instead of converting the icon to transparency.",
    )
    return parser.parse_args()


def load_provider(config_path: Path) -> tuple[str, str, str, str]:
    if not config_path.is_file():
        fail(f"Codex config not found: {config_path}")

    with config_path.open("rb") as config_file:
        config = tomllib.load(config_file)

    provider_name = config.get("model_provider")
    providers = config.get("model_providers", {})
    provider = providers.get(provider_name, {})
    if not provider_name or not isinstance(provider, dict):
        fail("The selected Codex model provider is missing from config.toml.")

    base_url = provider.get("base_url")
    bearer_token = provider.get("experimental_bearer_token")
    response_model = config.get("model")
    if not base_url:
        fail("The selected Codex provider has no base_url.")
    if not bearer_token:
        fail("The selected Codex provider has no bearer token.")
    if not response_model:
        fail("Codex config has no Responses model.")

    return (
        str(provider_name),
        str(base_url).rstrip("/"),
        str(bearer_token),
        str(response_model),
    )


def request_json(
    url: str,
    bearer_token: str,
    *,
    payload: dict[str, Any] | None = None,
    timeout: int = 300,
) -> dict[str, Any]:
    body = None
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {bearer_token}",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with urlopen(request, timeout=timeout) as response:
            response_body = response.read()
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        fail(f"Image provider returned HTTP {error.code}: {detail[:1000]}")
    except URLError as error:
        fail(f"Could not reach image provider: {error.reason}")

    try:
        decoded = json.loads(response_body)
    except json.JSONDecodeError as error:
        fail(f"Image provider returned invalid JSON: {error}")
    if not isinstance(decoded, dict):
        fail("Image provider returned an unexpected response shape.")
    return decoded


def fetch_responses_image_bytes(response: dict[str, Any]) -> bytes:
    output = response.get("output")
    if not isinstance(output, list):
        fail("Responses image provider returned no output items.")

    for item in output:
        if not isinstance(item, dict) or item.get("type") != "image_generation_call":
            continue
        result = item.get("result")
        if not isinstance(result, str) or not result:
            continue
        if result.startswith("data:") and "," in result:
            result = result.split(",", 1)[1]
        try:
            return base64.b64decode(result)
        except ValueError as error:
            fail(f"Responses image provider returned invalid base64 data: {error}")

    output_types = [
        item.get("type")
        for item in output
        if isinstance(item, dict)
    ]
    fail(
        "Responses provider returned no completed image_generation_call "
        f"(output types: {output_types})."
    )


def remove_edge_background(image: Any) -> Any:
    """Remove only edge-connected pixels matching the generated background."""
    Image, _ = require_pillow()
    from PIL import ImageChops

    alpha = image.getchannel("A")
    if alpha.getextrema()[0] < 255:
        return image

    pixels = image.load()
    width, height = image.size
    corners = [
        pixels[0, 0][:3],
        pixels[width - 1, 0][:3],
        pixels[0, height - 1][:3],
        pixels[width - 1, height - 1][:3],
    ]
    background = tuple(sum(c[index] for c in corners) // 4 for index in range(3))
    corner_spread = max(
        max(abs(corner[index] - background[index]) for index in range(3))
        for corner in corners
    )
    if corner_spread > 48:
        fail(
            "Expected a flat chroma-key background at the canvas edges; "
            f"received corner colors {corners}."
        )

    def is_background(x: int, y: int) -> bool:
        color = pixels[x, y]
        distance = max(abs(color[index] - background[index]) for index in range(3))
        return distance <= 48

    visited = bytearray(width * height)
    background_mask = Image.new("L", image.size, 0)
    mask_pixels = background_mask.load()
    queue: deque[tuple[int, int]] = deque()

    def enqueue(x: int, y: int) -> None:
        index = y * width + x
        if visited[index] or not is_background(x, y):
            return
        visited[index] = 1
        mask_pixels[x, y] = 255
        queue.append((x, y))

    for x in range(width):
        enqueue(x, 0)
        enqueue(x, height - 1)
    for y in range(height):
        enqueue(0, y)
        enqueue(width - 1, y)

    while queue:
        x, y = queue.popleft()
        if x > 0:
            enqueue(x - 1, y)
        if x + 1 < width:
            enqueue(x + 1, y)
        if y > 0:
            enqueue(x, y - 1)
        if y + 1 < height:
            enqueue(x, y + 1)

    image = image.copy()
    image.putalpha(ImageChops.multiply(alpha, ImageChops.invert(background_mask)))
    return image


def apply_brand_palette(image: Any) -> Any:
    """Normalize generated colors to the app's quiet neutral brand palette."""
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, alpha = pixels[x, y]
            if alpha == 0:
                continue
            luminance = (r + g + b) // 3
            if luminance < 120:
                color = BRAND_OUTLINE
            elif luminance > 190:
                color = BRAND_SECONDARY
            else:
                color = BRAND_PRIMARY
            pixels[x, y] = (*color, alpha)
    return image


def require_pillow() -> tuple[Any, Any]:
    try:
        from PIL import Image, ImageOps
    except ImportError:
        fail("Pillow is required. Install it with: python -m pip install pillow")
    return Image, ImageOps


def write_icon_set(
    source_bytes: bytes,
    source_path: Path,
    force: bool,
    keep_background: bool,
) -> None:
    Image, ImageOps = require_pillow()
    try:
        with Image.open(BytesIO(source_bytes)) as source_image:
            source_image.load()
            image = ImageOps.exif_transpose(source_image).convert("RGBA")
            if not keep_background:
                image = remove_edge_background(image)
                image = apply_brand_palette(image)
            image = ImageOps.fit(
                image,
                SOURCE_SIZE,
                method=Image.Resampling.LANCZOS,
                centering=(0.5, 0.5),
            )
    except Exception as error:  # Pillow raises format-specific exceptions.
        fail(f"Generated response is not a readable image: {error}")

    targets = [source_path, WINDOWS_ICON]
    targets.extend(MAC_ICON_DIR / f"app_icon_{size}.png" for size in MAC_SIZES)
    if not force:
        existing = [str(path) for path in targets if path.exists()]
        if existing:
            fail(
                "Icon targets already exist; rerun with --force to replace them: "
                + ", ".join(existing)
            )

    source_path.parent.mkdir(parents=True, exist_ok=True)
    MAC_ICON_DIR.mkdir(parents=True, exist_ok=True)
    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)

    staging_root = REPO_ROOT / "build/imagegen"
    staging_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rillight-icons-", dir=staging_root) as temp_dir:
        staging = Path(temp_dir)
        image.save(staging / source_path.name, format="PNG", optimize=True)

        for size in MAC_SIZES:
            resized = image.resize((size, size), Image.Resampling.LANCZOS)
            resized.save(
                staging / f"app_icon_{size}.png",
                format="PNG",
                optimize=True,
            )

        image.save(
            staging / WINDOWS_ICON.name,
            format="ICO",
            sizes=[(size, size) for size in WINDOWS_SIZES],
        )

        staged_targets = [
            (staging / source_path.name, source_path),
            *[
                (staging / f"app_icon_{size}.png", MAC_ICON_DIR / f"app_icon_{size}.png")
                for size in MAC_SIZES
            ],
            (staging / WINDOWS_ICON.name, WINDOWS_ICON),
        ]
        for staged, target in staged_targets:
            os.replace(staged, target)


def write_android_icons() -> None:
    """Derive Android resources from the existing brand without an API call."""
    Image, _ = require_pillow()
    from PIL import ImageDraw, ImageFont

    resource_dir = REPO_ROOT / "android/app/src/main/res"
    with Image.open(MAC_ICON_DIR / "app_icon_1024.png") as source:
        source = source.convert("RGBA")
        for density, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                              ("xxhdpi", 144), ("xxxhdpi", 192)]:
            target = resource_dir / f"mipmap-{density}/ic_launcher.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            source.resize((size, size), Image.Resampling.LANCZOS).save(target)
        banner = Image.new("RGB", (320, 180), (16, 25, 30))
        mark = source.resize((104, 104), Image.Resampling.LANCZOS)
        banner.paste(mark, (16, 38), mark)
        draw = ImageDraw.Draw(banner)
        draw.text((132, 70), "Rillight", font=ImageFont.load_default(size=38),
                  fill=BRAND_PRIMARY)
        target = resource_dir / "drawable-xhdpi/tv_banner.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        banner.save(target)


def write_dmg_background(force: bool) -> None:
    """Draw the 660x400 DMG install-window background offline, Pillow only."""
    Image, _ = require_pillow()
    from PIL import ImageDraw

    if DMG_BACKGROUND.is_file() and not force:
        fail(
            "DMG background already exists; rerun with --force to replace it: "
            + str(DMG_BACKGROUND)
        )

    image = Image.new("RGB", DMG_BACKGROUND_SIZE, DMG_BACKGROUND_BASE)
    draw = ImageDraw.Draw(image)

    def slot_box(center):
        half = DMG_SLOT_SIZE // 2
        x, y = center
        return (x - half, y - half, x + half, y + half)

    # Drop targets for the Finder icons: outlined slots on a dark base.
    for center in (DMG_APP_SLOT_CENTER, DMG_APPLICATIONS_SLOT_CENTER):
        draw.rounded_rectangle(slot_box(center), radius=24,
                               outline=BRAND_OUTLINE, width=4)

    # Drag guide: an arrow from the app slot to the Applications slot.
    y = DMG_BACKGROUND_SIZE[1] // 2
    start = DMG_APP_SLOT_CENTER[0] + DMG_SLOT_SIZE // 2 + 14
    end = DMG_APPLICATIONS_SLOT_CENTER[0] - DMG_SLOT_SIZE // 2 - 10
    draw.rectangle((start, y - 3, end - 26, y + 3), fill=BRAND_PRIMARY)
    draw.polygon(
        [(end - 30, y - 16), (end, y), (end - 30, y + 16)],
        fill=BRAND_PRIMARY,
    )

    DMG_BACKGROUND.parent.mkdir(parents=True, exist_ok=True)
    staging_root = REPO_ROOT / "build/imagegen"
    staging_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rillight-dmg-", dir=staging_root) as temp_dir:
        staged = Path(temp_dir) / DMG_BACKGROUND.name
        image.save(staged, format="PNG", optimize=True)
        os.replace(staged, DMG_BACKGROUND)


def main() -> None:
    args = parse_args()
    if args.dmg_background:
        write_dmg_background(args.force)
        print(f"Generated DMG background: {DMG_BACKGROUND}")
        return
    if args.android_only:
        write_android_icons()
        return
    provider_name, base_url, bearer_token, response_model = load_provider(args.config)
    payload = {
        "model": response_model,
        "input": PROMPT,
        "tools": [
            {
                "type": "image_generation",
                "model": args.model,
                "action": "generate",
                "quality": args.quality,
            }
        ],
    }

    print(f"Provider: {provider_name} ({base_url})")
    print(f"Responses model: {response_model}")
    print(f"Model: {args.model}")
    print("Target: macOS AppIcon.appiconset + Windows app_icon.ico")
    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    models_response = request_json(f"{base_url}/models", bearer_token, timeout=60)
    available_models = {
        item.get("id")
        for item in models_response.get("data", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if args.model not in available_models:
        image_models = sorted(
            model for model in available_models if "image" in model.lower()
        )
        fail(
            f"Configured provider does not expose {args.model!r}. "
            f"Available image models: {', '.join(image_models) or '(none)'}"
        )

    if args.reuse_source:
        if not args.source.is_file():
            fail(f"Source image not found: {args.source}")
        print(f"Reusing existing source image: {args.source}")
        source_bytes = args.source.read_bytes()
    else:
        print("Generating one 1024x1024 source image...")
        response = request_json(f"{base_url}/responses", bearer_token, payload=payload)
        source_bytes = fetch_responses_image_bytes(response)
    write_icon_set(source_bytes, args.source, args.force, args.keep_background)
    print(f"Generated source: {args.source}")
    print(f"Generated macOS icons: {MAC_ICON_DIR}")
    print(f"Generated Windows icon: {WINDOWS_ICON}")


if __name__ == "__main__":
    main()
