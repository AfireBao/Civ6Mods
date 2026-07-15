"""Human-readable run ID generator for CivBench games.

Produces IDs like ``crimson-amber-falcon-47`` — memorable in conversation,
safe in filenames (hyphens only, no underscores which are the JSONL
filename delimiter), and low-collision for ~200 lifetime runs.

128 adjectives × 32 colors × 128 nouns × 100 numbers ≈ 52M possible IDs.
"""

from __future__ import annotations

import hashlib
import random
import socket as _socket
import time as _time

_ADJECTIVES = (
    # A
    "ancient",
    "ashen",
    "austere",
    "azure",
    # B
    "blazing",
    "bold",
    "brazen",
    "bronze",
    "buried",
    # C
    "celestial",
    "charred",
    "coastal",
    "coral",
    "crimson",
    "crumbling",
    # D
    "dark",
    "deep",
    "divine",
    "dormant",
    "dread",
    "dusty",
    "dusk",
    # E
    "elder",
    "ember",
    "enduring",
    "epic",
    "eternal",
    "exalted",
    # F
    "fallen",
    "feral",
    "fierce",
    "flint",
    "forgotten",
    "fractured",
    "frozen",
    # G
    "galvanic",
    "gilded",
    "glacial",
    "golden",
    "granite",
    "grim",
    # H
    "hallowed",
    "hardened",
    "hidden",
    "hollow",
    "honored",
    # I
    "iron",
    "ivory",
    # J
    "jade",
    "jagged",
    # K
    "keen",
    "kindled",
    # L
    "living",
    "lone",
    "lunar",
    # M
    "marble",
    "mighty",
    "molten",
    "muted",
    # N
    "noble",
    "nomad",
    # O
    "obsidian",
    "onyx",
    "outer",
    # P
    "pale",
    "parched",
    "penal",
    "phantom",
    "primal",
    # R
    "radiant",
    "ragged",
    "regal",
    "remnant",
    "risen",
    "roaming",
    "rusted",
    # S
    "sacred",
    "scarlet",
    "scorched",
    "shadow",
    "shining",
    "silent",
    "silver",
    "slate",
    "solar",
    "solemn",
    "sovereign",
    "stark",
    "steep",
    "stoic",
    "stormborn",
    "sunken",
    "swift",
    # T
    "tempered",
    "thorned",
    "tidal",
    "tribal",
    "twilight",
    # U
    "unified",
    "unbroken",
    # V
    "vast",
    "veiled",
    "verdant",
    "vigilant",
    "volcanic",
    # W
    "walled",
    "wandering",
    "weathered",
    "woven",
    # Z
    "zealous",
)

_NOUNS = (
    # A
    "aqueduct",
    "archer",
    "armada",
    "arsenal",
    "atlas",
    # B
    "ballista",
    "barracks",
    "bastion",
    "battlement",
    "beacon",
    "boulevard",
    # C
    "caravan",
    "catapult",
    "centurion",
    "chariot",
    "chronicle",
    "citadel",
    "colossus",
    "column",
    "compass",
    "corsair",
    "covenant",
    "crucible",
    # D
    "dragoon",
    "dynasty",
    # E
    "eclipse",
    "ember",
    "empire",
    "epoch",
    # F
    "falcon",
    "flagship",
    "forge",
    "forum",
    "frontier",
    # G
    "galley",
    "garrison",
    "gladius",
    "granary",
    # H
    "harbor",
    "herald",
    "horizon",
    "horseman",
    # J
    "javelin",
    # K
    "keep",
    "keystone",
    "knight",
    # L
    "lancer",
    "lantern",
    "legion",
    "longbow",
    # M
    "mesa",
    "minaret",
    "monolith",
    "monument",
    "musket",
    # O
    "obelisk",
    "oracle",
    "outpost",
    # P
    "palisade",
    "parapet",
    "pavilion",
    "pennant",
    "phalanx",
    "pinnacle",
    "plaza",
    "praetor",
    # Q
    "quarry",
    # R
    "rampart",
    "redoubt",
    "regiment",
    "relic",
    "requiem",
    "ridgeline",
    # S
    "sabre",
    "scout",
    "sentinel",
    "serpent",
    "siege",
    "spire",
    "standard",
    "steppe",
    # T
    "temple",
    "terrace",
    "tower",
    "trebuchet",
    "trident",
    "trireme",
    # V
    "vanguard",
    "vault",
    "vigil",
    "vineyard",
    # W
    "warden",
    "warrior",
    "watchtower",
    # Z
    "zenith",
    "ziggurat",
    "zeppelin",
)


_COLORS = (
    "amber",
    "azure",
    "carmine",
    "cedar",
    "cerulean",
    "cobalt",
    "copper",
    "coral",
    "ebony",
    "emerald",
    "flax",
    "garnet",
    "indigo",
    "ivory",
    "jet",
    "khaki",
    "lapis",
    "lilac",
    "mahogany",
    "ochre",
    "olive",
    "pearl",
    "rust",
    "sable",
    "sage",
    "scarlet",
    "sepia",
    "sienna",
    "slate",
    "teal",
    "umber",
    "vermil",
)


def generate_run_id(
    model_id: str = "",
    scenario_id: str = "",
    timestamp: float | None = None,
    hostname: str | None = None,
) -> str:
    """Generate a human-readable run ID like ``crimson-amber-falcon-47``.

    Deterministic on (hostname, model, scenario, hour) when model/scenario
    are set — same machine resumes stably, parallel fleet launches get
    distinct IDs. Random fallback when no context is given.
    """
    ts = timestamp or _time.time()
    hour_bucket = int(ts) // 3600

    host = hostname if hostname is not None else _socket.gethostname()
    seed_str = f"{host}:{model_id}:{scenario_id}:{hour_bucket}"
    if model_id or scenario_id:
        h = hashlib.sha256(seed_str.encode()).digest()
        adj_idx = h[0] % len(_ADJECTIVES)
        col_idx = h[1] % len(_COLORS)
        noun_idx = h[2] % len(_NOUNS)
        num = h[3] % 100
    else:
        rng = random.Random()
        adj_idx = rng.randint(0, len(_ADJECTIVES) - 1)
        col_idx = rng.randint(0, len(_COLORS) - 1)
        noun_idx = rng.randint(0, len(_NOUNS) - 1)
        num = rng.randint(0, 99)

    return f"{_ADJECTIVES[adj_idx]}-{_COLORS[col_idx]}-{_NOUNS[noun_idx]}-{num:02d}"
