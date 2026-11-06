# Documentação de Containerização (Docker & Compose)

Este documento detalha a arquitetura de containers do **`clfbench`**, variáveis de ambiente, gerenciamento de volumes, atualização de dependências e procedimentos de depuração.

---

## 1. Arquitetura Multi-Stage do `Dockerfile`

O [`Dockerfile`](../Dockerfile) utiliza *multi-stage builds* (sintaxe BuildKit `docker/dockerfile:1.6`) com quatro estágios:

```text
ubuntu:22.04
  └── base (sistema + Python + usuário não-root UID:GID + diretórios /data, /outputs, /cache)
        └── cpu (PyTorch CPU-only + dependências base + pacote clfbench)

nvidia/cuda:${CUDA_VERSION}-cudnn8-runtime-ubuntu22.04
  └── gpu (sistema + CUDA/cuDNN runtime + usuário não-root + PyTorch CUDA + pacote clfbench)
        └── dev (herda de gpu + extras [dev]: pytest, ruff, black, pre-commit, jupyterlab, tensorboard)
```

### Detalhes dos Estágios

| Stage | Base | Uso Recomendado | Características |
| :--- | :--- | :--- | :--- |
| **`base`** | `ubuntu:22.04` | Camada fundacional para CPU | Instala dependências nativas (`git`, `libgl1`, `libglib2.0-0`, `build-essential`, fontes para `matplotlib`), cria o usuário não-root `clfbench` (`UID:GID`) e prepara `/workspace`, `/data`, `/outputs` e `/cache`. |
| **`cpu`** | `base` | Máquinas sem GPU / CI leve | Instala wheels PyTorch CPU-only (`https://download.pytorch.org/whl/cpu`), dependências do `pyproject.toml` em camada cacheada e o pacote `clfbench`. |
| **`gpu`** | `nvidia/cuda:${CUDA_VERSION}-cudnn8-runtime-ubuntu22.04` | Treinamento e inferência com GPU | Runtime oficial CUDA + cuDNN 8 sobre Ubuntu 22.04, wheels PyTorch compilados para CUDA (`cu121` por padrão) e pacote `clfbench`. |
| **`dev`** | `gpu` | Desenvolvimento interativo, testes e ferramentas | Inclui `pytest`, `pytest-cov`, `ruff`, `black`, `pre-commit`, `jupyterlab` e `tensorboard`. Comando padrão: `bash`. |

### Boas Práticas Implementadas
- **Cache de camadas otimizado**: As wheels do PyTorch e as dependências declaradas em `pyproject.toml` são instaladas antes da cópia do diretório `src/`. Modificações no código-fonte reconstroem apenas a camada final em poucos segundos.
- **Execução não-root**: Todos os estágios finais executam sob `USER ${UID}:${GID}`, garantindo que artefatos gravados em `/outputs` pertençam ao usuário do host.
- **Caches isolados**: `TORCH_HOME=/cache/torch` e `HF_HOME=/cache/huggingface` evitam downloads repetidos de pesos pré-treinados (`timm`/TorchVision/HuggingFace) entre execuções.
- **Healthcheck integrado**: O script [`docker/healthcheck.py`](../docker/healthcheck.py) valida periodicamente a integridade do pacote e a permissão de escrita em `/outputs`.

---

## 2. Serviços do `docker-compose.yml`

O arquivo [`docker-compose.yml`](../docker-compose.yml) (Compose v2) define cinco serviços:

1. **`clfbench`** *(padrão)*:
   - Usa o stage `gpu` e reserva todas as GPUs NVIDIA disponíveis via `deploy.resources.reservations.devices`.
   - Exemplo: `docker compose run --rm clfbench clfbench doctor`.
2. **`clfbench-cpu`** *(profile: `cpu`)*:
   - Usa o stage `cpu` com `CLFBENCH_FORCE_CPU=1`.
   - Exemplo: `docker compose --profile cpu run --rm clfbench-cpu clfbench doctor`.
3. **`dev`** *(profile: `dev`)*:
   - Usa o stage `dev` com *bind mounts* do código-fonte (`./src`, `./tests`, `./configs`, `./scripts`) para edição ao vivo sem rebuild.
   - Exemplo: `make docker-shell` (ou `docker compose --profile dev run --rm dev`).
4. **`test`** *(profile: `test`)*:
   - Executa `pytest --cov=clfbench --cov-report=term-missing -v` usando o stage `dev` sem exigir reserva de hardware GPU (funciona em hosts com ou sem GPU).
   - Exemplo: `make docker-test`.
