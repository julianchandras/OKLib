#!/usr/bin/env python3
"""
Shared helpers for filtering an OKLib `verified_invs` file down to a reviewable subset.
"""

import json
import re
from pathlib import Path

# benchmark/scripts/ -> repo root
OK_DIR = Path(__file__).resolve().parents[2]

ARCHIVE_DIR = OK_DIR / "inv_verify_archive"
LIVE_DIR = OK_DIR / "inv_verify_output"
CONF_DIR = OK_DIR / "conf" / "samples"
OUTPUT_DIR = OK_DIR / "inv_manual_scope"

# Envelope emitted by Gson. Element blocks sit at 4-space indent, separated by ",\n".
_HEADER = '{\n  "invariantList": [\n'
_FOOTER = "\n  ]\n}"


# --------------------------------------------------------------------------- loading

def _element_spans(text):
    """(start, end) of every top-level element of invariantList, in file order.

    Brace counting has to ignore braces inside string literals, and ignore \\" inside
    those strings -- opName values carry method signatures, so they are full of
    punctuation.
    """
    start = text.index("[", text.index('"invariantList"'))
    spans = []
    depth = 0
    in_str = False
    escaped = False
    elem_start = None

    for i in range(start + 1, len(text)):
        ch = text[i]
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                elem_start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                spans.append((elem_start, i + 1))
        elif ch == "]" and depth == 0:
            break
    return spans


def load_invariants(path):
    """-> (raw_text, spans, invariant_list). spans[i] locates invariant_list[i]."""
    text = Path(path).read_text()
    data = json.loads(text)
    invs = data.get("invariantList", [])
    spans = _element_spans(text)
    if len(spans) != len(invs):
        raise RuntimeError(
            f"{path}: sliced {len(spans)} elements but parsed {len(invs)} -- "
            "the slicer and the JSON parser disagree, refusing to emit a subset"
        )
    return text, spans, invs


def write_subset(out_path, text, spans, keep_indices):
    """Reassemble the Gson envelope around the kept elements, verbatim."""
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    blocks = [text[spans[i][0]:spans[i][1]] for i in keep_indices]
    if not blocks:
        out_path.write_text('{\n  "invariantList": []\n}')
        return
    # Element blocks already start at column 4 in the source; re-indent the first one
    # because our header ends right after the newline.
    out_path.write_text(_HEADER + "    " + (",\n    ".join(blocks)) + _FOOTER)


# ----------------------------------------------------------------------------- slots

def iter_slots(inv):
    """Yield (slot, kind, name) for each populated slot.

    kind is 'op' (opName, e.g. 'a.b.C.m(int)') or 'state' (stateName, e.g. 'a.b.C.f').
    AfterOpAtomicStateUpdate uses all three slots; most templates use two.
    """
    ctx = inv.get("context") or {}
    for slot in ("left", "right", "secondright"):
        node = ctx.get(slot)
        if not node:
            continue
        data = node.get("data") or {}
        if data.get("opName"):
            yield slot, "op", data["opName"]
        elif data.get("stateName"):
            yield slot, "state", data["stateName"]


def owner_class(name):
    """Class that owns an op or state name. 'a.b.C.m(int)' / 'a.b.C.f' -> 'a.b.C'."""
    return re.sub(r"\(.*", "", name).rsplit(".", 1)[0]


def signature(inv):
    """Template + operand names, ignoring timestamps -- for de-duplicating near-copies."""
    tmpl = inv.get("template", {}).get("type", "").split(".")[-1]
    return (tmpl, tuple(re.sub(r"\(.*\)", "()", n) for _, _, n in iter_slots(inv)))


# ------------------------------------------------------------------------ properties

def parse_properties(path):
    """key=value, skipping blanks and comments. Joins trailing-backslash continuations."""
    props = {}
    pending_key = None
    pending_val = []
    for raw in Path(path).read_text().splitlines():
        line = raw.rstrip("\n")
        if pending_key is not None:
            cont = line.endswith("\\")
            pending_val.append(line[:-1] if cont else line)
            if not cont:
                props[pending_key] = "".join(pending_val).strip()
                pending_key, pending_val = None, []
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, val = stripped.split("=", 1)
        if val.endswith("\\"):
            pending_key, pending_val = key.strip(), [val[:-1]]
        else:
            props[key.strip()] = val.strip()
    if pending_key is not None:
        props[pending_key] = "".join(pending_val).strip()
    return props


def manual_targets(props):
    """-> (classes, fields) that were instrumented by hand.

    instrument_class_allmethods is a class list -- every method of those classes is
    instrumented, so we match at class level.

    instrument_state_fields entries look like
        org...FSNamesystem.haContext^.getState\\(\\).getServiceState\\(\\).ordinal\\(\\)
        org...AbstractNNFailoverProxyProvider$NNProxyInfo.cachedState^
    Only the field before '^' is the state variable; the tail is an accessor chain used to
    read it. Just that one field is instrumented, so we match exactly, not class-wide.
    """
    classes = {c.strip() for c in props.get("instrument_class_allmethods", "").split(",") if c.strip()}
    fields = {f.split("^", 1)[0].strip() for f in props.get("instrument_state_fields", "").split(",") if f.strip()}
    return classes, fields


# -------------------------------------------------------------------------- resolving

def resolve_source(ticket, override=None):
    """Prefer the archived post-fix copy: it is stable and carries PROVENANCE, whereas
    inv_verify_output/ is whatever build ran last."""
    if override:
        p = Path(override)
        if not p.exists():
            raise SystemExit(f"--source not found: {p}")
        return p
    archived = ARCHIVE_DIR / ticket / "postfix" / "verified_invs"
    if archived.exists():
        return archived
    live = LIVE_DIR / ticket / "verified_invs"
    if live.exists():
        return live
    raise SystemExit(
        f"no verified_invs for {ticket}\n"
        f"  looked in: {archived}\n"
        f"             {live}\n"
        f"  pass --source PATH to point at one explicitly"
    )


def source_build(path):
    """Build description from the sibling PROVENANCE, if the source came from the archive."""
    prov = Path(path).parent / "PROVENANCE"
    if not prov.exists():
        return "unknown (no PROVENANCE beside the source)"
    for line in prov.read_text().splitlines():
        if line.startswith("build"):
            return line.split(":", 1)[1].strip()
    return "unknown"


def resolve_conf(ticket, override=None):
    if override:
        p = Path(override)
        if not p.exists():
            raise SystemExit(f"--conf not found: {p}")
        return p
    guess = CONF_DIR / f"{ticket.lower()}.properties"
    if guess.exists():
        return guess
    # Not every ticket has its own system config -- e.g. ZK-1496 is driven by
    # conf/samples/zk-1208.properties. Guessing would silently give an empty manual set,
    # so make the caller say which config they mean.
    candidates = sorted(p.name for p in CONF_DIR.glob(f"{ticket.split('-')[0].lower()}*.properties"))
    raise SystemExit(
        f"no system config for {ticket} at {guess}\n"
        f"  candidates for this system: {', '.join(candidates) or '(none)'}\n"
        f"  pass --conf conf/samples/<file>.properties"
    )


def out_dir(ticket):
    d = OUTPUT_DIR / ticket
    d.mkdir(parents=True, exist_ok=True)
    return d


def log_meta(ticket, lines):
    """Append a run record so a filtered file can always be traced back to its inputs."""
    from datetime import datetime
    meta = out_dir(ticket) / "FILTER.meta"
    with meta.open("a") as f:
        f.write(f"\n=== {datetime.now():%Y-%m-%d %H:%M:%S} ===\n")
        for line in lines:
            f.write(f"{line}\n")
    return meta
