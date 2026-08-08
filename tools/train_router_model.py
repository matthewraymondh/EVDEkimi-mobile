#!/usr/bin/env python3
"""Trains and exports the on-device ONNX router model.

This produces a *real* model that ships in the app bundle and runs through ONNX
Runtime Mobile on device. It is small on purpose — a few hundred KB, single-digit
milliseconds per inference, no download step, works offline from first launch.

What the model does (two heads, one graph):

  features[1, 512]  -->  MatMul(W1) + b1  -->  tanh  -->  embedding[1, 64]
                                                   |
                                                   +-->  MatMul(W2) + b2 --> softmax --> intent[1, 6]

* ``intent`` routes a message: does it need the cloud model, or can the local
  path answer it (a greeting, a thank-you, a question about the user's own
  history)? The classes are the ones an EVDEkimi property assistant actually
  sees — searching listings, asking price, booking a viewing, and the ownership
  questions that dominate Bali real estate.
* ``embedding`` is a 64-d supervised bottleneck used for offline semantic search
  over stored messages. It is not a general-purpose sentence encoder and is not
  claimed to be one; it is a learned projection that clusters the intents and
  vocabulary this app actually sees.

Feature extraction is a hashing vectorizer (word unigrams + bigrams + character
trigrams, FNV-1a 32-bit, L2 normalised). It is reimplemented in Dart in
``lib/features/ai/data/onnx/hashing_vectorizer.dart``; the two must agree bit for
bit, which is what ``test/features/ai/onnx_parity_test.dart`` verifies against the
golden fixture this script writes.

Usage:
    python tools/train_router_model.py
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

# --------------------------------------------------------------------------
# Configuration. Any change here must be mirrored in the Dart vectorizer and
# in the model metadata JSON, which is why the values live in one place.
# --------------------------------------------------------------------------
FEATURE_DIM = 512
EMBEDDING_DIM = 64
MODEL_VERSION = 1
MODEL_ID = "evdekimi-router-onnx-v1"

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSET_DIR = REPO_ROOT / "assets" / "models"
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures"

ONNX_PATH = ASSET_DIR / "evdekimi_router_v1.onnx"
METADATA_PATH = ASSET_DIR / "evdekimi_router_v1.json"
FIXTURE_PATH = FIXTURE_DIR / "onnx_router_golden.json"

# Order is the label order of the softmax output and is part of the contract
# with Dart. Append only; never reorder.
INTENTS = [
    "greeting",
    "gratitude",
    "recall",
    "property_search",
    "pricing",
    "viewing",
    "legal",
]


# --------------------------------------------------------------------------
# Feature extraction — must match the Dart implementation exactly.
# --------------------------------------------------------------------------
_NON_ALNUM = re.compile(r"[^a-z0-9]+")

FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
UINT32_MASK = 0xFFFFFFFF


def fnv1a_32(value: str) -> int:
    """FNV-1a over UTF-8 bytes.

    Chosen over Python's ``hash`` because it is stable across processes and
    trivial to reimplement identically in Dart.
    """
    digest = FNV_OFFSET
    for byte in value.encode("utf-8"):
        digest ^= byte
        digest = (digest * FNV_PRIME) & UINT32_MASK
    return digest


def normalise(text: str) -> str:
    return _NON_ALNUM.sub(" ", text.lower()).strip()


def extract_features(text: str) -> list[str]:
    """Word unigrams, word bigrams, and character trigrams."""
    normalised = normalise(text)
    if not normalised:
        return []

    words = normalised.split()
    features: list[str] = [f"w:{word}" for word in words]
    features += [f"b:{words[i]}_{words[i + 1]}" for i in range(len(words) - 1)]

    # Pad with spaces so word-boundary trigrams are represented.
    padded = f" {normalised} "
    features += [f"c:{padded[i:i + 3]}" for i in range(len(padded) - 2)]
    return features


def vectorise(text: str) -> np.ndarray:
    vector = np.zeros(FEATURE_DIM, dtype=np.float32)
    for feature in extract_features(text):
        vector[fnv1a_32(feature) % FEATURE_DIM] += 1.0
    norm = float(np.linalg.norm(vector))
    if norm > 0.0:
        vector /= norm
    return vector


# --------------------------------------------------------------------------
# Training corpus. Hand-authored templates, expanded combinatorially.
# --------------------------------------------------------------------------
CORPUS: dict[str, list[str]] = {
    "greeting": [
        "hi", "hello", "hey there", "good morning", "good evening",
        "hi there, how are you?", "hey, are you online?", "yo",
        "morning!", "hello again", "hey assistant", "hi, quick question",
        "selamat pagi", "halo", "hai", "good afternoon",
        "hey, you around?", "hello, can you help me find a property?",
        "start over", "new chat please", "greetings",
    ],
    "gratitude": [
        "thanks", "thank you", "thanks a lot", "that was helpful",
        "perfect, thanks", "appreciate it", "cheers", "thank you so much",
        "great, that worked", "nice, thanks!", "makasih", "terima kasih",
        "awesome thank you", "exactly what i needed", "you're the best",
        "that solved it, thanks", "ok thanks", "brilliant thanks",
    ],
    "recall": [
        "what did i ask you earlier?",
        "remind me what we discussed",
        "what did i say about the canggu villa?",
        "find my earlier message about seminyak",
        "search my history for beachfront",
        "did we talk about that ubud listing before?",
        "which property did i ask about yesterday?",
        "look up my previous conversation on leasehold",
        "what did we decide about the budget?",
        "recall our discussion about pererenan",
        "which chat mentioned the rice field view?",
        "i asked about a three bedroom before, what was it",
        "show me what i wrote about the land plot",
        "remind me of the shortlist we made",
        "what have we covered so far?",
        "go back to what i said about the pool villa",
    ],
    "property_search": [
        "show me villas in canggu",
        "i am looking for a 3 bedroom villa",
        "any land for sale in ubud?",
        "find me a beachfront property in sanur",
        "do you have anything in seminyak with a pool?",
        "looking for a house near berawa",
        "show listings in uluwatu",
        "i want a villa with an ocean view",
        "any apartments available in denpasar?",
        "properties with a rice field view please",
        "show me new listings this week",
        "i need a 2 bedroom close to the beach",
        "what do you have in pererenan?",
        "find a family home with a garden",
        "any commercial property in kuta?",
        "looking for a plot of land to build on",
        "show me your most popular villas",
        "do you have furnished villas?",
    ],
    "pricing": [
        "how much is that villa?",
        "what is the price range in canggu?",
        "my budget is 300 thousand usd",
        "what is the price per are in ubud?",
        "how much does a villa in seminyak cost?",
        "what is the expected rental yield?",
        "what roi can i expect on this property?",
        "are there any additional fees?",
        "how much is the annual land tax?",
        "what is the maintenance cost per month?",
        "is the price negotiable?",
        "what is the cheapest villa you have?",
        "how much deposit is required?",
        "what payment terms do you offer?",
        "compare prices between canggu and ubud",
        "what is the average nightly rate for rentals?",
    ],
    "viewing": [
        "can i schedule a viewing?",
        "i would like to visit the property",
        "when can i see the villa?",
        "book me a site visit for saturday",
        "are viewings available this week?",
        "can we arrange an inspection tomorrow?",
        "i want to tour the property",
        "is a virtual tour available?",
        "can someone show me around?",
        "what times are you available for a visit?",
        "arrange a meeting with the agent",
        "can i see it in person before deciding?",
        "schedule an appointment please",
        "i am in bali next week, can we meet?",
    ],
    "legal": [
        "what is the difference between leasehold and freehold?",
        "can foreigners own land in indonesia?",
        "explain hak pakai",
        "do i need a pt pma to buy?",
        "how long is the lease term?",
        "is the certificate clean?",
        "what is hak milik?",
        "who handles the notary?",
        "can the lease be extended?",
        "what zoning is this land?",
        "is a building permit included?",
        "what taxes apply when buying?",
        "how does the due diligence process work?",
        "can i put the property in my name?",
        "what documents do i need to sign?",
        "is there a nominee structure involved?",
    ],
}


def build_dataset() -> tuple[np.ndarray, np.ndarray]:
    features: list[np.ndarray] = []
    labels: list[int] = []
    for index, intent in enumerate(INTENTS):
        for sample in CORPUS[intent]:
            features.append(vectorise(sample))
            labels.append(index)
            # Light augmentation: casing and trailing punctuation are noise the
            # normaliser already removes, but capitalised/questioned variants
            # exercise different character trigrams at the boundaries.
            features.append(vectorise(sample.upper()))
            labels.append(index)
            features.append(vectorise(sample.rstrip("?!. ") + " ?"))
            labels.append(index)
    return np.stack(features), np.array(labels, dtype=np.int64)


def train(
    x: np.ndarray,
    y: np.ndarray,
    *,
    epochs: int = 4000,
    learning_rate: float = 0.35,
    weight_decay: float = 1e-4,
    seed: int = 20260807,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Trains a 2-layer tanh MLP with plain gradient descent.

    Hand-rolled rather than pulled from scikit-learn so the export has no
    dependency beyond numpy/onnx, and so the exact forward pass that ONNX
    reproduces is visible here.
    """
    rng = np.random.default_rng(seed)
    n_classes = len(INTENTS)

    # Xavier-ish init keeps tanh in its linear range at the start.
    w1 = (rng.standard_normal((FEATURE_DIM, EMBEDDING_DIM)) * (1.0 / np.sqrt(FEATURE_DIM))).astype(np.float32)
    b1 = np.zeros(EMBEDDING_DIM, dtype=np.float32)
    w2 = (rng.standard_normal((EMBEDDING_DIM, n_classes)) * (1.0 / np.sqrt(EMBEDDING_DIM))).astype(np.float32)
    b2 = np.zeros(n_classes, dtype=np.float32)

    one_hot = np.zeros((y.size, n_classes), dtype=np.float32)
    one_hot[np.arange(y.size), y] = 1.0
    batch = float(y.size)

    for epoch in range(epochs):
        hidden_pre = x @ w1 + b1
        hidden = np.tanh(hidden_pre)
        logits = hidden @ w2 + b2

        # Numerically stable softmax.
        shifted = logits - logits.max(axis=1, keepdims=True)
        exp = np.exp(shifted)
        probs = exp / exp.sum(axis=1, keepdims=True)

        d_logits = (probs - one_hot) / batch
        d_w2 = hidden.T @ d_logits + weight_decay * w2
        d_b2 = d_logits.sum(axis=0)

        d_hidden = d_logits @ w2.T
        d_hidden_pre = d_hidden * (1.0 - hidden**2)
        d_w1 = x.T @ d_hidden_pre + weight_decay * w1
        d_b1 = d_hidden_pre.sum(axis=0)

        w1 -= learning_rate * d_w1
        b1 -= learning_rate * d_b1
        w2 -= learning_rate * d_w2
        b2 -= learning_rate * d_b2

        if epoch % 1000 == 0:
            loss = float(-np.log(probs[np.arange(y.size), y] + 1e-9).mean())
            accuracy = float((probs.argmax(axis=1) == y).mean())
            print(f"  epoch {epoch:5d}  loss {loss:.4f}  train acc {accuracy:.3f}")

    hidden = np.tanh(x @ w1 + b1)
    logits = hidden @ w2 + b2
    accuracy = float((logits.argmax(axis=1) == y).mean())
    print(f"  final train accuracy: {accuracy:.3f}")
    return w1, b1, w2, b2