5. **`tensorboard`** *(profile: `tools`)*:
   - Expõe o servidor TensorBoard na porta `6006` lendo `/outputs` em modo somente-leitura (`:ro`).
   - Exemplo: `make tensorboard`.

---

## 3. Variáveis do `.env`

O arquivo `.env` é gerado automaticamente por `make setup` a partir de [`.env.example`](../.env.example):

| Variável | Padrão | Descrição |
| :--- | :--- | :--- |
| `UID` | `1000` (auto via `make setup`) | UID do usuário no host Linux. |
| `GID` | `1000` (auto via `make setup`) | GID do usuário no host Linux. |
| `DATA_DIR` | `./data` | Caminho no host montado em `/data:ro` no container. |
| `OUTPUT_DIR` | `./outputs` | Caminho no host montado em `/outputs` (leitura e escrita). |
| `CUDA_VISIBLE_DEVICES` | `all` | Índices das GPUs visíveis (ex.: `0`, `0,1`, ou vazio para ocultar). |
| `SHM_SIZE` | `8gb` | Tamanho do `/dev/shm` para workers do PyTorch `DataLoader`. |
| `IMAGE_TAG` | `0.1.0` | Tag aplicada às imagens construídas (`clfbench:<tag>-gpu`). |
| `PYTHON_VERSION` | `3.10` | Versão do Python usada nos argumentos de build. |
| `CUDA_VERSION` | `12.1.1` | Tag da imagem base `nvidia/cuda:<CUDA_VERSION>-cudnn8-runtime-ubuntu22.04`. |
| `TORCH_VERSION` | `2.3.1` | Versão do pacote `torch` instalada no build. |
| `TORCHVISION_VERSION` | `0.18.1` | Versão do pacote `torchvision` instalada no build. |
| `CUDA_WHEEL_TAG` | `cu121` | Índice de wheels CUDA do PyTorch (`cu118`, `cu121`, `cu124`). |
| `TENSORBOARD_PORT` | `6006` | Porta do host mapeada para o serviço `tensorboard`. |
| `WANDB_API_KEY` | *(vazio)* | Chave de API opcional para Weights & Biases. |

---

## 4. Volumes e Persistência

| Origem (Host / Volume) | Destino no Container | Modo | Propósito |
| :--- | :--- | :--- | :--- |
| `${DATA_DIR:-./data}` | `/data` | `ro` (somente leitura) | Protege os datasets originais contra modificação acidental. |
| `${OUTPUT_DIR:-./outputs}` | `/outputs` | `rw` (leitura/escrita) | Armazena logs, métricas, gráficos e checkpoints gerados. |
| `./configs` | `/workspace/configs` | `rw` | Permite alterar arquivos YAML de configuração sem rebuild. |
| `clfbench_torch_cache` | `/cache/torch` | `rw` (volume nomeado) | Cache persistente de pesos do PyTorch / `timm`. |
| `clfbench_hf_cache` | `/cache/huggingface` | `rw` (volume nomeado) | Cache persistente de modelos do HuggingFace Hub. |

---

## 5. Como Customizar Localmente (`docker-compose.override.yml`)

Para apontar para um disco externo de datasets, limitar o uso de GPUs específicas ou expor portas adicionais sem modificar o `docker-compose.yml` versionado:

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
```

O arquivo `docker-compose.override.yml` está no `.gitignore` e é carregado automaticamente pelo Docker Compose v2.

---

## 6. Como Atualizar Versões de CUDA e PyTorch

Para atualizar a versão do CUDA ou do PyTorch:

1. Edite as variáveis correspondentes no seu `.env`:
   ```dotenv
   CUDA_VERSION=12.4.1
   TORCH_VERSION=2.4.0
   TORCHVISION_VERSION=0.19.0
   CUDA_WHEEL_TAG=cu124
   ```
2. Reconstrua a imagem:
   ```bash
   make docker-build
   make doctor
   ```

---

## 7. Como Debugar

- **Inspecionar ambiente completo**:
  ```bash
  make doctor
  ```
- **Abrir shell interativo com código montado**:
  ```bash
  make docker-shell
  ```
- **Testar fallback para CPU mesmo em máquina com GPU**:
  ```bash
  docker compose run --rm -e CLFBENCH_FORCE_CPU=1 clfbench clfbench doctor
  ```
- **Executar healthcheck manualmente dentro do container**:
  ```bash
  make docker-run CMD="python /workspace/docker/healthcheck.py"
  ```
