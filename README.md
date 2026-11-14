# Llama-Launcher

**Um launcher conveniente para o llama-server.**

É um único `.bat`, sem instalação manual: você escolhe o modelo no menu, ajusta o que quiser e ele sobe o servidor.

Vou corrigir os bugs que aparecerem, mas **não prometo novos recursos nem atualizações**. Se encontrar algo errado ou quiser dar um feedback, abra uma issue aqui no repositório.

## Requisitos

- Windows com PowerShell 5.1 (já vem no Windows)
- Conexão com a internet na primeira execução, para o launcher baixar o llama.cpp, o uv e o Python
- Modelos `.gguf` dentro da pasta `Modelos`
- Opcional: GPU NVIDIA (`nvidia-smi`) e Tailscale

## Como usar

1. Coloque o `iniciar_llama.bat` em uma pasta própria e execute-o. Na primeira vez, ele oferece instalar o que faltar (llama.cpp, CUDA, uv e Python) na subpasta `runtime`, sem alterar o sistema.
2. Crie a pasta `Modelos/<NomeDoModelo>/` (sem espaços; ex.: `Gemma-4`) e coloque o `.gguf` nela.
3. Para organizar por categoria, crie uma pasta acima da do modelo: `Modelos/<Categoria>/<NomeDoModelo>/` (ex.: `Modelos/RPG/Gemma-4`). A categoria aparece no menu como uma pasta; os modelos de `Modelos/<NomeDoModelo>/` ficam na lista principal.
4. Para usar visão, coloque o arquivo `mmproj*` na mesma pasta do modelo.
5. Execute o `iniciar_llama.bat` e escolha o modelo no menu. Pressione `Esc` duas vezes para encerrar o servidor e voltar ao menu.

## Geração de imagem (opcional)

Funciona **somente com o [SwarmUI](https://github.com/mcmonkeyprojects/SwarmUI)**, que não é instalado pelo launcher.

Depois, na configuração do modelo, selecione **Geração de Imagem**, pressione `Enter` e escolha o `launch-windows.bat` da pasta onde o SwarmUI está instalado.

## Aviso

**Use por sua conta e risco. Não me responsabilizo por qualquer uso incorreto ou indevido.**

As opções LAN e Tailscale deixam o servidor escutando em todas as interfaces, sem senha, então use apenas em redes confiáveis. O modo agente dá ao modelo acesso ao PC onde o llama está rodando: ele pode ler e gravar arquivos e executar comandos. Ative-o apenas com a rede em modo local.

## 📜 Licença

Este projeto é distribuído sob a licença **GNU GPL v3.0**. Versões modificadas e projetos derivados precisam continuar de código aberto sob a mesma licença e dar o crédito aos autores originais.

Veja o arquivo [LICENSE](LICENSE) para os termos completos.