def build_onnx(w1: np.ndarray, b1: np.ndarray, w2: np.ndarray, b2: np.ndarray) -> onnx.ModelProto:
    """Hand-builds the graph so the ops are explicit and auditable."""
    features = helper.make_tensor_value_info("features", TensorProto.FLOAT, [1, FEATURE_DIM])
    embedding = helper.make_tensor_value_info("embedding", TensorProto.FLOAT, [1, EMBEDDING_DIM])
    intent = helper.make_tensor_value_info("intent_probs", TensorProto.FLOAT, [1, len(INTENTS)])

    initializers = [
        numpy_helper.from_array(w1.astype(np.float32), "W1"),
        numpy_helper.from_array(b1.astype(np.float32), "B1"),
        numpy_helper.from_array(w2.astype(np.float32), "W2"),
        numpy_helper.from_array(b2.astype(np.float32), "B2"),
    ]

    nodes = [
        helper.make_node("MatMul", ["features", "W1"], ["hidden_pre_raw"], name="proj1"),
        helper.make_node("Add", ["hidden_pre_raw", "B1"], ["hidden_pre"], name="bias1"),
        # tanh gives a bounded embedding, which keeps cosine similarity stable.
        helper.make_node("Tanh", ["hidden_pre"], ["embedding"], name="bottleneck"),
        helper.make_node("MatMul", ["embedding", "W2"], ["logits_raw"], name="proj2"),
        helper.make_node("Add", ["logits_raw", "B2"], ["logits"], name="bias2"),
        helper.make_node("Softmax", ["logits"], ["intent_probs"], axis=1, name="intent"),
    ]

    graph = helper.make_graph(
        nodes,
        "evdekimi_router",
        [features],
        [embedding, intent],
        initializer=initializers,
    )

    model = helper.make_model(
        graph,
        producer_name="evdekimi-train-router",
        # Opset 13 is comfortably supported by ONNX Runtime Mobile builds.
        opset_imports=[helper.make_operatorsetid("", 13)],
    )
    model.ir_version = 9
    onnx.checker.check_model(model)
    return model


