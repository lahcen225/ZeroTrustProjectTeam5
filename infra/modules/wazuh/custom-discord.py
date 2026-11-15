#!/usr/bin/env python3
# SecureMed: Wazuh-alert naar Discord als embed.
# (De ingebouwde Slack-integratie werkt niet met Discord: Discord geeft 400 op het "ts"-veld.)
# Wazuh roept dit aan als: custom-discord <alertbestand> <api_key> <hook_url>
import json
import sys

import requests

alert_file, hook_url = sys.argv[1], sys.argv[3]
with open(alert_file) as f:
    alert = json.load(f)

regel = alert.get("rule", {})
data = alert.get("data", {})
level = int(regel.get("level", 0))

velden = [
    {"name": "Agent", "value": alert.get("agent", {}).get("name", "-"), "inline": True},
    {"name": "Regel", "value": f'{regel.get("id")} (level {level})', "inline": True},
]
if data.get("srcip"):
    velden.append({"name": "Bron-IP", "value": data["srcip"], "inline": True})
gebruiker = data.get("dstuser") or data.get("poging_gebruiker")
if gebruiker:
    velden.append({"name": "Gebruiker", "value": gebruiker, "inline": True})

embed = {
    "title": regel.get("description", "Wazuh alert")[:256],
    "color": 0xE53E3E if level >= 15 else 0xDD6B20,  # rood / oranje
    "fields": velden,
    "footer": {"text": "Wazuh - SecureMed"},
}
log = alert.get("full_log", "").replace("`", "'")[:900]
if log:
    embed["description"] = f"```{log}```"
if alert.get("timestamp"):
    embed["timestamp"] = alert["timestamp"].replace("+0000", "+00:00")

antwoord = requests.post(hook_url, json={"username": "Wazuh", "embeds": [embed]}, timeout=10)
antwoord.raise_for_status()
