# Plano de implementação: confiabilidade em Linux e macOS

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans para implementar este plano tarefa por tarefa. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tornar instalação, identificação e remoção de Nerd Fonts previsíveis e verificáveis em Linux e macOS.

**Architecture:** Preservar o instalador Bash autocontido e os backends brew, pacman e direct. O backend direct terá instalação isolada por família e manifesto de arquivos; os gerenciadores de pacotes conservarão seus próprios registros. Catálogos manterão nomes originais de pacotes e aliases explícitos, sem reconstrução por convenções destrutivas.

**Tech Stack:** Bash 3.2+, utilitários Unix disponíveis em Linux/macOS, curl ou wget, tar com suporte a xz, Make, ShellCheck, shfmt e GitHub Actions.

**Spec:** Avaliação solicitada nesta conversa: remoção segura; extração isolada; manifesto; downloads robustos; mapeamento de catálogos; seleção de backend; Makefile; documentação; testes Linux/macOS; CLI inválida; cache Homebrew. As decisões abaixo são propostas para implementação, não funcionalidades já entregues.

## Restrições globais

- Bash mínimo: 3.2. Não usar arrays associativos, `mapfile`, `wait -n` ou expansões exclusivas de Bash 4+.
- Preservar as ações existentes, IDs já aceitos e opções da CLI; novas validações retornam código 1 para argumentos inválidos, 2 para dependência/backend indisponível, 3 para seleção sem resultados, 4 para falha de instalação/remoção.
- Não alterar `scripts/install.ps1` nesta iniciativa.
- Não adicionar dependências de runtime como Python, jq ou banco de dados.
- Instalação direta é por usuário e não usa sudo. Nenhum teste automatizado deve escrever nas fontes reais do usuário.
- Preservar alterações locais existentes em `scripts/install.sh` e `tests/brew-names.sh`.
- `--dry-run` não cria pastas, arquivos de estado nem downloads de fontes; consulta de catálogo do gerenciador continua permitida.
- O script continua autocontido; tabelas necessárias em execução ficam incorporadas nele.
- Usar caminhos entre aspas, `read -r` e operações que preservem espaços. Rejeitar nomes de arquivos com newline/tab nos arquivos baixados para manter o formato de manifesto inequívoco.
- Testes padrão não acessam rede e não exigem root. Testes de integração reais ficam separados.

## Abordagem proposta e alternativas

1. **Recomendada:** manter os três backends, usar direct no automático em Linux e brew seguido de direct em macOS. Evita exigir Homebrew no Linux e preserva integração com gerenciadores quando pedida.
2. Usar direct por padrão nos dois sistemas: reduz diferenças, mas deixa de aproveitar o gerenciamento do Homebrew no macOS.
3. Preferir sempre o primeiro gerenciador presente: aproxima-se do comportamento atual, mas a presença do comando não demonstra compatibilidade do catálogo ou do pacote.

No Linux, `--backend pacman` e `--backend brew` continuam disponíveis quando suportados. Não alternar de backend silenciosamente depois de uma instalação parcialmente concluída.

## Arquivos e responsabilidades

| Arquivo | Mudança |
| --- | --- |
| `scripts/install.sh` | CLI, catálogos, seleção de backend, instalação direta e manifesto |
| `tests/run.sh` | Executar todos os testes de comportamento e reportar falhas |
| `tests/helpers.sh` | Criar fixtures, executáveis falsos e diretórios temporários |
| `tests/brew-names.sh` | Preservar e ampliar regressão de nomes Homebrew |
| `tests/cli.sh` | Argumentos, códigos de saída e dry-run |
| `tests/backends.sh` | Escolha de backend, aliases e cache por execução |
| `tests/direct.sh` | Arquivos instalados, manifesto, remoção e reinstalação |
| `tests/downloads.sh` | HTTP, timeout, retry, archive inválido e interrupção |
| `tests/makefile.sh` | Falhas de bootstrap e propagação de erros |
| `tests/integration.sh` | Instalação real opcional em ambiente descartável |
| `Makefile` | Bootstrap confiável e alvos test/lint/check |
| `.pre-commit-config.yaml` | Incluir testes Bash nas verificações |
| `.github/workflows/check.yml` | Matriz Linux/macOS |
| `README.md`, `CHANGELOG.md` | Contrato de suporte, uso e mudanças de comportamento |