def main() -> None:
    print("Building dataset…")
    x, y = build_dataset()
    print(f"  {x.shape[0]} samples, {x.shape[1]} features, {len(INTENTS)} classes")

    print("Training…")
    w1, b1, w2, b2 = train(x, y)

    print("Exporting ONNX…")
    model = build_onnx(w1, b1, w2, b2)
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    ONNX_PATH.write_bytes(model.SerializeToString())
    size_kb = ONNX_PATH.stat().st_size / 1024
    print(f"  wrote {ONNX_PATH.relative_to(REPO_ROOT)} ({size_kb:.1f} KB)")

    # Verify with the real runtime, not just the checker: a graph can pass the
    # checker and still fail to load on a mobile build.
    import onnxruntime as ort

    session = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    print(f"  inputs:  {[i.name for i in session.get_inputs()]}")
    print(f"  outputs: {[o.name for o in session.get_outputs()]}")

    probe_texts = [
        "hello there",
        "thanks a lot!",
        "what did i say about canggu earlier?",
        "show me 3 bedroom villas in seminyak",
        "how much is a villa in ubud?",
        "can i schedule a viewing on saturday?",
        "can foreigners own freehold land in bali?",
        "",
        "Halo, terima kasih banyak",
    ]

    golden = []
    correct = 0
    for text in probe_texts:
        vector = vectorise(text)
        embedding, probs = session.run(None, {"features": vector.reshape(1, -1)})
        top = int(np.argmax(probs[0]))
        golden.append(
            {
                "text": text,
                # Sparse form keeps the fixture readable and small.
                "featureNonZero": {
                    str(int(i)): round(float(vector[i]), 6)
                    for i in np.nonzero(vector)[0]
                },
                "embedding": [round(float(v), 6) for v in embedding[0]],
                "intentProbs": [round(float(v), 6) for v in probs[0]],
                "topIntent": INTENTS[top],
            }
        )
        print(f"  {text[:44]!r:48} -> {INTENTS[top]} ({probs[0][top]:.3f})")
        correct += 1

    digest = hashlib.sha256(ONNX_PATH.read_bytes()).hexdigest()

    METADATA_PATH.write_text(
        json.dumps(
            {
                "modelId": MODEL_ID,
                "version": MODEL_VERSION,
                "featureDim": FEATURE_DIM,
                "embeddingDim": EMBEDDING_DIM,
                "intents": INTENTS,
                "inputName": "features",
                "outputNames": ["embedding", "intent_probs"],
                "sha256": digest,
                "sizeBytes": ONNX_PATH.stat().st_size,
                "producer": "tools/train_router_model.py",
            },
            indent=2,
        )
            + "\n",
        encoding="utf-8",
    )
    print(f"  wrote {METADATA_PATH.relative_to(REPO_ROOT)}")

    FIXTURE_PATH.write_text(
        json.dumps(
            {
                "_comment": (
                    "Golden fixture generated by tools/train_router_model.py. "
                    "Asserts the Dart hashing vectorizer and ONNX inference "
                    "match the Python reference bit for bit."
                ),
                "modelId": MODEL_ID,
                "featureDim": FEATURE_DIM,
                "embeddingDim": EMBEDDING_DIM,
                "intents": INTENTS,
                "cases": golden,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"  wrote {FIXTURE_PATH.relative_to(REPO_ROOT)}")
    print(f"\nDone. sha256={digest[:16]}…  probes={correct}")


if __name__ == "__main__":
    main()
