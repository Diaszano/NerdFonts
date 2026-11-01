# NerdFonts

Instalador de Nerd Fonts para Linux e macOS, com seleção interativa e instalação por usuário. O script Bash é autocontido: não exige clonar o projeto inteiro para funcionar.

## Uso rápido

```bash
# Linux: instalação direta; macOS: Homebrew quando disponível.
bash scripts/install.sh --fonts firacode,jetbrainsmono

# Seleção interativa (requer fzf).
bash scripts/install.sh

# Listar, simular e instalar todas as famílias.
bash scripts/install.sh --list
bash scripts/install.sh --fonts hack --dry-run
make run-all
```

`--all` instala o catálogo completo do backend escolhido. Algumas famílias são grandes; reserve espaço e tempo para downloads e extração. O padrão é quatro downloads simultâneos, configurável com `--jobs 2` ou `NF_JOBS=2`.

## Plataformas e dependências

| Ambiente | Backend automático | Destino direto |
| --- | --- | --- |
| Linux | direct | `${XDG_DATA_HOME:-$HOME/.local/share}/fonts/NerdFonts/ID` |
| macOS | brew; direct se brew ou catálogo indisponível | `~/Library/Fonts/NerdFonts/ID` |

Bash 3.2 ou posterior é o mínimo. O instalador evita recursos exclusivos de Bash 4+. A CI executa a suíte com o Bash do sistema no macOS e com Bash recente no Linux; a disponibilidade de um workflow não substitui resultados de execução em cada plataforma.

Para instalar diretamente, é necessário `curl` **ou** `wget` e `tar` com suporte a `.tar.xz`. Instale também `xz` se o seu tar depender de um descompressor externo. Listar o catálogo direto, consultar o inventário e remover fontes não exigem downloader. `fzf` só é necessário no modo interativo. No Linux, `fc-cache` atualiza o cache após alterações quando disponível; falhas geram aviso e podem ser corrigidas com `fc-cache -f`.

A instalação direta não usa sudo. Pacman pode solicitar sudo para operações no sistema. Homebrew e Pacman precisam estar instalados e disponíveis no PATH quando selecionados explicitamente.

```bash
# Debian/Ubuntu: dependências da instalação direta e seleção interativa.
sudo apt-get install curl xz-utils fontconfig fzf

# Arch Linux: dependências da instalação direta.
sudo pacman -S --needed curl tar xz fontconfig fzf

# macOS, se você usa Homebrew.
brew install fzf
```

## Backends e nomes de fontes

```bash
bash scripts/install.sh --backend direct --fonts hack
bash scripts/install.sh --backend brew --fonts zedmono
bash scripts/install.sh --backend pacman --fonts firacode
```

As opções são `auto`, `direct`, `brew` e `pacman`. Um pedido explícito indisponível falha com diagnóstico; não muda silenciosamente de backend. O automático no Linux usa direct mesmo se Homebrew estiver instalado. No macOS, falha de catálogo Homebrew permite escolher direct antes de começar a instalação; uma instalação parcial nunca provoca fallback automático.

Os catálogos dos gerenciadores mantêm os nomes originais dos pacotes, incluindo hífens. O catálogo disponível é consultado uma vez por execução. Desinstalação usa o inventário local, sem depender de busca remota. O Homebrew verifica a capacidade de instalar os casks selecionados antes da instalação real.

Os IDs são os valores de `--list`. Aliases conhecidos continuam aceitos, como `saucecodepro` → `sourcecodepro`, `caskaydiacove` → `cascadiacode` e `shuretechmono` → `sharetechmono`. IDs desconhecidos geram aviso; se nenhum pedido for válido, a execução falha. Nomes repetidos ou aliases da mesma família são deduplicados.

O catálogo direto é uma tabela incorporada, conferida contra os arquivos oficiais da release. Ele não inventa URLs para fontes desconhecidas. A disponibilidade pode mudar em releases futuras; use um backend com catálogo atualizado ou atualize o script quando necessário.

## Inventário e remoção

Escolha o mesmo backend usado na instalação:

```bash
bash scripts/install.sh --backend direct --installed
bash scripts/install.sh --backend direct --uninstall hack --dry-run
bash scripts/install.sh --backend direct --uninstall hack
bash scripts/install.sh --backend direct --uninstall all
```

Sem valor após `--uninstall`, o instalador abre a seleção interativa das fontes instaladas.