## Foco da revisão

1. Instalações antigas sem manifesto: nunca atribuir arquivos ao instalador apenas por substring; coberto na tarefa 5.
2. Interrupção com downloads filhos ativos: aguardar/cancelar filhos e não deixar estado de sucesso incorreto; coberto na tarefa 6.
3. Colisões e nomes parecidos, como ubuntu/ubuntumono: remover somente a família selecionada; coberto na tarefa 5.
4. Catálogo remoto indisponível durante desinstalação: usar registro local do gerenciador; coberto na tarefa 3.
5. Diretório com espaços, XDG personalizado e diferenças GNU/BSD: mesmos resultados nos dois sistemas; coberto nas tarefas 4 e 8.

## Execução e sequência

Cada tarefa tem ciclo de teste vermelho → implementação mínima → teste verde, seguido da suíte completa existente naquele ponto. Criar um commit por tarefa após revisão do diff; não publicar nem fazer merge automaticamente. Executar em checkout isolado na implementação, preservando e levando as alterações locais relevantes.

### Tarefa 1: Base de testes e validação da CLI

**Arquivos:** criar `tests/run.sh`, `tests/helpers.sh`, `tests/cli.sh`; modificar `scripts/install.sh`.

**Interfaces:** `tests/run.sh` retorna 0 somente se todos os testes passarem. CLI valida backend contra `auto|brew|pacman|direct` antes de invocar funções; `NF_JOBS` e `--jobs` aceitam inteiros positivos.

- [ ] Criar helpers para executar o script como subprocesso, capturar stdout/stderr/status e montar PATH com dependências falsas. Redirecionar HOME/XDG apenas nos processos de teste.
- [ ] Escrever testes: backend desconhecido retorna 1 sem `command not found`; backend sem valor retorna 1; `NF_JOBS=0`, negativo ou texto retorna 1; ações conflitantes retornam 1; help/version funcionam sem dependências.
- [ ] Rodar `bash tests/cli.sh` e confirmar falhas pelos comportamentos acima.
- [ ] Implementar validação central após parsing, incluindo valores da variável de ambiente. Deduplicar pedidos de fontes preservando sua ordem.
- [ ] Remover variáveis sem uso `OPT_NO_COLOR` e `OPT_YES`; preservar o efeito de `--no-color` e a aceitação documentada de `--yes` como opção reservada.
- [ ] Verificar `bash tests/run.sh`, `bash -n scripts/install.sh` e `git diff --check`; registrar commit `fix: validate installer arguments consistently`.

### Tarefa 2: Seleção de backend e dependências por plataforma

**Arquivos:** modificar `scripts/install.sh`; criar `tests/backends.sh`.

**Interfaces:** `resolve_backend REQUESTED` define `RESOLVED_BACKEND`; automático Linux escolhe direct, automático macOS tenta brew compatível e depois direct. Pedido explícito indisponível retorna 2.

- [ ] Escrever testes com uname e gerenciadores falsos: Linux com brew presente escolhe direct; Darwin com brew apto escolhe brew; Darwin sem brew escolhe direct; OS desconhecido e backend explícito indisponível falham com diagnóstico.
- [ ] Cobrir pacman ausente, curl ausente com wget presente, ambos ausentes, tar sem suporte xz e modo interativo sem fzf. Help/version não passam por essas verificações.
- [ ] Rodar `bash tests/backends.sh` e verificar vermelho antes de alterar produção.
- [ ] Implementar seleção e checagem das dependências necessárias à ação: desinstalação direta não deve exigir downloader. Validar extração xz com fixture incorporada pequena, sem depender de opções de versão GNU.
- [ ] Para brew explícito em Linux, consultar metadados de suporte do Homebrew instalado e produzir erro claro quando o cask não for suportado; não proibir casks somente pelo OS.
- [ ] Falha em um backend explícito não aciona fallback. Diagnóstico deve informar backend escolhido e alternativa quando houver.
- [ ] Executar suíte e registrar commit `fix: resolve supported backends by platform`.

