# Plano de Correção e Simplificação Ponytail (NerdFonts)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminar 6.300+ linhas de complexidade desnecessária, código morto, abstrações prematuras e duplicações no repositório NerdFonts, restaurando a simplicidade nativa em Bash e PowerShell.

**Architecture:** 
1. Eliminar artefatos de build concatenados (`dist/`) e backends fantasmas do Linux (`apt`, `dnf`, `zypper`).
2. Trocar estruturas de dados reimplementadas na mão (hash maps em strings, loops de trim) por funcionalidades nativas do Bash e utilitários Unix.
3. Consolidar os 14 módulos fragmentados em um script Bash direto, portável e autocontido (`scripts/install.sh`).
4. Simplificar `scripts/install.ps1` substituindo 4 backends, reflection GDI+ e loops de menu por comandos nativos do PowerShell e Shell COM (`CopyHere`).

**Tech Stack:** Bash (compatível macOS/Linux), PowerShell 5.1+ (Windows), Git, Makefile.

**Spec:** Ponytail Audit Report (18 pontos identificados: `net: -6314 lines, -3 deps possible`).

## Global Constraints

- Preservar a funcionalidade principal para o usuário final: listar fontes, instalar fonte específica, instalar todas as fontes e seleção interativa com fzf (Bash) ou console/GUI (PowerShell).
- Manter compatibilidade com macOS e distribuições Linux suportadas (Homebrew, Pacman e Direct GitHub Releases).
- Não quebrar a API de linha de comando (`--all`, `--fonts`, `--list`, `--installed`, `--uninstall`, `--backend`, `--dry-run`, `--quiet`, `--no-color`, `-h/--help`).
- Seguir os princípios YAGNI (You Aren't Gonna Need It) e soluções mínimas viáveis.

---

### Task 1: Limpeza de Artefato de Build e Verificação no Makefile (Pontos 1 e 15)

**Files:**
- Delete: `dist/install.sh`
- Modify: `.gitignore`
- Modify: `Makefile:33-41,110-135`

**Interfaces:**
- Consumes: Arquivos existentes no repositório.
- Produces: `.gitignore` limpo e `Makefile` sem alvos `build` e `bundle-check`.

- [ ] **Step 1: Remover o bundle dist/install.sh e atualizar .gitignore**

Executar remoção do diretório `dist/` e garantir que qualquer diretório `dist/` futuro seja ignorado pelo git:
```bash
git rm -rf dist/ 2>/dev/null || rm -rf dist/
```
No `.gitignore`, substituir:
```gitignore
# dist/install.sh is committed on purpose (curl|bash entrypoint)
dist/*
!dist/install.sh
```
Por:
```gitignore
dist/
```

- [ ] **Step 2: Remover os alvos de bundle do Makefile**

No `Makefile`, deletar as variáveis de bundle e os alvos `build` e `bundle-check`:
Remover:
```makefile
# Path to the installer bundle generator
BUILD_SCRIPT := scripts/build.sh

# Path to the generated single-file installer bundle
BUNDLE_SCRIPT := dist/install.sh

# Temporary directory used by the bundle freshness check
CHECK_TMP_DIR := .tmp/bundle-check
```
E remover os alvos `build` e `bundle-check`:
```makefile
# -----------------------------------------------------------------------------
# Installer bundle (dist/)
# -----------------------------------------------------------------------------
.PHONY: build
build: ## Build the self-contained installer bundle (dist/install.sh)
	@bash "$(BUILD_SCRIPT)"

.PHONY: bundle-check
bundle-check: ## Fail if dist/install.sh is out of date compared to a fresh rebuild
...
```

- [ ] **Step 3: Verificar que o Makefile continua funcionando**

Run: `make help`
Expected: Exibir lista de alvos sem erros de sintaxe ou referências quebradas.

- [ ] **Step 4: Commit das mudanças da Task 1**

```bash
git add .gitignore Makefile
git commit -m "chore: remover bundle dist/install.sh e checks do makefile"
```

---

### Task 2: Eliminar Backends Fantasmas de Pacotes Linux (Ponto 4)

**Files:**
- Delete: `scripts/lib/backends/apt.sh`
- Delete: `scripts/lib/backends/dnf.sh`
- Delete: `scripts/lib/backends/zypper.sh`
- Modify: `scripts/lib/constants.sh:109`
- Modify: `scripts/lib/cli.sh:53,204,208`
- Modify: `scripts/lib/platform.sh:20,90,139`
- Modify: `scripts/install.sh:72,113-116`
- Modify: `scripts/build.sh:75-78`

**Interfaces:**
- Consumes: Módulos de backends.
- Produces: `BACKEND_AUTO_ORDER=(brew pacman direct)` sem referências a apt, dnf ou zypper.

- [x] **Step 1: Deletar os arquivos de backend que retornam catálogo vazio**

```bash
rm -f scripts/lib/backends/apt.sh scripts/lib/backends/dnf.sh scripts/lib/backends/zypper.sh
```

- [x] **Step 2: Atualizar a lista de backends e help/CLI**

Em `scripts/lib/constants.sh`:
```bash
# De:
BACKEND_AUTO_ORDER=(brew dnf pacman zypper apt)
# Para:
BACKEND_AUTO_ORDER=(brew pacman direct)
```

Em `scripts/lib/cli.sh`:
Substituir ocorrências de `--backend auto|brew|apt|dnf|pacman|zypper|direct` por:
`--backend auto|brew|pacman|direct`.

Em `scripts/lib/platform.sh`:
Atualizar comentários e mensagem de erro do `resolve_backend` para listar apenas `brew, pacman, direct`.

Em `scripts/install.sh`:
Remover o `source` dos arquivos deletados:
```bash
  source "$SCRIPT_DIR/lib/backends/apt.sh"
  source "$SCRIPT_DIR/lib/backends/dnf.sh"
  source "$SCRIPT_DIR/lib/backends/zypper.sh"
```

- [x] **Step 3: Testar listagem e resolução de backends**

Run: `bash scripts/install.sh --help`
Expected: Exibe `--backend auto|brew|pacman|direct`.

- [x] **Step 4: Commit das mudanças da Task 2**

```bash
git add scripts/lib/ scripts/install.sh scripts/build.sh
git commit -m "refactor: remover backends inativos apt, dnf e zypper"
```

---

### Task 3: Eliminar Wrappers Triviais e Indireções Desnecessárias (Pontos 9, 16 e 17)

**Files:**
- Modify: `scripts/lib/log.sh:33-35,90-92`
- Modify: `scripts/lib/util.sh:160-176`
- Modify: `scripts/lib/deps.sh:29-86`

**Interfaces:**
- Consumes: Chamadas de checagem de binários e logging.
- Produces: Checagens diretas com `command -v` e sem hooks especulativos de dry-run.

- [ ] **Step 1: Eliminar wrappers is_command_installed e print_error em log.sh**

Substituir usages de `is_command_installed "cmd"` por `command -v cmd >/dev/null 2>&1`.
Substituir usages de `print_error "msg"` diretamente por `die 1 "msg"`.
Remover as funções `is_command_installed` e `print_error` de `scripts/lib/log.sh`.

- [ ] **Step 2: Eliminar hooks especulativos em util.sh**

Remover do final de `scripts/lib/util.sh`:
```bash
backend_dry_run_install() {
  echo "[dry-run] Would install ${1}."
}

backend_dry_run_uninstall() {
  echo "[dry-run] Would uninstall ${1}."
}
```

- [ ] **Step 3: Simplificar checagem de dependências em deps.sh**

Substituir o arquivo `scripts/lib/deps.sh` pelo formato enxuto direto:
```bash
#!/usr/bin/env bash
# shellcheck shell=bash

ensure_fzf_available() {
  if command -v fzf >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$RESOLVED_BACKEND" == "brew" ]]; then
    print_warn "fzf não está instalado. Tentando instalar via Homebrew..."
    if brew install fzf; then
      print_success "fzf instalado com sucesso."
      return 0
    fi
  fi

  die 2 "fzf é necessário para o modo interativo. Instale-o manualmente ou use --all / --fonts."
}

check_dependencies() {
  case "$RESOLVED_BACKEND" in
  brew)
    command -v brew >/dev/null 2>&1 || die 2 "Homebrew não encontrado: https://brew.sh"
    ;;
  direct)
    (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1) && command -v tar >/dev/null 2>&1 || \
      die 2 "O backend direct requer curl/wget e tar."
    ;;
  esac
}
```

- [ ] **Step 4: Executar verificação dos comandos com flags**

Run: `bash scripts/install.sh --version`
Expected: Exibe versão sem erros.

- [ ] **Step 5: Commit das mudanças da Task 3**

```bash
git add scripts/lib/log.sh scripts/lib/util.sh scripts/lib/deps.sh
git commit -m "refactor: eliminar wrappers triviais e hooks especulativos"
```

---

### Task 4: Substituir Map Manual em String e Subshell Tempfiles (Pontos 6 e 11)

**Files:**
- Modify: `scripts/lib/util.sh:26-108`
- Modify: `scripts/lib/backends/brew.sh`
- Modify: `scripts/lib/backends/pacman.sh`
- Modify: `scripts/lib/fonts.sh:68-103`

**Interfaces:**
- Consumes: Mapeamento de nome de fonte para pacote e catálogo de fontes.
- Produces: Resolução de pacote via convenção determinística e captura de catálogo em variável direta.

- [ ] **Step 1: Substituir map_set/map_get/map_has por convenção determinística de nomes**

No Homebrew, todo cask de Nerd Font segue o padrão estrito `font-<id>-nerd-font`.
No Pacman, os pacotes seguem `ttf-<id>-nerd`.
Portanto, não é necessário manter um dicionário dinâmico em string `key|value` nem iterar por linhas a cada busca.
Remover `map_set`, `map_get` e `map_has` de `scripts/lib/util.sh`.
Em `scripts/lib/backends/brew.sh`, simplificar `brew_id_to_cask`:
```bash
brew_id_to_cask() {
  printf 'font-%s-nerd-font' "$1"
}
```
E remover todas as referências a `BREW_FONT_MAP`.
Em `scripts/lib/backends/pacman.sh`, remover referências a `PACMAN_FONT_MAP`.

- [ ] **Step 2: Eliminar o workaround de mktemp/cat/rm em fonts.sh**

Como os maps globais em string foram eliminados, as funções `load_font_catalog` e `load_installed_fonts` em `scripts/lib/fonts.sh` não precisam mais gravar stdout em arquivos temporários para contornar subshells.
Substituir por:
```bash
load_font_catalog() {
  if [[ "$CACHED_FONT_LIST_BACKEND" == "$RESOLVED_BACKEND" && -n "$CACHED_FONT_LIST" ]]; then
    return 0
  fi
  CACHED_FONT_LIST=$("${RESOLVED_BACKEND}_list_fonts")
  CACHED_FONT_LIST_BACKEND="$RESOLVED_BACKEND"
}

load_installed_fonts() {
  if [[ -n "$CACHED_INSTALLED_LIST" ]]; then
    return 0
  fi
  CACHED_INSTALLED_LIST=$("${RESOLVED_BACKEND}_list_installed_fonts")
}
```

- [ ] **Step 3: Testar execução de listagem de fontes**

Run: `bash scripts/install.sh --list`
Expected: Lista de fontes obtida diretamente sem criar ou depender de arquivos temporários no `/tmp`.

- [ ] **Step 4: Commit das mudanças da Task 4**

```bash
git add scripts/lib/util.sh scripts/lib/backends/ scripts/lib/fonts.sh
git commit -m "refactor: remover hash map manual em string e tempfiles de catalog"
```

---

### Task 5: Simplificar CLI, Trimming e Funções Duplicadas (Pontos 8, 12 e 14)

**Files:**
- Modify: `scripts/lib/fonts.sh:244-340`
- Modify: `scripts/lib/cli.sh:118-137,232-258`

**Interfaces:**
- Consumes: Entradas de linha de comando e despacho de fontes.
- Produces: Validação limpa de argumentos e pipelines concisos de texto.

- [ ] **Step 1: Enxugar normalize_font_list em cli.sh**

Substituir os 20 linhas de loops manuais com substrings por uma linha Unix canônica:
```bash
normalize_font_list() {
  printf '%s' "$1" | tr -d ' ' | tr ',' '\n' | grep -v '^$'
}
```

- [ ] **Step 2: Simplificar validate_arg_combination em cli.sh**

Substituir a matriz combinatória redundante verificando contagem de ações principais mutuamente exclusivas:
```bash
validate_arg_combination() {
  local actions=0
  [[ "$OPT_ALL" == 1 ]] && ((actions++))
  [[ -n "$OPT_FONTS" ]] && ((actions++))
  [[ "$OPT_LIST" == 1 ]] && ((actions++))
  [[ "$OPT_INSTALLED" == 1 ]] && ((actions++))
  [[ -n "$OPT_UNINSTALL_MODE" ]] && ((actions++))

  if ((actions > 1)); then
    die 1 "Apenas uma ação (--all, --fonts, --list, --installed, --uninstall) pode ser especificada."
  fi
}
```

- [ ] **Step 3: Eliminar wrappers de uma linha e unificar filtros em fonts.sh**

Em `scripts/lib/fonts.sh`:
- Remover `install_all_fonts`, `prompt_install_selected_fonts` e `uninstall_all_fonts` (fazer chamadas diretas a `dispatch_install_fonts` e `dispatch_uninstall_fonts` no `main.sh`).
- Unificar o filtro de validação de lista de nomes (`filter_font_list` compartilhado entre install e uninstall) em vez de manter duas funções idênticas de 25 linhas com loop e grep.

- [ ] **Step 4: Testar parsing com flags válidas e inválidas**

Run: `bash scripts/install.sh --list --all`
Expected: Falha com código 1 informando que apenas uma ação pode ser especificada.
Run: `bash scripts/install.sh --fonts "hack, firacode" --dry-run`
Expected: Normaliza os nomes sem erros de espaço.

- [ ] **Step 5: Commit das mudanças da Task 5**

```bash
git add scripts/lib/cli.sh scripts/lib/fonts.sh scripts/lib/main.sh
git commit -m "refactor: simplificar normalização de argumentos e filtros de fontes"
```

---

### Task 6: Simplificar Backend Direct (Ponto 5)

**Files:**
- Modify: `scripts/lib/backends/direct.sh`

**Interfaces:**
- Consumes: Downloads de assets do repositório oficial `ryanoasis/nerd-fonts`.
- Produces: Download direto e descompactação limpa em `~/.local/share/fonts` ou `~/Library/Fonts`.

- [ ] **Step 1: Remover o sistema complexo de cache com TTL e markers**

Em `scripts/lib/backends/direct.sh`:
- Eliminar o cabeçalho de metadados `#META|epoch|tag` e cálculo manual de expiração em horas.
- Obter a lista de fontes via API oficial ou lista estática conhecida das fontes oficiais.
- Simplificar `direct_install_fonts`: baixar o `.tar.xz` da release com `curl -sL` ou `wget -qO-` e extrair com `tar -xJ -C "$target_dir"`.
- Simplificar detecção de fonte instalada checando se existem arquivos correspondentes no diretório de fontes do usuário (`find "$target_dir" -iname "*${id}*"`).

- [ ] **Step 2: Testar o backend direct em modo dry-run**

Run: `bash scripts/install.sh --backend direct --fonts "hack" --dry-run`
Expected: Executa sem tentar ler ou gravar caches defeituosos.

- [ ] **Step 3: Commit das mudanças da Task 6**

```bash
git add scripts/lib/backends/direct.sh
git commit -m "refactor: simplificar download direto de fontes sem cache de TTL complexo"
```

---

### Task 7: Consolidar Arquivos Bash em Script Único Autocontido (Ponto 3)

**Files:**
- Create/Rewrite: `scripts/install.sh`
- Delete: `scripts/lib/` (todos os módulos restantes)
- Delete: `scripts/build.sh`

**Interfaces:**
- Consumes: Toda a lógica enxuta final de instalação em Bash.
- Produces: Um único `scripts/install.sh` de ~300 linhas, sem necessidade de bundler, sem subshell workarounds.

- [ ] **Step 1: Integrar a lógica consolidada em scripts/install.sh**

Mesclar os módulos essenciais (constantes, cores, detecção de OS, backends brew/pacman/direct, CLI e main) diretamente dentro de `scripts/install.sh`.
Tornar o script completamente independente e autocontido (eliminando a necessidade de `scripts/build.sh` e da pasta `scripts/lib/`).

- [ ] **Step 2: Deletar scripts/build.sh e scripts/lib/**

```bash
rm -rf scripts/build.sh scripts/lib/
```

- [ ] **Step 3: Validar funcionamento completo do scripts/install.sh autocontido**

Run: `bash scripts/install.sh --help`
Expected: Ajuda completa formatada.
Run: `bash scripts/install.sh --version`
Expected: Informação de versão.
Run: `bash scripts/install.sh --list`
Expected: Lista de fontes válidas.

- [ ] **Step 4: Commit das mudanças da Task 7**

```bash
git add scripts/
git commit -m "refactor: consolidar instalador bash em script único autocontido"
```

---

### Task 8: Simplificar Utilitários e Exceções no PowerShell (Pontos 13 e 18)

**Files:**
- Modify: `scripts/install.ps1:136-140,218-244`

**Interfaces:**
- Consumes: Tipos de exceção e manipulação de arrays/strings em PowerShell.
- Produces: Uso idiomático de operadores PowerShell (`-contains`, `.ToLowerInvariant()`, `throw`).

- [ ] **Step 1: Remover class NfUsageException**

Deletar:
```powershell
class NfUsageException : System.Exception {
    NfUsageException([string]$message) : base($message) { }
}
```
Substituir todas as ocorrências de `throw [NfUsageException]"mensagem"` por `throw "mensagem"`.

- [ ] **Step 2: Substituir funções auxiliares pelos operadores nativos do PowerShell**

Remover `ConvertTo-NfLowercase` e usar diretamente `$str.ToLowerInvariant()`.
Remover a função `Test-NfListContains` e usar diretamente o operador nativo `-contains`:
```powershell
# De:
if (Test-NfListContains $List $Value) { ... }
# Para:
if ($List -contains $Value) { ... }
```
Remover `Get-NfCanonicalIdsFromCsv` e usar:
```powershell
$Csv -split '\s*,\s*' | Where-Object { $_ }
```

- [ ] **Step 3: Testar sintaxe e validação do script PowerShell**

Run: `pwsh -Command "& ./scripts/install.ps1 -Help"` (se pwsh disponível) ou validar sintaxe de bloco.
Expected: Parsing limpo sem erros de classe ou funções ausentes.

- [ ] **Step 4: Commit das mudanças da Task 8**

```bash
git add scripts/install.ps1
git commit -m "refactor(powershell): remover classe de exceção e usar operadores nativos"
```

---

### Task 9: Simplificar Registro de Fontes e Menu Interativo no Windows (Pontos 7 e 10)

**Files:**
- Modify: `scripts/install.ps1:1200-1270,1563-1601`

**Interfaces:**
- Consumes: Arquivos de fonte baixados no Windows e seleção interativa.
- Produces: Instalação nativa via Shell COM e seleção via `Out-GridView` ou prompt simples.

- [ ] **Step 1: Substituir registro via HKCU / System.Drawing por Shell.Application**

Remover `Get-NfFontInternalName`, `Register-NfFontFile`, `Unregister-NfFontFilesById` e manipulação manual da chave `HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts`.
Instalar fontes usando a interface padrão do Windows Shell:
```powershell
function Install-NfFontNative {
    param([string]$FilePath)
    $shell = New-Object -ComObject Shell.Application
    $fontsFolder = $shell.Namespace(0x14) # 0x14 = Fonts folder
    $fontsFolder.CopyHere($FilePath, 0x10) # 0x10 = Yes to all / suppress prompt
}
```

- [ ] **Step 2: Substituir o menu interativo console manual de 40 linhas**

Substituir o loop manual de parsing de números em `Select-NfItemsInteractive` por:
```powershell
function Select-NfItemsInteractive {
    param([string[]]$Items, [string]$PromptTitle)
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        return ($Items | Out-GridView -Title $PromptTitle -OutputMode Multiple)
    }
    Write-Host $PromptTitle
    $Items | ForEach-Object { Write-Host " - $_" }
    $sel = Read-Host "Digite os nomes das fontes separados por vírgula"
    return ($sel -split '\s*,\s*' | Where-Object { $_ })
}
```

- [ ] **Step 3: Verificar estrutura do instalador PowerShell**

Run: conferir as linhas modificadas no `scripts/install.ps1`.
Expected: Eliminação de mais de 100 linhas de código complexo de registro e UI.

- [ ] **Step 4: Commit das mudanças da Task 9**

```bash
git add scripts/install.ps1
git commit -m "refactor(powershell): usar Shell.Application para fontes e simplificar menu"
```

---

### Task 10: Simplificar Arquitetura Multi-Backend no PowerShell (Ponto 2)

**Files:**
- Modify: `scripts/install.ps1`

**Interfaces:**
- Consumes: Gerenciamento de fontes no Windows.
- Produces: Suporte nativo focado (Winget ou Direct download) sem probe-caching e sem abstração de 4 vias redundante.

- [x] **Step 1: Eliminar as implementações redundantes de Scoop e Chocolatey**

O Windows 10 e 11 incluem nativamente o `winget`. A manutenção de 4 backends concorrentes com sistema de ranking, probing e caching gera mais de 900 linhas de código morto e duplicado.
Remover:
- Funções `*-NfScoop*`
- Funções `*-NfChoco*`
- Sistema de probe-caching dinâmico (`Probe-NfBackendCatalog`, `Set-NfCatalogCache`)
Manter suporte nativo ao `winget` e fallback para download direto do GitHub.

- [x] **Step 2: Reduzir scripts/install.ps1 para menos de 250 linhas**

Consolidar o fluxo do PowerShell com parâmetros equivalentes aos do script Bash:
- `-All`
- `-Fonts`
- `-List`
- `-DryRun`

- [x] **Step 3: Testar execução de parâmetros do PowerShell**

Run: Verificar argumentos e consistência do `scripts/install.ps1`.
Expected: Script limpo, legível e direto.

- [x] **Step 4: Commit das mudanças da Task 10**

```bash
git add scripts/install.ps1
git commit -m "refactor(powershell): simplificar backends e consolidar fluxo Windows"
```

---

## Verificação e Auditoria Final

Após a conclusão de todas as tarefas, executar:
1. `bash scripts/install.sh --help`
2. `bash scripts/install.sh --list`
3. Contagem total de linhas do repositório:
```bash
wc -l scripts/install.sh scripts/install.ps1 Makefile
```
Esperado: Repositório reduzido de ~8.290 linhas para menos de 1.000 linhas totais, mantendo 100% da utilidade real sem nenhum código morto.
