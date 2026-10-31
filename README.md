# Llama-Launcher

Um launcher conveniente para o llama-server: um único `.bat`, sem instalar nada.

## Requisitos

- Windows com PowerShell 5.1 (já vem no Windows)
- `llama-server.exe` de uma versão recente do [llama.cpp](https://github.com/ggml-org/llama.cpp/releases), na mesma pasta do script
- Modelos `.gguf` dentro da pasta `Modelos`
- Opcional: GPU NVIDIA (`nvidia-smi`), Tailscale e [uv](https://docs.astral.sh/uv/) (para o Open WebUI)

## Uso

1. Coloque o `iniciar_llama.bat` na mesma pasta do `llama-server.exe`.
2. Crie `Modelos/<NomeDoModelo>/` (sem espaços; ex.: `Gemma-4`) e coloque o `.gguf` dentro.
3. Para visão, coloque na mesma pasta o arquivo `mmproj*`.
4. Execute o `iniciar_llama.bat`. Pressione `Esc` duas vezes para encerrar o servidor e voltar ao menu.

## Aviso

As opções LAN e Tailscale deixam o servidor escutando em todas as interfaces, sem senha. Use apenas em redes confiáveis.

## Licença

[GPLv3](LICENSE)