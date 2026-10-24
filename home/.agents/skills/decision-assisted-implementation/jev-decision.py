#!/usr/bin/env python3
"""Ask Jev for one bounded routing decision, using an approved summary on stdin."""
import json
import os
import sys
from urllib.request import Request, urlopen


OPTIONS = {
    "CONTINUE": "The current agent can proceed without changing approach.",
    "RETRY": "The current agent should revise its approach using the observed failure.",
    "ESCALATE": "A stronger agent is needed because attempts failed or design uncertainty remains.",
    "STOP": "The available evidence is insufficient; ask the user before continuing.",
}


def decide(summary, key):
    body = json.dumps({
        "model": "jev-latest",
        "state": summary,
        "questions": {"next": {
            "type": "choice",
            "instructions": "Choose the next action from the evidence. Do not judge test success or generate code.",
            "criteria": OPTIONS,
        }},
    }).encode()
    request = Request(
        "https://api.typesafe.ai/v1/systemone", body,
        {"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=20) as response:
        answer = json.load(response)["answers"]["next"]
    choice, confidence = answer["choice"], answer["confidence"]
    if answer["type"] != "choice" or choice not in OPTIONS or type(confidence) not in (int, float) or not 0 <= confidence <= 1:
        raise ValueError("invalid decision")
    return {"choice": choice, "confidence": confidence}


def main():
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key:
        raise ValueError("TYPESAFE_API_KEY is not set")
    summary = sys.stdin.read(4097)
    if not summary.strip() or len(summary) > 4096:
        raise ValueError("approved summary must contain 1–4096 characters")
    print(json.dumps(decide(summary, key)))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Do not print exception text: HTTP errors can contain request details.
        print("Jev decision unavailable; stop and inspect locally (no automatic retry).", file=sys.stderr)
        sys.exit(1)
