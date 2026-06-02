# ABOUTME: Tests for LLM-endpoint resolution + Pi provider config writing in run_dataroom.py.
# ABOUTME: Covers remote (Nebius/Bedrock Mantle) and self-hosted llama.cpp backends + validation.
import json

import pytest

from server.run_dataroom import resolve_llm_endpoint, write_pi_config


# --- resolve_llm_endpoint: remote (default) backend --------------------------
def test_remote_nebius_endpoint():
    env = {
        "LLM_BASE_URL": "https://api.tokenfactory.nebius.com/v1",
        "LLM_API_KEY": "nebius-key",
        "MODEL_ID": "deepseek-ai/DeepSeek-R1-0528",
    }
    base_url, api_key = resolve_llm_endpoint(env)
    assert base_url == "https://api.tokenfactory.nebius.com/v1"
    assert api_key == "nebius-key"


def test_remote_bedrock_mantle_endpoint():
    env = {
        "LLM_BASE_URL": "https://bedrock-mantle.us-east-1.api.aws/v1",
        "LLM_API_KEY": "bedrock-key",
        "MODEL_ID": "openai.gpt-oss-120b",
    }
    base_url, api_key = resolve_llm_endpoint(env)
    assert base_url == "https://bedrock-mantle.us-east-1.api.aws/v1"
    assert api_key == "bedrock-key"


def test_remote_base_url_trailing_slash_is_stripped():
    env = {
        "LLM_BASE_URL": "https://api.tokenfactory.nebius.com/v1/",
        "LLM_API_KEY": "k",
        "MODEL_ID": "m",
    }
    base_url, _ = resolve_llm_endpoint(env)
    assert base_url == "https://api.tokenfactory.nebius.com/v1"


def test_remote_requires_model_id():
    env = {"LLM_BASE_URL": "https://api.tokenfactory.nebius.com/v1", "LLM_API_KEY": "k"}
    with pytest.raises(ValueError, match="MODEL_ID required"):
        resolve_llm_endpoint(env)


def test_remote_requires_api_key():
    env = {"LLM_BASE_URL": "https://api.tokenfactory.nebius.com/v1", "MODEL_ID": "m"}
    with pytest.raises(ValueError, match="LLM_API_KEY required"):
        resolve_llm_endpoint(env)


# --- resolve_llm_endpoint: self-hosted llama.cpp (legacy LLAMA_URL) ----------
def test_local_llama_url_gets_v1_suffix():
    base_url, api_key = resolve_llm_endpoint({"LLAMA_URL": "http://llama-server:8080"})
    assert base_url == "http://llama-server:8080/v1"
    assert api_key == "sk-local"   # default placeholder key for local


def test_local_llama_url_trailing_slash():
    base_url, _ = resolve_llm_endpoint({"LLAMA_URL": "http://localhost:8080/"})
    assert base_url == "http://localhost:8080/v1"


def test_no_endpoint_configured_raises():
    with pytest.raises(ValueError, match="LLM_BASE_URL"):
        resolve_llm_endpoint({})


def test_llm_base_url_takes_precedence_over_llama_url():
    env = {
        "LLM_BASE_URL": "https://remote/v1",
        "LLM_API_KEY": "k",
        "MODEL_ID": "m",
        "LLAMA_URL": "http://llama-server:8080",
    }
    base_url, _ = resolve_llm_endpoint(env)
    assert base_url == "https://remote/v1"


# --- write_pi_config: models.json / settings.json contents -------------------
def _read_config(agent_dir):
    models = json.loads((agent_dir / "models.json").read_text())
    settings = json.loads((agent_dir / "settings.json").read_text())
    return models, settings


def test_write_pi_config_remote_defaults(tmp_path, monkeypatch):
    monkeypatch.delenv("LLM_API", raising=False)
    monkeypatch.delenv("LLM_THINKING_LEVEL", raising=False)
    monkeypatch.delenv("LLM_SUPPORTS_DEVELOPER_ROLE", raising=False)
    monkeypatch.delenv("LLM_SUPPORTS_REASONING_EFFORT", raising=False)
    monkeypatch.setenv("MODEL_ID", "deepseek-ai/DeepSeek-R1-0528")
    monkeypatch.setenv("CONTEXT_WINDOW", "131072")

    agent_dir = tmp_path / ".pi-agent"
    write_pi_config(agent_dir, "https://api.tokenfactory.nebius.com/v1", "nebius-key",
                    "jina-key", "http://127.0.0.1:9999")
    models, settings = _read_config(agent_dir)

    prov = models["providers"]["default"]
    assert prov["baseUrl"] == "https://api.tokenfactory.nebius.com/v1"
    assert prov["apiKey"] == "nebius-key"
    assert prov["api"] == "openai-completions"   # default protocol
    assert prov["compat"] == {"supportsDeveloperRole": False, "supportsReasoningEffort": False}
    assert prov["models"][0]["id"] == "deepseek-ai/DeepSeek-R1-0528"
    assert prov["models"][0]["contextWindow"] == 131072

    assert settings["defaultProvider"] == "default"
    assert settings["defaultModel"] == "deepseek-ai/DeepSeek-R1-0528"
    assert settings["defaultThinkingLevel"] == "high"
    assert settings["compaction"]["enabled"] is True


def test_write_pi_config_honors_env_overrides(tmp_path, monkeypatch):
    monkeypatch.setenv("MODEL_ID", "openai.gpt-oss-120b")
    monkeypatch.setenv("LLM_API", "openai-responses")
    monkeypatch.setenv("LLM_THINKING_LEVEL", "medium")
    monkeypatch.setenv("LLM_SUPPORTS_DEVELOPER_ROLE", "true")
    monkeypatch.setenv("LLM_SUPPORTS_REASONING_EFFORT", "1")
    monkeypatch.setenv("CONTEXT_WINDOW", "200000")

    agent_dir = tmp_path / ".pi-agent"
    write_pi_config(agent_dir, "https://bedrock-mantle.us-east-1.api.aws/v1", "bedrock-key",
                    "jina-key", "http://127.0.0.1:9999")
    models, settings = _read_config(agent_dir)

    prov = models["providers"]["default"]
    assert prov["api"] == "openai-responses"
    assert prov["compat"] == {"supportsDeveloperRole": True, "supportsReasoningEffort": True}
    assert prov["models"][0]["contextWindow"] == 200000
    assert settings["defaultThinkingLevel"] == "medium"


def test_write_pi_config_sets_index_url_env(tmp_path, monkeypatch):
    monkeypatch.setenv("MODEL_ID", "m")
    monkeypatch.delenv("DATAROOM_INDEX_URL", raising=False)
    agent_dir = tmp_path / ".pi-agent"
    import os
    write_pi_config(agent_dir, "https://remote/v1", "k", "jina", "http://127.0.0.1:7777")
    assert os.environ["DATAROOM_INDEX_URL"] == "http://127.0.0.1:7777"
