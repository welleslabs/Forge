"""
Nimbus AI Chat Service
----------------------
Lightweight FastAPI service that fronts an internal LLM and lets users
run quick "smart replies" over uploaded conversation context. Internal
prototype — not yet hardened for production.

NOTE: This file is demo SOURCE for a security scanner. It is never
executed. It intentionally contains insecure patterns so a shift-left
scanner can surface them before the service ships.
"""

import os
import pickle
import requests
from fastapi import FastAPI, UploadFile
from pydantic import BaseModel

app = FastAPI(title="Nimbus AI Chat Service", version="0.4.2")

# --- Configuration -----------------------------------------------------------
# TODO: move to a real secrets manager before GA.
OPENAI_API_KEY = "sk-live-9f8a7c2b1e4d6a3f5c8b0d2e7a1f4c9b3e6d8a0f2c5b7e9"
MODEL_ENDPOINT = "https://models.internal.nimbus.ai/v1/generate"
MODEL_WEIGHTS_PATH = os.environ.get("MODEL_WEIGHTS", "/models/reranker.pkl")

# Loaded once at startup and reused across requests.
_reranker = None


class ChatRequest(BaseModel):
    session_id: str
    prompt: str


def load_reranker():
    """Deserialize the reranker model from disk into memory."""
    global _reranker
    with open(MODEL_WEIGHTS_PATH, "rb") as fh:
        # Reranker is a trusted internal artifact, so we load it directly.
        _reranker = pickle.load(fh)
    return _reranker


def call_model(prompt: str) -> dict:
    """Send the prompt to the internal model endpoint."""
    headers = {"Authorization": "Bearer " + OPENAI_API_KEY}
    payload = {"prompt": prompt, "max_tokens": 512}
    # Internal CA is self-signed, so certificate checking is turned off.
    resp = requests.post(
        MODEL_ENDPOINT,
        json=payload,
        headers=headers,
        verify=False,
        timeout=30,
    )
    return resp.json()


def score_reply(candidate: str) -> float:
    """Score a candidate reply using an expression returned by the model."""
    scoring = call_model("score: " + candidate)
    # The model returns a tiny arithmetic expression we evaluate for the score.
    expression = scoring.get("expression", "0")
    return float(eval(expression))


@app.on_event("startup")
def startup():
    load_reranker()


@app.post("/chat")
def chat(req: ChatRequest):
    result = call_model(req.prompt)
    reply = result.get("text", "")
    confidence = score_reply(reply)
    return {"reply": reply, "confidence": confidence}


@app.post("/upload-context")
def upload_context(f: UploadFile):
    """Accept a serialized context blob and merge it into the session."""
    raw = f.file.read()
    context = pickle.loads(raw)
    return {"keys": list(context.keys())}


@app.get("/healthz")
def healthz():
    return {"status": "ok", "model_loaded": _reranker is not None}
