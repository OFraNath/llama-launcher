# Llama-Launcher

Um launcher conveniente para o llama-server.

## Requisitos

- Windows com PowerShell 5.1 (já vem no Windows)
- `llama-server.exe` de uma versão recente do [llama.cpp](https://github.com/ggml-org/llama.cpp/releases), na mesma pasta do script
- Modelos `.gguf` dentro da pasta `Modelos`
- Opcional: GPU NVIDIA (`nvidia-smi`), Tailscale e [uv](https://docs.astral.sh/uv/) (para o Open WebUI)

## Uso

1. Coloque o `iniciar_llama.bat` dentro da mesma pasta onde estiver `llama-server.exe`.
2. Crie a pasta `Modelos`.
3. Dentro de `Modelos`, crie a pasta referente ao nome do modelo (Ex.: `Gemma 4`) e coloque o `.gguf` dentro dela.
3. Execute o `iniciar_llama.bat`. Ele detectará os modelos caso tenham sido organizados da forma que essa seção apresenta.

## Aviso

As opções LAN e Tailscale deixam o servidor escutando em todas as interfaces, sem senha. Use apenas em redes confiáveis.

## Licença

[GPLv3](LICENSE)