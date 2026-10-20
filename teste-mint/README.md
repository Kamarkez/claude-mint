# teste-mint: teste automático do Mint

Confere se tudo no Linux Mint do notebook (Galaxy Book, Cinnamon) continua funcionando **antes e depois de cada mudança** e gera um relatório em texto para mandar ao Claude. Só lê: nenhum item do teste muda configuração.

O que ele confere (96 itens, `teste-mint --lista` mostra todos):

- os 74 itens do antigo `~/.local/share/personalizacoes/verificar-personalizacoes.sh` (S-Pen, teclado virtual, LibreOffice no modo tablet, acessibilidade, visual e painel, apps, Hearthstone, Buds3), com os mesmos nomes. Se aquele arquivo mudar depois de 15/10, o teste segue a versão nova: os itens novos entram no fim do relatório, os que mudaram lá usam o resultado de lá e os que saíram de lá deixam de ser conferidos (aparecem em "Não são mais conferidos");
- sistema: espaço em disco, pacotes quebrados, serviços com falha (sistema e usuário), Cinnamon rodando, kernel novo e reinício pendente, internet;
- área de trabalho: ícones na tela (`nemo-desktop` aberto), Nemo ignorando o Hidamari, Lixeira ao lado da HBO, atalhos apontando para programas que existem;
- início automático e ajudantes: cada programa do `~/.config/autostart` existe e os scripts de `~/.local/bin` e `~/.local/share/personalizacoes` não têm erro de sintaxe;
- planilha FINANÇAS (Drive): atalho e ajudante `financas-drive`, macros liberadas, Drive aparecendo em Rede;
- backup das personalizações recente e o próprio teste automático ligado.

Itens marcados como **aviso** dependem do que está aberto ou são lembretes; eles aparecem no relatório mas não contam como falha.

## Instalar (uma vez, sem sudo)

```bash
bash ~/Downloads/teste-mint.sh --instalar
```

Isso instala o comando `~/.local/bin/teste-mint`, liga o teste automático e já roda a primeira conferência, que gera `~/Downloads/relatorio-teste-mint-<data>.txt`.

## Quando ele roda

| Quando | Como | O que acontece |
|---|---|---|
| Uma mudança feita por script do Claude | o script se embrulha sozinho no `teste-mint --mudanca` (abaixo) | foto antes, a mudança, conferência depois e relatório em Downloads |
| Uma mudança feita com um comando avulso | `teste-mint --mudanca "Nome" -- COMANDO` | igual ao de cima |
| Depois de atualizações do sistema ou de Flatpak | unidade `teste-mint-atualizacoes.path` do systemd do usuário | espera o apt/Flatpak terminar, confere em silêncio e só avisa (notificação + relatório) se algo parou |
| 2 min depois de entrar na sessão | `~/.config/autostart/teste-mint.desktop` | igual ao de cima |
| Quando você quiser | `teste-mint` | confere e compara com o teste anterior |

Um item que para logo depois da mudança ganha até 60 s para voltar sozinho (por exemplo, os ícones reabrindo) antes de entrar no relatório como "parou de funcionar". O relatório separa o que **parou com esta mudança**, o que **voltou a funcionar**, o que **já falhava antes**, o que **não é mais conferido** e os avisos, e traz os pacotes instalados e os erros do sistema registrados no período.

## Regra para scripts de mudança

Todo script que muda algo no Mint começa com estas linhas, logo depois do `#!/bin/bash`:

```bash
if [ -z "${TESTE_MINT_DENTRO:-}" ] && [ "$(id -u)" -ne 0 ] && [ -x "$HOME/.local/bin/teste-mint" ]; then
  exec "$HOME/.local/bin/teste-mint" --mudanca "Nome da mudança" -- bash "$0" "$@"
fi
```

O script roda dentro do teste, que tira a foto de antes, roda o script e confere depois, mesmo se ele der erro ou for interrompido com Ctrl+C. Se o `teste-mint` não estiver instalado, o script roda normal.

Mudança feita à mão, em vários passos: `teste-mint --antes "Nome"` antes de começar e `teste-mint --depois` no fim.

## Outros comandos

```bash
teste-mint --lista          # itens conferidos
teste-mint --ajuda          # uso completo
teste-mint --desinstalar    # desliga o teste automático (os resultados ficam guardados)
```

## Onde ficam as coisas

- Comando: `~/.local/bin/teste-mint` (entra no `backup-personalizacoes`).
- Resultados (os 60 mais novos): `~/.local/share/personalizacoes/teste-mint/resultados/`; o último em `ultimo.tsv`.
- Relatórios: `~/Downloads/relatorio-teste-mint-<data>.txt`.
- Registro de cada rodada: `~/.cache/teste-mint.log`.

## Acrescentar um item

Cada item é uma linha em `definir_itens` no `teste-mint.sh`:

```bash
item grupo.nome f "Título que aparece no relatório" "comando que sai 0 quando está tudo certo"
```

`f` faz o item contar como falha; `a`, só como aviso. O comando pode escrever um detalhe com `det "texto"` e sair com `aviso "texto"` para virar aviso. Teste antes com `TESTE_MINT_EXTRA=arquivo-com-itens.sh teste-mint`.
