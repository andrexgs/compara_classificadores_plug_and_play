# Changelog

Todas as mudanças notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

---

## [0.1.0] - 2026-11-06

### Adicionado
- Estrutura inicial do pacote Python `clfbench` em layout `src/clfbench/` com 13 subpacotes modulares (`config`, `data`, `augmentation`, `models`, `optim`, `training`, `evaluation`, `active_learning`, `distillation`, `xai`, `oneclass`, `reporting`, `utils`).
- Configuração unificada no `pyproject.toml` com dependências base, extras opcionais (`[dev]`, `[xai]`, `[all]`) e configuração de ferramentas (`ruff`, `black`, `pytest`, `coverage`).
- CLI `clfbench` com suporte a `--help`, `--version` e subcomando `clfbench doctor` para diagnóstico completo de Python, PyTorch, CUDA/GPUs (com fallback automático para CPU), permissões em `/data` e `/outputs`, espaço em disco, `/dev/shm`, `UID:GID` e commit Git.
- Configuração base comentada em `configs/default.yaml`.
- Suíte de testes de fumaça em `tests/test_smoke.py`.
- `Dockerfile` multi-stage (`base`, `cpu`, `gpu`, `dev`) com execução não-root configurável (`UID`/`GID`), cache de camadas otimizado, labels OCI, `docker/entrypoint.sh` e `docker/healthcheck.py`.
- `docker-compose.yml` (Compose v2) com serviços `clfbench` (GPU), `clfbench-cpu`, `dev`, `test` e `tensorboard`, além de `docker-compose.override.example.yml` e `.env.example`.
- Scripts idempotentes em `scripts/`: `install_docker.sh`, `setup_nvidia_toolkit.sh` e `run_smoke.sh`.
- `Makefile` com alvos documentados (`make help`, `setup`, `docker-build`, `docker-build-cpu`, `docker-run`, `docker-shell`, `docker-test`, `doctor`, `tensorboard`, `docker-clean`, `install`, `lint`, `format`, `test`).
- Configuração de hooks em `.pre-commit-config.yaml`.
- Documentação inicial completa: `README.md`, `docs/DOCKER.md`, `docs/DECISIONS.md` e `docs/CHANGELOG.md`.
