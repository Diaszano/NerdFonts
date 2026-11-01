# Verificação da implementação Linux/macOS

Plano: [confiabilidade Linux/macOS](2026-11-01-linux-macos-reliability.md).

## Evidências locais

- `make check`: 12 arquivos de testes de comportamento, sintaxe Bash, ShellCheck e shfmt aprovados.
- Suíte completa aprovada também no Bash 3.2.0 oficial, compilado em `/tmp` no Linux.
- Integração real direct em HOME temporário: download, instalação, inventário, repetição e remoção aprovados; sentinela externa preservada.
- `make run-all` executado pelo usuário em Linux: retorno 0 em 317,7 segundos. Verificação posterior: catálogo com 72 famílias e inventário gerenciado com 72 famílias.
- Revisão independente identificou quatro problemas importantes; todos foram reproduzidos antes da correção e cobertos por regressões: inventário Pacman incluindo pacotes não relacionados, perda de links/FIFOs na reparação, dependências indevidas em consultas direct offline e falta de retry após HTTP 200 com transferência interrompida.
- Foram adicionados testes de SIGINT/SIGTERM para curl e wget, limite de concorrência, rollback de publicação, falha de remoção, links e caminhos inválidos em arquivos.

## Decisões e limites

- Trabalho numa branch do checkout atual: o worktree nativo criado pelo ambiente ficou fora da área gravável do sandbox. As alterações locais iniciais foram preservadas.
- Um commit consolidado substitui os commits por tarefa previstos no plano; o histórico de execução por tarefa foi registrado durante o trabalho.
- O suporte xz é validado ao abrir o arquivo baixado, antes da publicação, em vez de usar um arquivo binário incorporado ao instalador. A falta de suporte aparece na etapa de extração.
- Compatibilidade dos casks é verificada pelo próprio Homebrew com `install --cask --dry-run`, em vez de interpretar manualmente metadados sujeitos a mudança.
- Manifestos corrompidos impedem substituição e remoção. Reparar arquivos ausentes só é automático quando o manifesto ainda é válido e não existem arquivos desconhecidos.
- O catálogo direct contém assets conferidos na release oficial v3.5.1. Nomes não publicados não geram URLs por adivinhação; o alias legado `roboto` aponta para `robotomono`.
- Python 3 é usado somente como driver do teste de sinais, para iniciar processos que possam receber SIGINT. Não é dependência de runtime do instalador.
- Execução nativa macOS, integração Homebrew e integração Pacman não foram realizadas nesta máquina. Os workflows de CI estão preparados para essas verificações; compatibilidade com Bash 3.2 no Linux não prova integração nativa macOS.
- Ajuste menor adiado: o aviso de inventário inválido sugere reinstalação mesmo quando o manifesto está corrompido. A operação continua recusada com segurança e o README explica a inspeção manual.
