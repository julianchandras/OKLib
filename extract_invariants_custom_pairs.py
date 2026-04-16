#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


PRIMARY_OP_TOKEN = "FSDirStatAndListingOp.getBlockLocations"
ALTERNATIVE_OP_TOKENS = ("getLocations", "getLocatedBlocks", "string2Bytes")
DEFAULT_OUTPUT_SUFFIX = ".blocklocation_filtered.json"


def get_opname(inv: dict, side: str) -> str:
    return (
        inv.get("context", {})
        .get(side, {})
        .get("data", {})
        .get("opName", "")
    )


def matches(inv: dict) -> bool:
    left_op = get_opname(inv, "left")
    right_op = get_opname(inv, "right")
    left_has_primary = PRIMARY_OP_TOKEN in left_op
    right_has_primary = PRIMARY_OP_TOKEN in right_op
    left_has_alternative = any(alt in left_op for alt in ALTERNATIVE_OP_TOKENS)
    right_has_alternative = any(alt in right_op for alt in ALTERNATIVE_OP_TOKENS)

    # Match invariants where the two opnames are split across sides in either order.
    return (left_has_primary and right_has_alternative) or (
        right_has_primary and left_has_alternative
    )


def parse_args() -> argparse.Namespace:
    alt_tokens_text = " or ".join(ALTERNATIVE_OP_TOKENS)
    parser = argparse.ArgumentParser(
        description=(
            "Extract invariants from all_invs where left/right opName includes "
            f"{PRIMARY_OP_TOKEN} and also includes either "
            f"{alt_tokens_text} (in any side/order)."
        )
    )
    parser.add_argument("input", help="Path to input all_invs JSON file")
    parser.add_argument(
        "-o",
        "--output",
        help="Path to output JSON file. Default: <input>.blocklocation_filtered.json",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    output_path = (
        Path(args.output)
        if args.output
        else input_path.with_name(input_path.name + DEFAULT_OUTPUT_SUFFIX)
    )

    with input_path.open() as f:
        all_invs = json.load(f)

    inv_list = all_invs.get("invariantList", [])
    filtered = [inv for inv in inv_list if matches(inv)]

    out_data = {"invariantList": filtered}
    with output_path.open("w") as f:
        json.dump(out_data, f, indent=2)

    print(f"Read invariants: {len(inv_list)}")
    print(f"Matched invariants: {len(filtered)}")
    print(f"Wrote: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
