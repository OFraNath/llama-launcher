# Llama-Launcher

Um launcher conveniente para o llama-server: um único `.bat`, sem instalação manual.

## Requisitos

- Windows com PowerShell 5.1 (já vem no Windows)
- Conexão com a internet na primeira execução, para o launcher baixar o llama.cpp, o uv e o Python
- Modelos `.gguf` dentro da pasta `Modelos`
- Opcional: GPU NVIDIA (`nvidia-smi`) e Tailscale

## Uso

1. Coloque o `iniciar_llama.bat` numa pasta própria e execute-o. Na primeira vez ele oferece instalar o que faltar (llama.cpp, CUDA, uv e Python) dentro da subpasta `runtime`, sem alterar o sistema.
2. Crie `Modelos/<NomeDoModelo>/` (sem espaços; ex.: `Gemma-4`) e coloque o `.gguf` dentro.
3. Para visão, coloque na mesma pasta o arquivo `mmproj*`.
4. Abra o `iniciar_llama.bat` e escolha o modelo no menu. Pressione `Esc` duas vezes para encerrar o servidor e voltar ao menu.

## Aviso

As opções LAN e Tailscale deixam o servidor escutando em todas as interfaces, sem senha. Use apenas em redes confiáveis.

## Licença

[GPLv3](LICENSE)