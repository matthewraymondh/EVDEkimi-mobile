#!/usr/bin/env python3
"""Compare two golden fixtures: the committed one and a freshly retrained one.

Why this exists instead of `git diff` on the artefacts
-----------------------------------------------------

The obvious check is to retrain and require the bytes to match. It is also
wrong, and CI proved it: the regenerated model came out the same *size*
(133,623 bytes, so an identical graph) with every weight slightly different.

That is floating point, not a broken script. `numpy` dispatches matmul to
whatever BLAS the platform provides, and the reduction order inside a threaded
AVX-512 kernel is not the reduction order inside a different one. Each rounding
difference is around 1e-16; three thousand epochs of gradient descent compound
them into weights that differ in the last few decimal places. Seeding fixes the
random draws, which is all it can fix — arithmetic is the other half.

So byte-identity is not a property of this training script across machines, and
demanding it produces a red build that says nothing. What the check was actually
for was "nobody hand-edited an asset, and the script still works". Both survive
here, split by what each half can honestly promise:

* **Feature extraction must match exactly.** Hashing is integer arithmetic —
  FNV-1a over token bytes, modulo the feature dimension. No float is involved,
  so a single differing bucket means the vectoriser changed, and that is the one
  failure with real consequences: the Dart side would silently disagree with the
  weights it is feeding.
* **Learned values are compared numerically.** Same predicted intent for every
  probe, probabilities within a tolerance far tighter than the drift matters,
  and embeddings by direction rather than by value, since the direction is what
  cosine similarity uses downstream.

Usage:  python tools/verify_model_parity.py <committed.json> <retrained.json>
"""

from __future__ import annotations

import json
import math
import sys

# Both are far tighter than platform drift, and far looser than a real change.
# Observed drift between a Windows x86 laptop and an Azure Linux runner does not
# reach the third decimal place; a changed corpus or a changed architecture
# moves probabilities by tenths.
PROBABILITY_TOLERANCE = 0.01
MINIMUM_COSINE = 0.9999


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 1.0 if na == nb else 0.0
    return dot / (na * nb)


def main(committed_path: str, retrained_path: str) -> int:
    with open(committed_path, encoding="utf-8") as handle:
        committed = json.load(handle)
    with open(retrained_path, encoding="utf-8") as handle:
        retrained = json.load(handle)

    problems: list[str] = []

    # ---- shape of the model, which must not move at all
    for key in ("modelId", "featureDim", "embeddingDim", "intents"):
        if committed[key] != retrained[key]:
            problems.append(
                f"{key}: committed {committed[key]!r} != retrained {retrained[key]!r}"
            )

    old_cases = {case["text"]: case for case in committed["cases"]}
    new_cases = {case["text"]: case for case in retrained["cases"]}

    if old_cases.keys() != new_cases.keys():
        added = sorted(new_cases.keys() - old_cases.keys())
        removed = sorted(old_cases.keys() - new_cases.keys())
        problems.append(f"probe set changed. added={added} removed={removed}")

    for text in sorted(old_cases.keys() & new_cases.keys()):
        old, new = old_cases[text], new_cases[text]
        label = repr(text)

        # Which buckets a string lands in is integer arithmetic — FNV-1a modulo
        # the feature dimension — so the set of keys must match exactly. Any
        # difference means the vectoriser changed, and the Dart side would then
        # be feeding the weights a different input than they were trained on.
        old_buckets, new_buckets = old["featureNonZero"], new["featureNonZero"]
        if old_buckets.keys() != new_buckets.keys():
            problems.append(
                f"{label}: feature buckets changed — "
                f"{sorted(old_buckets.keys() ^ new_buckets.keys())[:8]} differ. "
                "This is integer hashing; it cannot drift."
            )
        else:
            for bucket, old_weight in old_buckets.items():
                if abs(old_weight - new_buckets[bucket]) > 1e-6:
                    problems.append(
                        f"{label}: bucket {bucket} weight "
                        f"{old_weight} -> {new_buckets[bucket]}"
                    )

        if old["topIntent"] != new["topIntent"]:
            problems.append(
                f"{label}: predicted intent changed — "
                f"{old['topIntent']} -> {new['topIntent']}"
            )

        old_probs, new_probs = old["intentProbs"], new["intentProbs"]
        if len(old_probs) != len(new_probs):
            problems.append(
                f"{label}: {len(old_probs)} probabilities became {len(new_probs)}"
            )
        else:
            for intent, old_p, new_p in zip(committed["intents"], old_probs, new_probs):
                if abs(old_p - new_p) > PROBABILITY_TOLERANCE:
                    problems.append(
                        f"{label}: P({intent}) moved {old_p:.4f} -> {new_p:.4f}, "
                        f"beyond the {PROBABILITY_TOLERANCE} tolerance"
                    )

        similarity = cosine(old["embedding"], new["embedding"])
        if similarity < MINIMUM_COSINE:
            problems.append(
                f"{label}: embedding direction moved — cosine {similarity:.6f} "
                f"below {MINIMUM_COSINE}"
            )

    if problems:
        print("::error::The retrained model does not behave like the committed one.")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(
        f"OK: {len(old_cases)} probes agree. Feature extraction identical, "
        "intents identical, probabilities and embeddings within tolerance."
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
