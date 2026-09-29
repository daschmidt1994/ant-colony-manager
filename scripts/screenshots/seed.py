"""Realistic demo data for README screenshots, created through the public API."""
import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
TOKEN = None
NOW = datetime.now(timezone.utc)


def call(method, path, body=None, auth=True, headers=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Content-Type", "application/json")
    if auth and TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(req, data) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def ago(days=0, hours=0):
    return (NOW - timedelta(days=days, hours=hours)).isoformat()


setup = call("POST", "/api/v1/setup", {"email": "anna@ameisen.test", "password": "Formicarium-2026!",
                                        "display_name": "Anna", "setup_token": "screenshot-setup-token-123"}, auth=False)
TOKEN = setup["access_token"]
call("PATCH", "/api/v1/me/settings", {"timezone": "Europe/Vienna", "digest_time": "18:00"})

species = {s["scientific_name"]: s["id"] for s in call("GET", "/api/v1/species")["items"]}
food = {f["name"]: f for f in call("GET", "/api/v1/food-items")["items"]}
loc_a = call("POST", "/api/v1/locations", {"name": "Regal A"})["data"]["id"]
loc_b = call("POST", "/api/v1/locations", {"name": "Regal B"})["data"]["id"]


def colony(name, sp, loc, status="active", gyne="monogyne", founded=None):
    body = {"name": name, "species_id": species[sp], "species_text": sp, "location_id": loc,
            "status": status, "gyne_type": gyne, "origin": "bought"}
    if founded:
        body["founded_on"] = founded
    return call("POST", "/api/v1/colonies", body)["data"]["id"]


def schedule(c, task, days, start_days_ago=30):
    call("POST", "/api/v1/schedules", {"colony_id": c, "task_type": task, "interval_days": days,
                                       "starts_at": ago(start_days_ago)})


def feed(c, days_ago, *items, acceptance="accepted"):
    lst = []
    for name, qty in items:
        f = food[name]
        lst.append({"food_item_id": f["id"], "food_name": name, "category": f["category"],
                    "quantity": qty, "unit": f["default_unit"], "size": "small" if f["category"] == "protein" else None})
    call("POST", "/api/v1/events", {"colony_id": c, "type": "feeding", "occurred_at": ago(days_ago, 2),
                                    "feeding": {"acceptance": acceptance, "items": lst}})


def event(c, kind, days_ago, **extra):
    call("POST", "/api/v1/events", {"colony_id": c, "type": kind, "occurred_at": ago(days_ago, 3), **extra})


# 1 – Messor: protein overdue, lots of history
messor = colony("Messor #1", "Messor barbarus", loc_a, founded="2025-06-14")
for t, d in [("protein", 3), ("carbohydrate", 5), ("water", 2), ("cleaning", 14)]:
    schedule(messor, t, d)
for d in [26, 21, 16, 12, 8, 5]:
    feed(messor, d, ("Samen", 1), ("Heimchen", 2))
for d in [24, 18, 12, 6, 1]:
    feed(messor, d, ("Zuckerwasser", 3))
for d in [9, 7, 5, 3, 1]:
    event(messor, "water", d, water={"kinds": ["drinker_refilled"]})
event(messor, "cleaning", 10, cleaning={"kinds": ["food_remains", "midden"]})
for d, lo, hi in [(60, 50, 100), (30, 100, 500), (4, 500, 1000)]:
    event(messor, "census", d, census={"estimate_min": lo, "estimate_max": hi})
for d, t, h in [(6, 24.8, 54), (3, 25.6, 57), (0, 25.4, 55)]:
    event(messor, "measurement", d, measurements=[{"metric": "temperature", "value": t}, {"metric": "humidity", "value": h}])

# 2 – Lasius: winter rest planned in 10 days, water due today
lasius = colony("Lasius #2", "Lasius niger", loc_a, founded="2025-07-02")
for t, d in [("protein", 4), ("carbohydrate", 4), ("water", 3)]:
    schedule(lasius, t, d)
feed(lasius, 3, ("Fruchtfliege", 5), ("Honigwasser", 2))
event(lasius, "water", 3, water={"kinds": ["drinker_refilled"]})
event(lasius, "census", 8, census={"estimate_min": 50, "estimate_max": 100})
start = (NOW + timedelta(days=10)).date().isoformat()
end = (NOW + timedelta(days=150)).date().isoformat()
call("POST", "/api/v1/winter-rests", {"colony_id": lasius, "planned_start_on": start, "planned_end_on": end})

# 3 – Camponotus: sensor, all fine
campo = colony("Camponotus #3", "Camponotus nicobarensis", loc_b, gyne="monogyne", founded="2024-11-20")
for t, d in [("protein", 4), ("carbohydrate", 3), ("water", 3), ("cleaning", 10)]:
    schedule(campo, t, d)
feed(campo, 1, ("Schabe", 2), ("Honigwasser", 3))
event(campo, "water", 1, water={"kinds": ["drinker_refilled", "nest_moistened"]})
event(campo, "cleaning", 2, cleaning={"kinds": ["food_remains", "midden"]})
event(campo, "census", 6, census={"estimate_min": 100, "estimate_max": 500})
sensor = call("POST", "/api/v1/sensors", {"name": "Klimaschrank", "colony_id": campo,
                                          "temp_min": 22, "temp_max": 30, "humidity_min": 45, "humidity_max": 75})
key, sid = sensor["extra"]["api_key"], sensor["data"]["id"]
readings = []
for h in range(0, 72, 2):
    readings.append({"metric": "temperature", "value": round(26 + 1.5 * ((h % 24) / 12 - 1) ** 2, 1), "measured_at": ago(hours=h)})
    readings.append({"metric": "humidity", "value": 60 + (h % 12) / 2, "measured_at": ago(hours=h)})
call("POST", f"/api/v1/sensors/{sid}/measurements", {"readings": readings}, auth=False,
     headers={"Authorization": "Bearer " + key})

# 4 – Formica: founding colony
formica = colony("Formica #4", "Formica fusca", loc_b, status="founding", founded="2026-06-20")
schedule(formica, "water", 7)
for d in [15, 8, 2]:
    event(formica, "water", d, water={"kinds": ["tank_refilled"]})
event(formica, "check", 2, note="Erste Arbeiterinnen geschlüpft")

# 5 – Pheidole: cleaning overdue
pheidole = colony("Pheidole #5", "Pheidole pallidula", loc_b, gyne="polygyne", founded="2025-09-01")
for t, d in [("protein", 3), ("water", 3), ("cleaning", 7)]:
    schedule(pheidole, t, d)
feed(pheidole, 2, ("Samen", 1), ("Fruchtfliege", 3))
event(pheidole, "water", 1, water={"kinds": ["drinker_refilled"]})
event(pheidole, "cleaning", 11, cleaning={"kinds": ["food_remains", "midden"]})

call("PUT", "/api/v1/me/notifications", {"ntfy_url": "https://ntfy.sh/ameisen-k3m9x2p7qa4z", "digest_ntfy": True,
                                         "overdue_ntfy": True, "overdue_repeat_hours": 12, "sensor_ntfy": True,
                                         "sensor_repeat_hours": 6, "winter_ntfy": True, "winter_repeat_hours": 24,
                                         "quiet_start": "22:00", "quiet_end": "07:00", "quiet_except_sensor": True})
json.dump({"messor": messor, "lasius": lasius, "campo": campo, "species": species["Messor barbarus"]},
          open(sys.argv[2] if len(sys.argv) > 2 else "ids.json", "w"))
print("seeded")
