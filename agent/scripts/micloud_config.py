"""micloud_config — shared config loader for the Python agents.

Reads ~/.config/micloud/config.env (override via $MICLOUD_CONFIG) — the *same* KEY="value" file the
shell scripts `source` — so both languages share one per-instance config. Resolution order for any
key: process environment  >  config.env  >  the default passed to get(). Missing file ⇒ all defaults,
so the agents still run out-of-the-box.
"""
import os

_cache = None

def _config_path():
    return os.environ.get("MICLOUD_CONFIG", os.path.expanduser("~/.config/micloud/config.env"))

def _parse():
    d = {}
    p = _config_path()
    if not os.path.exists(p):
        return d
    for raw in open(p, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] in "\"'" and v[-1] == v[0]:
            v = v[1:-1]
        if "$" in v:                                   # $HOME / ${HOME} / env, then ${EARLIER_KEY}
            v = os.path.expandvars(v)
            for kk, vv in d.items():
                v = v.replace("${%s}" % kk, vv).replace("$%s" % kk, vv)
        d[k] = v
    return d

def load():
    global _cache
    if _cache is None:
        _cache = _parse()
    return _cache

def get(key, default=None):
    return os.environ.get(key) or load().get(key) or default

def flag(key, default=False):
    v = get(key)
    return default if v is None else str(v).strip().lower() in ("1", "true", "yes", "on")
