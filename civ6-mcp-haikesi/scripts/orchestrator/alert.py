"""Alert notifications via ntfy.sh."""

from __future__ import annotations

import json
import logging
import urllib.request

log = logging.getLogger("orchestrator")


def send_alert(message: str, webhook: str = "") -> None:
    """Send ntfy alert + log."""
    log.warning("ALERT: %s", message)
    if not webhook:
        return
    try:
        payload = json.dumps(
            {
                "message": message,
                "title": "CivBench Orchestrator",
                "priority": 4,
                "tags": ["warning"],
            }
        ).encode()
        req = urllib.request.Request(
            webhook, data=payload, headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        log.debug("Alert delivery failed", exc_info=True)