### Tarefa 3: Catálogos com nomes originais, aliases e cache

**Arquivos:** modificar `scripts/install.sh`, `tests/brew-names.sh`, `tests/backends.sh`.

**Interfaces:** `load_font_catalog` mantém IDs públicos e mapa ID→pacote original em variáveis globais da execução; `brew_id_to_cask ID` e `pacman_id_to_pkg ID` consultam o mapa e falham se não houver correspondência. Nenhuma conversão chama nova busca remota.

- [ ] Criar regressões de instalação/dry-run para `font-zed-mono-nerd-font`, `font-fira-code-nerd-font` e pacote Pacman com nome não reconstruível. Validar argumentos e resultado do instalador, além de contar buscas no limite externo.
- [ ] Testar que listagem de instalados e desinstalação funcionam com busca remota falhando; obter nomes originais do inventário local nesses fluxos.
- [ ] Cobrir aliases existentes como cascadiacode/caskaydiacove, sourcecodepro/saucecodepro e sharetechmono/shuretechmono; uma fonte selecionada por dois aliases é instalada uma vez.
- [ ] Rodar os testes e observar falhas de lookup, cache ou alias.
- [ ] Capturar catálogo no processo principal para evitar perder estado em command substitution. Armazenar registros delimitados e usar lookup exato compatível com Bash 3.2; não usar arrays associativos.
- [ ] Unificar o catálogo estático direct e seu mapeamento de assets em uma tabela incorporada, com aliases separados. Verificar os nomes contra a release oficial durante a implementação; não inventar capitalização como fallback.
- [ ] Propagar erro de lookup antes de chamar gerenciadores com argumento vazio. Consultar o catálogo disponível no máximo uma vez por execução; inventário instalado tem cache separado.
- [ ] Rodar suíte e registrar commit `fix: preserve backend package names and cache catalogs`.

### Tarefa 4: Instalação direta isolada e estado transacional

**Arquivos:** modificar `scripts/install.sh`; criar `tests/direct.sh`.

**Interfaces:** `direct_font_dir` retorna `~/Library/Fonts` no macOS ou `${XDG_DATA_HOME:-$HOME/.local/share}/fonts` no Linux. Cada família pertence a `FONT_ROOT/NerdFonts/ID/`; manifesto `FONT_ROOT/NerdFonts/ID/.nerdfonts-manifest`.

**Formato do manifesto:** primeira linha `nerdfonts-manifest-v1`; segunda `id<TAB>ID`; terceira `asset<TAB>ASSET`; quarta `source<TAB>URL`; demais `file<TAB>CAMINHO_RELATIVO`. Não executar/sourcear o arquivo. Registrar versão concreta somente se identificada; não chamar `latest` de versão concreta.

- [ ] Criar fixture tar.xz com fontes ttf/otf, README/licença e arquivos aninhados. Testar caminho com espaços e XDG customizado; somente fontes entram no destino.
- [ ] Testar arquivo vazio, archive sem fontes, caminhos absolutos, `..`, links simbólicos/hard links e nomes com tab/newline: falhar sem modificar instalação anterior.
- [ ] Rodar `bash tests/direct.sh` e confirmar vermelho.
- [ ] Extrair em staging privado; inspecionar entradas antes da extração e recusar links ou caminhos que escapem dele. Preservar caminhos relativos dos arquivos de fonte.
- [ ] Montar a árvore final e manifesto no mesmo filesystem do destino. Publicar por rename; se houver instalação anterior, preservar backup até a nova árvore estar publicada e reverter em falha. Impedir dois processos de alterar a mesma família com lock por mkdir e limpeza em trap.
- [ ] Só emitir sucesso depois de validar arquivos e publicar manifesto. Execuções repetidas pulam família apenas se manifesto válido e todos os arquivos existirem; estado incompleto gera diagnóstico e permite reinstalação segura.
- [ ] Executar suíte e registrar commit `fix: isolate direct font installations with manifests`.

