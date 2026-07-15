"""Non-linear ETA prediction with Bayesian blending."""

from __future__ import annotations

from typing import Any

# Segments: (start_turn, end_turn) matching Civ VI game phases
_SEGMENTS = [(1, 50), (50, 150), (150, 330)]

# Per-model priors: (early, mid, late) min/turn, expected end turn, stall overhead
_PRIORS: dict[str, dict[str, Any]] = {
    "opus": {"rates": (1.5, 2.5, 3.5), "end_turn": 300, "stall_mult": 1.08},
    "gpt": {"rates": (1.8, 2.4, 3.3), "end_turn": 290, "stall_mult": 1.10},
    "flash-lite": {"rates": (0.8, 1.2, 1.8), "end_turn": 300, "stall_mult": 1.08},
    "3-flash": {"rates": (1.0, 1.5, 2.5), "end_turn": 300, "stall_mult": 1.08},
    "gemini": {"rates": (3.0, 5.0, 7.0), "end_turn": 280, "stall_mult": 1.12},
    "sonnet": {"rates": (1.3, 2.2, 3.0), "end_turn": 300, "stall_mult": 1.08},
}
_DEFAULT = {"rates": (2.0, 3.5, 5.0), "end_turn": 290, "stall_mult": 1.10}
_PSEUDOCOUNT = 20


def _integrate(rates: tuple, from_turn: int, to_turn: int) -> float:
    total = 0.0
    for (seg_s, seg_e), rate in zip(_SEGMENTS, rates):
        lo = max(from_turn, seg_s)
        hi = min(to_turn, seg_e)
        if hi > lo:
            total += (hi - lo) * rate
    return total


def estimate_eta(
    model_name: str, current_turn: int, elapsed_h: float, turn_limit: int = 330
) -> dict[str, float]:
    """Non-linear ETA with confidence interval.

    Returns ``{"eta_h": 11.9, "lo_h": 7.2, "hi_h": 18.1}``.
    """
    model_lower = model_name.lower()
    prior = _DEFAULT
    for key, p in _PRIORS.items():
        if key in model_lower:
            prior = p
            break

    pr = prior["rates"]
    elapsed_min = elapsed_h * 60

    prior_elapsed = _integrate(pr, 1, current_turn)
    scale = elapsed_min / prior_elapsed if prior_elapsed > 0 else 1.0

    rates = []
    for i, ((seg_s, seg_e), r) in enumerate(zip(_SEGMENTS, pr)):
        n_obs = max(0, min(current_turn, seg_e) - seg_s)
        obs_rate = r * scale if n_obs > 0 else r
        blended = (n_obs * obs_rate + _PSEUDOCOUNT * r) / (n_obs + _PSEUDOCOUNT)
        rates.append(blended)

    end_turn = min(prior["end_turn"], turn_limit)
    remaining_min = _integrate(tuple(rates), current_turn, end_turn)
    remaining_min *= prior["stall_mult"]
    eta_h = remaining_min / 60

    sigma = 0.25
    lo_rates = tuple(r * (1 - sigma) for r in rates)
    hi_rates = tuple(r * (1 + sigma) for r in rates)
    lo_end = max(current_turn + 1, min(end_turn, 250))
    eta_lo = _integrate(lo_rates, current_turn, lo_end) / 60
    eta_hi = _integrate(hi_rates, current_turn, turn_limit) * prior["stall_mult"] / 60

    return {
        "eta_h": round(eta_h, 1),
        "lo_h": round(eta_lo, 1),
        "hi_h": round(eta_hi, 1),
    }
