#!/usr/bin/env python3
"""Menu navigation audit — captures screenshots + OCR at each stage.

Launches Civ VI, navigates menus, captures what OCR sees at each step,
and logs timing. Use to calibrate per-machine menu positions and verify
OCR reliability before benchmark runs.

Usage:
    uv run python scripts/menu_audit.py [--save 0A_GROUND_CONTROL]

Outputs screenshots and OCR results to ~/.civbench/audit/
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from civ_mcp import game_launcher

AUDIT_DIR = Path.home() / ".civbench" / "audit"


def capture_and_ocr(stage: str) -> dict:
    """Capture screenshot + run OCR, save both."""
    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%H%M%S")

    win = game_launcher._find_game_window()
    if not win:
        print(f"  [{stage}] NO WINDOW FOUND")
        return {"stage": stage, "error": "no window", "results": []}

    print(f"  [{stage}] Window: {win.w}x{win.h} at ({win.x},{win.y})")

    # Capture screenshot
    try:
        if sys.platform == "linux":
            import mss

            with mss.mss() as sct:
                monitor = {"top": win.y, "left": win.x, "width": win.w, "height": win.h}
                img = sct.grab(monitor)
                from PIL import Image

                pil_img = Image.frombytes("RGB", img.size, img.bgra, "raw", "BGRX")
                path = AUDIT_DIR / f"{ts}_{stage}.png"
                pil_img.save(str(path))
                print(f"  [{stage}] Screenshot saved: {path}")
        elif sys.platform == "darwin":
            from civ_mcp.game_launcher import _capture_window

            cg_image = _capture_window(win.window_id)
            # Save via CoreGraphics
            import Quartz

            url = Quartz.CFURLCreateWithFileSystemPath(
                None,
                str(AUDIT_DIR / f"{ts}_{stage}.png"),
                Quartz.kCFURLPOSIXPathStyle,
                False,
            )
            dest = Quartz.CGImageDestinationCreateWithURL(url, "public.png", 1, None)
            Quartz.CGImageDestinationAddImage(dest, cg_image, None)
            Quartz.CGImageDestinationFinalize(dest)
            print(f"  [{stage}] Screenshot saved")
        else:
            # Windows — use PIL grab
            from PIL import ImageGrab

            img = ImageGrab.grab(bbox=(win.x, win.y, win.x + win.w, win.y + win.h))
            path = AUDIT_DIR / f"{ts}_{stage}.png"
            img.save(str(path))
            print(f"  [{stage}] Screenshot saved: {path}")
    except Exception as e:
        print(f"  [{stage}] Screenshot failed: {e}")

    # Run OCR
    try:
        results = game_launcher._ocr_game_window(win)
        if not results:
            results = game_launcher._ocr_fullscreen()
    except Exception:
        results = game_launcher._ocr_fullscreen()

    ocr_items = []
    if results:
        for item in results:
            text = item[0] if isinstance(item, tuple) else str(item)
            x = item[1] if len(item) > 1 else 0
            y = item[2] if len(item) > 2 else 0
            w = item[3] if len(item) > 3 else 0
            h = item[4] if len(item) > 4 else 0
            ocr_items.append(
                {
                    "text": text,
                    "x": x,
                    "y": y,
                    "w": w,
                    "h": h,
                    "pct_x": round(x / win.w, 3) if win.w else 0,
                    "pct_y": round(y / win.h, 3) if win.h else 0,
                }
            )
            # Highlight key items
            text_lower = text.lower()
            marker = ""
            for keyword in [
                "single player",
                "load game",
                "continue",
                "multiplayer",
                "game options",
                "0a_ground",
                "ground_control",
            ]:
                if keyword in text_lower:
                    marker = " <<<<<"
                    break
            print(
                f"    '{text}' at ({x},{y}) [{w}x{h}] pct=({ocr_items[-1]['pct_x']},{ocr_items[-1]['pct_y']}){marker}"
            )

    print(f"  [{stage}] {len(ocr_items)} OCR items")

    # Save OCR results
    result = {
        "stage": stage,
        "window": {"x": win.x, "y": win.y, "w": win.w, "h": win.h},
        "results": ocr_items,
        "timestamp": time.time(),
    }
    with open(AUDIT_DIR / f"{ts}_{stage}_ocr.json", "w") as f:
        json.dump(result, f, indent=2)

    return result


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Menu navigation audit")
    parser.add_argument("--save", default="0A_GROUND_CONTROL", help="Save to load")
    parser.add_argument(
        "--skip-launch", action="store_true", help="Skip game launch (already running)"
    )
    args = parser.parse_args()

    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Audit output: {AUDIT_DIR}")
    print(f"Platform: {sys.platform}")
    print()

    # Step 0: Launch game if needed
    if not args.skip_launch:
        print("Step 0: Launching Civ VI...")
        if not game_launcher._is_tuner_port_open():
            result = game_launcher._launch_game_sync()
            print(f"  Launch: {result}")
            time.sleep(5)
        else:
            print("  Already running")
    print()

    # Step 1: Capture main menu
    print("Step 1: Main menu")
    time.sleep(3)
    main_menu = capture_and_ocr("01_main_menu")
    print()

    # Step 2: Click "Single Player"
    print("Step 2: Click 'Single Player'")
    clicked = game_launcher._click_text("Single Player", timeout=15, post_delay=2)
    print(f"  Clicked: {clicked is not None}")
    if clicked:
        sp_menu = capture_and_ocr("02_single_player")
    print()

    # Step 3: Click "Load Game"
    print("Step 3: Click 'Load Game'")
    clicked = game_launcher._click_text("Load Game", timeout=10, post_delay=2)
    print(f"  Clicked: {clicked is not None}")
    if clicked:
        load_menu = capture_and_ocr("03_load_game")
    print()

    # Step 4: Find and click the save
    print(f"Step 4: Find save '{args.save}'")
    clicked = game_launcher._click_text(args.save, timeout=15, post_delay=1)
    print(f"  Clicked: {clicked is not None}")
    if clicked:
        save_selected = capture_and_ocr("04_save_selected")
    print()

    # Step 5: Click "Load Game" button (bottom)
    print("Step 5: Click 'Load Game' button")
    clicked = game_launcher._click_text(
        "Load Game", timeout=10, post_delay=1, prefer_bottom=True, min_y_fraction=0.7
    )
    print(f"  Clicked: {clicked is not None}")
    print()

    # Step 6: Wait for leader screen + capture
    print("Step 6: Waiting for leader screen (15s)...")
    time.sleep(15)
    leader = capture_and_ocr("06_leader_screen")

    # Check if CONTINUE is visible
    continue_found = any(
        "continue" in item.get("text", "").lower() for item in leader.get("results", [])
    )
    print(f"  CONTINUE visible to OCR: {continue_found}")
    print()

    # Step 7: Try positional click positions
    print("Step 7: CONTINUE button position candidates")
    win = game_launcher._find_game_window()
    if win:
        positions = [(0.38, 0.75), (0.35, 0.82), (0.38, 0.80), (0.35, 0.78)]
        for pct_x, pct_y in positions:
            abs_x = win.x + int(win.w * pct_x)
            abs_y = win.y + int(win.h * pct_y)
            print(f"  ({pct_x:.0%},{pct_y:.0%}) -> screen ({abs_x},{abs_y})")
    print()

    # Step 8: Click CONTINUE (try OCR first, then positional)
    print("Step 8: Clicking CONTINUE...")
    start = time.time()
    clicked = game_launcher._click_text("CONTINUE", timeout=30, post_delay=1)
    if clicked:
        print(f"  OCR click succeeded in {time.time() - start:.1f}s")
    else:
        print(f"  OCR failed after {time.time() - start:.1f}s — using positional click")
        game_launcher._click_continue_positional()
    print()

    # Step 9: Wait for game to load, capture in-game
    print("Step 9: Waiting 15s for game load...")
    time.sleep(15)
    ingame = capture_and_ocr("09_in_game")

    # Step 10: Check FireTuner
    print(f"\nStep 10: FireTuner port open: {game_launcher._is_tuner_port_open()}")

    print("\n=== AUDIT COMPLETE ===")
    print(f"Results in: {AUDIT_DIR}")


if __name__ == "__main__":
    main()