### Tarefa 5: Inventário e desinstalação por propriedade

**Arquivos:** modificar `scripts/install.sh`, `tests/direct.sh`, `tests/cli.sh`.

**Interfaces:** `direct_list_installed_fonts` e `direct_is_font_installed ID` usam somente manifestos válidos. `direct_uninstall_fonts IDS...` remove somente arquivos registrados dentro da pasta gerenciada da família.

- [ ] Escrever testes com ubuntu e ubuntumono instalados, arquivos externos com nomes parecidos, caminhos com espaços, manifesto adulterado e arquivo gerenciado ausente.
- [ ] Cobrir instalação antiga sem manifesto: preservar arquivos, emitir orientação de instalação não gerenciada e não incluí-la como removível em `--uninstall all`.
- [ ] Verificar que `--dry-run --uninstall` descreve os arquivos da família e não altera disco. Falha de remoção deve entrar em `FAILED_FONTS` e retornar 4.
- [ ] Rodar testes e confirmar vermelho.
- [ ] Substituir buscas por substring e `echo | xargs rm`. Validar ID, cabeçalho, caminhos relativos e ausência de symlinks no caminho antes de remover qualquer arquivo.
- [ ] Em manifesto inválido ou caminho externo, recusar toda a remoção daquela família; manter estado para diagnóstico. Remover pastas vazias; preservar arquivos desconhecidos e avisar quando restarem.
- [ ] Remover manifesto somente após remoção bem-sucedida dos arquivos registrados. Não adotar nem migrar arquivos antigos automaticamente; documentar reinstalação gerenciada sem apagá-los.
- [ ] Rodar suíte e registrar commit `fix: uninstall only files owned by the installer`.

### Tarefa 6: Downloads, concorrência e interrupções

**Arquivos:** modificar `scripts/install.sh`; criar `tests/downloads.sh`.

**Interfaces:** `download_asset URL DEST` retorna status não zero em HTTP/timeout/transferência incompleta; logs identificam família e etapa. Downloads limitados a `OPT_JOBS`; processos filhos e temporários pertencem à execução atual.

- [ ] Criar testes com curl/wget falsos: HTTP 404 sem retry, 503 transitório com retry e sucesso, timeout, download truncado, arquivo inválido e falha de extração. Confirmar ausência de manifesto de sucesso nas falhas.
- [ ] Testar teto de concorrência e instalação parcial: duas famílias concluem, uma falha; retorno 4 lista somente a falha e preserva as concluídas.
- [ ] Testar SIGINT/SIGTERM com filhos ativos: códigos 130/143, filhos encerrados e aguardados, staging/locks limpos, instalação anterior preservada.
- [ ] Rodar `bash tests/downloads.sh` para confirmar vermelho.
- [ ] Implementar até 3 tentativas totais para falhas transitórias, timeout de conexão de 15 s e duração máxima de 300 s por tentativa. Exibir causa do erro; não silenciar stderr do tar.
- [ ] Implementar equivalência curl/wget com detecção das opções suportadas; limitar retries manualmente se necessário. HTTP permanente não deve ser repetido.
- [ ] Registrar PIDs sem `wait -n`, aguardar seus resultados e cancelar somente filhos desta execução. Usar traps de saída e sinais que também limpem staging e locks.
- [ ] Atualizar cache fontconfig uma vez após mudanças reais no Linux; avisar se falhar. Ausência de fc-cache não invalida a cópia das fontes; macOS não depende dele.
- [ ] Rodar suíte e registrar commit `fix: handle download failures and interrupted jobs`.

### Tarefa 7: Makefile e verificações locais

**Arquivos:** modificar `Makefile`, `.pre-commit-config.yaml`; criar `tests/makefile.sh`.

**Interfaces:** `make test` executa `bash tests/run.sh`; `make lint` executa ShellCheck e shfmt em scripts/testes; `make check` depende de ambos. `make run` continua sem exigir ambiente de desenvolvimento.

