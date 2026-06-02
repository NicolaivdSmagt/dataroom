# ABOUTME: Tests for stats._llm_backend detection that gates the llama.cpp-only live signals.
# ABOUTME: Remote endpoints must skip /slots + /metrics; self-hosted llama.cpp must keep them.
from server.stats import _llm_backend


def test_explicit_backend_wins(monkeypatch):
    monkeypatch.setenv("LLM_BACKEND", "Local")
    monkeypatch.setenv("LLM_BASE_URL", "https://remote/v1")   # ignored when explicit
    assert _llm_backend() == "local"


def test_remote_when_llm_base_url_set(monkeypatch):
    monkeypatch.delenv("LLM_BACKEND", raising=False)
    monkeypatch.setenv("LLM_BASE_URL", "https://api.tokenfactory.nebius.com/v1")
    monkeypatch.setenv("LLAMA_URL", "http://llama-server:8080")   # remote still wins
    assert _llm_backend() == "remote"


def test_local_when_only_llama_url_set(monkeypatch):
    monkeypatch.delenv("LLM_BACKEND", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.setenv("LLAMA_URL", "http://llama-server:8080")
    assert _llm_backend() == "local"


def test_defaults_to_remote_when_nothing_set(monkeypatch):
    monkeypatch.delenv("LLM_BACKEND", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.delenv("LLAMA_URL", raising=False)
    assert _llm_backend() == "remote"