Cada família instalada diretamente tem sua própria pasta e um arquivo `.nerdfonts-manifest`, que registra ID, asset, URL de origem e caminhos relativos das fontes. Apenas arquivos `.ttf` e `.otf` são instalados. Downloads e extração são feitos em staging; arquivos inválidos, links e caminhos que escapem da pasta são recusados antes de publicar a instalação.

O manifesto determina a propriedade dos arquivos: a remoção não procura trechos de nomes em outras fontes. Arquivos desconhecidos dentro da pasta da família são preservados e impedem uma substituição que poderia apagá-los. Um manifesto inválido bloqueia remoção e substituição; inspecione a pasta e faça backup antes de corrigir o estado manualmente. Um arquivo registrado ausente permite reinstalação quando o restante do manifesto é válido e não há arquivos desconhecidos.

**Instalações antigas sem manifesto não são adotadas nem removidas automaticamente.** Elas podem permanecer nas pastas antigas e não aparecem como gerenciadas em `--installed`. Uma nova instalação gerenciada pode coexistir com elas; revise duplicatas manualmente, sem apagar fontes de outros programas. A remoção pelo backend direct não remove fontes gerenciadas pelo Homebrew ou Pacman.

`XDG_DATA_HOME`, quando definido, precisa ser um caminho absoluto. No macOS, o destino direto continua sendo `~/Library/Fonts`.

## Falhas, downloads e cancelamento

O download direto faz até três tentativas para falhas transitórias de rede, HTTP 408/429 e erros 5xx. HTTP permanente, como 404, falha sem repetir. Cada tentativa tem timeout de conexão/inatividade de 15 segundos e duração máxima de 300 segundos. A extração inválida apresenta o diagnóstico do tar.

Uma falha numa família não remove as outras concluídas. A execução lista as famílias que falharam e retorna código 4. Tente novamente o mesmo comando: instalações completas são puladas. Ctrl+C/SIGTERM cancela os processos da execução e limpa staging e locks; uma instalação anterior é preservada ou restaurada se a publicação falhar.

| Código | Significado |
| --- | --- |
| 0 | Ação concluída, inclusive sem alterações necessárias |
| 1 | Argumentos inválidos |
| 2 | Dependência, plataforma ou backend indisponível |
| 3 | Seleção sem fontes válidas/disponíveis |
| 4 | Falha ao instalar ou remover uma ou mais famílias |
| 130 / 143 | Interrupção por SIGINT / SIGTERM |

`--dry-run` não baixa fontes nem cria arquivos; consultas ao catálogo do gerenciador ainda podem ocorrer. `--quiet` omite mensagens de progresso do instalador; diagnósticos dos programas externos podem continuar aparecendo. `--no-color` e `NO_COLOR=1` desativam as cores. `--yes` permanece reservado, sem efeito adicional.

```bash
bash scripts/install.sh --help
bash scripts/install.sh --version
```

## Desenvolvimento e testes

```bash
make test       # Suíte offline, sem sudo, fontes reais ou rede.
make lint       # Bash syntax, ShellCheck e shfmt.
make check      # Testes e lint.
make dev-install # Homebrew, pre-commit e hooks; altera o ambiente de desenvolvimento.
make run RUN_ARGS='--backend direct --fonts hack --dry-run'
```

As ferramentas de desenvolvimento são `make`, ShellCheck, shfmt e Python 3 (usado apenas pelo teste de sinais). A configuração de pre-commit cobre scripts e testes. O instalador continua utilizável sem essas ferramentas.

O workflow `Linux and macOS checks` executa a suíte nas duas plataformas. A execução manual (`workflow_dispatch`) também testa download direto real em HOME temporário, Homebrew num runner macOS descartável e Pacman num container Arch descartável. Os testes normais substituem somente dependências externas e exercitam o script como subprocesso.

```bash
# Integração real opcional: baixa uma família pequena em pasta temporária,
# verifica repetição/inventário/remoção e preserva uma fonte externa de controle.
bash tests/integration.sh
```

Para configurar o PATH do Homebrew, use o prefixo da sua instalação:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"             # macOS Apple Silicon
eval "$(/usr/local/bin/brew shellenv)"                # macOS Intel
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" # Linux
```

Consulte a [instalação oficial do Homebrew](https://docs.brew.sh/Installation) e a [release oficial das Nerd Fonts](https://github.com/ryanoasis/nerd-fonts/releases/latest).

O script Windows `scripts/install.ps1` permanece no projeto; esta revisão e a matriz descrita acima cobrem Linux e macOS.

## Licença

O projeto usa a licença [GPL-3.0](LICENSE). As fontes distribuídas pelo projeto Nerd Fonts têm suas próprias licenças; consulte o projeto de origem.
