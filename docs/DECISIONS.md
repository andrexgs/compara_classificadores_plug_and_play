# Registro de Decisões de Arquitetura (ADR - Fase 0)

Este documento registra as decisões técnicas e suposições adotadas durante a construção da **Fase 0** do **`clfbench`**.

---

## ADR-001: Layout `src/` e Empacotamento via `pyproject.toml` (PEP 621)

- **Contexto**: Necessidade de garantir que os testes e a CLI importem sempre o pacote instalado (e não módulos relativos acidentais do diretório de trabalho) e centralizar configurações de ferramentas.
- **Decisão**: Adotar o layout `src/clfbench/` com configuração unificada no `pyproject.toml` para `setuptools`, `ruff`, `black` (`line-length = 100`), `pytest` e `coverage`.
- **Consequência**: Maior higiene de importação tanto localmente quanto nos containers Docker.

---

## ADR-002: CLI com `argparse` + Formatação `rich` (com Fallback Gracioso)

- **Contexto**: O escopo permite `Typer` ou `argparse` para a CLI (`clfbench --help`, `clfbench --version`, `clfbench doctor`).
- **Decisão**: Utilizar `argparse` da biblioteca padrão para o roteamento de argumentos e `rich.console.Console` (com fallback automático para `sys.stdout.write`) para a saída formatada do `clfbench doctor`, mantendo `logging` padrão em todos os demais pontos do código.
- **Consequência**: A CLI possui zero risco de quebra por incompatibilidade de versões de bibliotecas externas de CLI e funciona até mesmo em ambientes Python mínimos, aproveitando o `rich` quando presente.

---

## ADR-003: Resolução Híbrida de `/data` e `/outputs` (Container vs. Host Nativo)

- **Contexto**: No container Docker, os diretórios padrão são `/data` e `/outputs`. Contudo, os testes de fumaça (`tests/test_smoke.py`) e o comando `clfbench doctor` também devem passar quando executados nativamente no host Linux, onde `/outputs` na raiz `/` normalmente não existe.
- **Decisão**: O `clfbench doctor` verifica primeiro variáveis de ambiente (`CLFBENCH_DATA_DIR` / `CLFBENCH_OUTPUT_DIR`) ou flags (`--data-dir` / `--output-dir`); se não definidas, usa `/data` e `/outputs` quando existem no filesystem (ou dentro do container) e faz fallback automático para `./data` e `./outputs` quando executado nativamente no host.
- **Consequência**: O comando `clfbench doctor` funciona de forma transparente tanto dentro do container quanto nativamente no host, retornando código de saída `!= 0` sempre que o diretório de saída alvo não existir ou não tiver permissão de escrita.

---

## ADR-004: Multi-Stage Dockerfile com Estágios `base`, `cpu`, `gpu` e `dev`

- **Contexto**: O estágio `cpu` precisa ser enxuto (sem bibliotecas CUDA), enquanto o estágio `gpu` requer o runtime CUDA/cuDNN oficial da NVIDIA e o estágio `dev` adiciona ferramentas de qualidade, testes e Jupyter/TensorBoard.
- **Decisão**:
  - `base` parte de `ubuntu:22.04` e serve de base para `cpu` (instalando PyTorch CPU-only via `--index-url https://download.pytorch.org/whl/cpu`).
  - `gpu` parte de `nvidia/cuda:${CUDA_VERSION}-cudnn8-runtime-ubuntu22.04` com a mesma estrutura de diretórios, variáveis de ambiente e usuário não-root (`UID:GID`) do `base`.
  - `dev` herda de `gpu` e instala `.[dev]`, `jupyterlab` e `tensorboard`.
  - Em ambos (`cpu` e `gpu`), o `pyproject.toml` é copiado e instalado antes do diretório `src/` para maximizar o reaproveitamento do cache de camadas do Docker.
- **Consequência**: Imagens CPU enxutas, imagens GPU completas e rebuilds rápidos após alterações de código.

---

## ADR-005: Compatibilidade Dupla `pytest` e `unittest` nos Testes de Fumaça

- **Contexto**: O arquivo `tests/test_smoke.py` deve passar via `pytest` (no container `test` e em ambientes com `[dev]` instalado) e também poder ser validado nativamente em ambientes Python que ainda não tenham `pytest` instalado.
- **Decisão**: Estruturar `tests/test_smoke.py` utilizando `unittest.TestCase` (nativamente suportado e coletado pelo `pytest`).
- **Consequência**: Permite execução imediata tanto com `pytest --cov=clfbench` quanto com `python3 -m unittest discover -s tests -v`.
