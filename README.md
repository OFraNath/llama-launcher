# Llama-Launcher

Um launcher conveniente para o llama-server.

## Requisitos

- Windows com PowerShell 5.1 (já vem no Windows)
- `llama-server.exe` de uma versão recente do [llama.cpp](https://github.com/ggml-org/llama.cpp/releases), na mesma pasta do script
- Modelos `.gguf` dentro da pasta `Modelos`
- Opcional: GPU NVIDIA (`nvidia-smi`), Tailscale e [uv](https://docs.astral.sh/uv/) (para o Open WebUI)

## Uso

1. Coloque o `iniciar_llama.bat` ao lado do `llama-server.exe`.
2. Crie a pasta `Modelos` e coloque seus `.gguf` nela.
3. Dê dois cliques no `.bat`.

## Aviso

As opções LAN e Tailscale deixam o servidor escutando em todas as interfaces, sem senha. Use apenas em redes confiáveis.

## Licença

[GPLv3](LICENSE)