- [ ] Escrever testes de bootstrap usando comandos falsos: curl falha; instalador falha; brew recém-instalado está fora do PATH; pre-commit falha. Nenhum fluxo pode imprimir sucesso após falha nem ocultar status não zero.
- [ ] Rodar `bash tests/makefile.sh` e confirmar vermelho.
- [ ] Separar download e execução do bootstrap Homebrew, verificar cada etapa e limpar o script temporário. Não executar conteúdo vazio após falha do curl.
- [ ] Após bootstrap, localizar brew nos prefixos oficiais e propagar seu shellenv ao processo que precisa dele. Garantir ordem de `dev-install`, inclusive com make paralelo, sem pré-requisitos concorrentes dependentes de brew.
- [ ] Adicionar os alvos test/lint/check e incluir `tests/*.sh` nos hooks de ShellCheck/shfmt. Resolver os quatro diagnósticos encontrados; supressões locais somente se houver justificativa específica.
- [ ] Rodar `make check` e `git diff --check`; registrar commit `fix: propagate setup failures and add project checks`.

### Tarefa 8: CI, integração real e documentação

**Arquivos:** criar `.github/workflows/check.yml`, `tests/integration.sh`; modificar `README.md`, `CHANGELOG.md`.

**Interfaces:** CI executa checks sem rede de testes em Ubuntu e macOS; macOS usa explicitamente `/bin/bash` para validar Bash 3.2, Linux executa Bash recente. Integração real é manual via workflow_dispatch e usa uma única família pequena em diretório temporário.

- [ ] Configurar matriz Ubuntu/macOS, instalar ferramentas de lint e rodar `make check`. Usar actions com versões verificadas na implementação; não tratar uname falso como validação real de macOS.
- [ ] Fazer `tests/integration.sh` instalar uma família direct no HOME temporário, verificar arquivos/manifesto, repetir instalação, listar e remover. Comparar com sentinela externa preservada. Limpar tudo ao sair.
- [ ] Adicionar integração Homebrew no macOS e Pacman em ambiente Arch descartável; testar nomes reais e instalação/remoção sem alterar máquina pessoal. Separar erros de rede de regressões da suíte determinística.
- [ ] Documentar backends automáticos/explícitos, Bash mínimo, dependências por ação, fzf apenas interativo, destinos Linux/macOS, XDG, manifestos e arquivos antigos não gerenciados.
- [ ] Documentar tentativas/timeouts, instalação parcial, códigos de saída, cancelamento, custo de `--all`, exemplos por plataforma e comandos de desenvolvimento. Corrigir PATH Homebrew para Linux/Intel/Apple Silicon.
- [ ] Registrar no changelog a mudança do automático no Linux, remoção por manifesto e nomes corretos dos pacotes.
- [ ] Rodar `make check`, integração direct nos dois sistemas e revisar os resultados dos backends reais. Registrar commit `ci: verify font installer on linux and macos`.

## Critérios de conclusão

- [ ] Instalar → listar → repetir instalação → desinstalar funciona em Linux e macOS reais.
- [ ] Remover ubuntu preserva ubuntumono e todos os arquivos externos ao manifesto.
- [ ] Caminhos com espaços e XDG personalizado passam na suíte.
- [ ] Instalação interrompida/inválida não publica manifesto de sucesso nem destrói instalação anterior.
- [ ] Erros de rede/HTTP/extração e dependências aparecem com causa e status documentado.
- [ ] Pacotes Homebrew/Pacman usam nomes originais; catálogo disponível é consultado uma vez por execução.
- [ ] CLI inválida não executa funções desconhecidas; dry-run não altera arquivos.
- [ ] ShellCheck, shfmt e suíte passam na matriz; falhas ou integrações não executadas são explicitamente reportadas.
- [ ] Revisar diff final, documentação e compatibilidade antes de propor merge. Nenhuma declaração de suporte real ao macOS se somente testes simulados estiverem disponíveis.

## Ordem e limites

Executar 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. O maior risco está nas tarefas 4–6; concluir seus testes antes de avançar à validação externa. Não incluir novos gerenciadores apt/dnf, atualização automática de fontes ou reformulação do PowerShell. Este plano não autoriza apagar arquivos antigos sem manifesto, publicar releases ou fazer merge.
