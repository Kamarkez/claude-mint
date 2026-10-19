#!/bin/bash
# teste-mint: teste automático do Linux Mint do notebook. Confere se tudo continua funcionando antes e
# depois de cada mudança e gera um relatório para mandar ao Claude.
#
# Instalar (uma vez, sem sudo):  bash ~/Downloads/teste-mint.sh --instalar
#
# Uso:
#   teste-mint                              confere tudo agora e compara com o teste anterior
#   teste-mint --mudanca "Nome" -- COMANDO  confere antes, roda o COMANDO, confere depois e compara
#   teste-mint --antes "Nome"               só a foto de antes (mudança feita à mão)
#   teste-mint --depois                     confere e compara com a foto de antes
#   teste-mint --lista                      mostra os itens conferidos
#   teste-mint --desinstalar                tira o teste automático (os resultados ficam guardados)
# Sozinho (o --instalar liga): depois de atualizações do sistema ou de Flatpak e 2 min depois de entrar na
#   sessão, confere tudo em silêncio e só avisa (notificação + relatório em Downloads) se algo que
#   funcionava parou.
# Scripts de mudança feitos pelo Claude começam com estas linhas, que fazem o teste rodar sozinho:
#   if [ -z "${TESTE_MINT_DENTRO:-}" ] && [ "$(id -u)" -ne 0 ] && [ -x "$HOME/.local/bin/teste-mint" ]; then
#     exec "$HOME/.local/bin/teste-mint" --mudanca "Nome da mudança" -- bash "$0" "$@"
#   fi
# O teste só lê: nenhum item muda configuração. Resultados em ~/.local/share/personalizacoes/teste-mint/,
# relatórios em ~/Downloads/relatorio-teste-mint-<data>.txt, registro em ~/.cache/teste-mint.log.
# Inclui os 74 itens de ~/.local/share/personalizacoes/verificar-personalizacoes.sh (versão de 15/10/2026);
# se aquele arquivo mudar, os itens novos dele entram no relatório sozinhos.
# Saída: 0 = nada parou de funcionar; 1 = algo parou; 2 = uso errado ou outro teste rodando;
#   no --mudanca, se o COMANDO falhar, sai com o código dele.
# Criado em 19/10/2026 (thread "Teste automático do Mint", repositório Kamarkez/claude-mint).
set -uo pipefail

VERSAO="2026-10-19"
BIN="$HOME/.local/bin/teste-mint"
EU="$(readlink -f "${BASH_SOURCE[0]}")"
DADOS="${TESTE_MINT_DADOS:-$HOME/.local/share/personalizacoes/teste-mint}"  # TESTE_MINT_*: só para teste
RES="$DADOS/resultados"
LOG="${TESTE_MINT_LOG:-$HOME/.cache/teste-mint.log}"
LIMITE="${TESTE_MINT_LIMITE:-25}"   # segundos por item
ESPERA="${TESTE_MINT_ESPERA:-60}"   # quanto tempo um item que parou tem para voltar sozinho (programas reabrindo)
PAUSA="${TESTE_MINT_PAUSA:-5}"      # pausa entre o fim da mudança e a conferência
GUARDAR=60                          # quantos resultados guardar
UNIDADE="teste-mint-atualizacoes"
AUTOSTART="$HOME/.config/autostart/teste-mint.desktop"
LEGADO="$HOME/.local/share/personalizacoes/verificar-personalizacoes.sh"
LEGADO_SHA="a0afa6f4ae45681845e90152ec538ea54cc41f65a8769a08626eec5ae0daafac"  # 15/10/2026, já incluída abaixo
CARIMBO="$(date +%Y-%m-%d_%H%M%S)"
if [ -t 1 ]; then VERDE=$'\e[32m'; VERM=$'\e[31m'; AMAR=$'\e[33m'; NEG=$'\e[1m'; FIM=$'\e[0m'
else VERDE=""; VERM=""; AMAR=""; NEG=""; FIM=""; fi

log() { mkdir -p "$(dirname "$LOG")"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
morrer() { echo "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------------------
# Itens. item ID NIVEL TÍTULO COMANDO   NIVEL f: não passar = FALHA; a: não passar = só AVISO (depende do que
# está aberto ou é lembrete). O COMANDO roda com bash; sai 0 = OK, 42 = AVISO; o que escrever em >&3 vira o
# detalhe no relatório. Títulos dos 74 itens antigos ficam iguais aos de verificar-personalizacoes.sh.
# ---------------------------------------------------------------------------------------------------------
I_ID=(); I_NIVEL=(); I_TIT=(); I_CMD=(); I_GRP=(); GRUPO=""
declare -A IDX=()
grupo() { GRUPO="$1"; }
item() { IDX[$1]=${#I_ID[@]}; I_ID+=("$1"); I_NIVEL+=("$2"); I_TIT+=("$3"); I_CMD+=("$4"); I_GRP+=("$GRUPO"); }

# ajudantes usados pelos comandos (vão no TM_PRELUDIO para o bash de cada item, não para a mudança)
g()     { gsettings get "$1" "$2" 2>/dev/null; }
cin()   { gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon --method org.Cinnamon.Eval "$1" 2>/dev/null; }
det()   { printf '%s\n' "$*" >&3; }
aviso() { [ $# -eq 0 ] || det "$*"; return 42; }
py()    { python3 "$TM_PY" "$@"; }
# pgrep -f acharia o próprio teste-mint (ou quem o chamou) se o nome da mudança tiver o texto procurado
pgrep() {
  local out rc; out="$(command pgrep "$@")"; rc=$?
  [ $rc -eq 0 ] || return $rc
  out="$(awk -v p=" ${TM_PAIS:-} " 'index(p, " " $1 " ") == 0' <<<"$out")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

c_servicos() {
  local s; s="$(systemctl "$@" --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  [ -z "${s// /}" ] || { det "com falha: $s"; return 1; }
}
c_espaco() {
  local livre; livre="$(df -P -BG / 2>/dev/null | awk 'NR==2 {sub("G","",$4); print $4}')"
  [ -n "$livre" ] || { det "não consegui ler o espaço livre"; return 1; }
  det "$livre GB livres"
  [ "$livre" -ge 5 ] || return 1
  [ "$livre" -ge 10 ] || return 42
}
c_pacotes() { local s; s="$(dpkg --audit 2>&1)"; [ -z "$s" ] || { det "$(head -3 <<<"$s")"; return 1; }; }
c_reinicio() {
  [ -e /run/reboot-required ] || return 0
  aviso "o sistema pede para reiniciar ($(sort -u /run/reboot-required.pkgs 2>/dev/null | head -5 | tr '\n' ' '))"
}
c_kernel() {
  local uso novo; uso="$(uname -r)"
  novo="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
  det "em uso $uso${novo:+; mais novo instalado $novo}"
  [ -z "$novo" ] || [ "$novo" = "$uso" ] || return 42
}
c_internet() { local c; c="$(nmcli -t networking connectivity 2>/dev/null)"; det "${c:-o NetworkManager não respondeu}"; [ "$c" = full ]; }
c_cinnamon() {
  pgrep -u "$(id -u)" -x cinnamon >/dev/null || { det "o Cinnamon não está rodando"; return 1; }
  [ "${XDG_SESSION_TYPE:-x11}" = x11 ] || { det "sessão ${XDG_SESSION_TYPE}"; return 1; }
  det "Cinnamon $(cinnamon --version 2>/dev/null | awk '{print $2}')"
}
c_libreoffice() {
  command -v soffice >/dev/null || { det "soffice não encontrado"; return 1; }
  local v; v="$(dpkg-query -W -f='${Version}' libreoffice-core 2>/dev/null)"
  [ -n "$v" ] || v="$(flatpak info org.libreoffice.LibreOffice 2>/dev/null | sed -n 's/^ *Version: //p')"
  [ -n "$v" ] || { det "não achei o pacote do LibreOffice"; return 1; }
  det "versão $v"
}
c_icones() {
  case "$(g org.nemo.desktop desktop-layout)" in "'false::false'") det "ícones desligados nas configurações"; return 0 ;; esac
  pgrep -u "$(id -u)" -x nemo-desktop >/dev/null && return 0
  det "o programa dos ícones (nemo-desktop) está fechado: os ícones sumiram da tela"; return 1
}
hidamari_instalado() {
  [ -x ~/.local/bin/hidamari-com-icones ] || [ -d ~/.local/share/flatpak/app/io.github.jeffshee.Hidamari ] \
    || [ -d /var/lib/flatpak/app/io.github.jeffshee.Hidamari ]
}
c_nemo_hidamari() {
  hidamari_instalado || { det "Hidamari não instalado"; return 0; }
  g org.nemo.desktop ignored-desktop-handlers | grep -qi hidamari && return 0
  det "falta 'hidamari' em org.nemo.desktop ignored-desktop-handlers (os ícones somem ao reabrir)"; return 1
}
c_hidamari_aberto() {
  hidamari_instalado || { det "Hidamari não instalado"; return 0; }
  flatpak ps --columns=application 2>/dev/null | grep -qx io.github.jeffshee.Hidamari && return 0
  pgrep -af hidamari | grep -v hidamari-com-icones | grep -q . && return 0
  det "fechado"; return 1
}
c_flatpaks() {
  local lista falta="" a
  lista="$(flatpak list --app --columns=application 2>/dev/null)"
  for a in com.github.johnfactotum.Foliate com.github.xournalpp.xournalpp com.github.flxzt.rnote \
           io.github.jeffshee.Hidamari org.localsend.localsend_app org.qbittorrent.qBittorrent org.telegram.desktop; do
    grep -qx "$a" <<<"$lista" || falta+="$a "
  done
  [ -z "$falta" ] || { det "faltam: $falta"; return 1; }
}
c_financas() {
  [ -x ~/.local/bin/financas-drive ] || { det "falta ~/.local/bin/financas-drive"; return 1; }
  [ -f "$TM_DESK/FINANÇAS (Drive).desktop" ] || { det "falta o atalho FINANÇAS (Drive) na área de trabalho"; return 1; }
}
c_financas_macros() {
  grep 'oor:name="SecureURL"' ~/.config/libreoffice/4/user/registrymodifications.xcu 2>/dev/null | grep -q 'google-drive://' \
    && return 0
  det "a entrada some se alguém clicar OK em Segurança de macros; o atalho FINANÇAS (Drive) refaz ao abrir"; return 1
}
c_drive() {
  local conta m
  conta="$(grep -o 'FINANCAS_CONTA", "[^"]*' ~/.local/bin/financas-drive 2>/dev/null | sed 's/.*"//')"
  [ -n "$conta" ] || { det "não achei a conta do Google no ajudante financas-drive"; return 1; }
  m="$(timeout 15 gio mount -li 2>/dev/null)"
  grep -qi "google-drive://$conta" <<<"$m" && { det "Drive de $conta disponível em Rede"; return 0; }
  det "a conta $conta não aparece em Rede (Contas on-line)"; return 1
}
c_backup() {
  local d f dias
  d="$TM_DOWN/Claude Docs, Backups e Instruções/Backups"
  f="$(ls -t "$d"/personalizacoes-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$f" ] || { aviso "nenhum backup em $d"; return 42; }
  dias=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
  det "$(basename "$f") (de $dias dia(s) atrás)"
  [ "$dias" -le 14 ] || aviso "$(basename "$f") é de $dias dias atrás: rode backup-personalizacoes"
}

definir_itens() {
  X=~/.var/app/com.github.xournalpp.xournalpp/config/xournalpp

  grupo "Sistema"
  item sis.driver-samsung   f "Kernel em uso tem o driver Samsung"           "lsmod | grep -q samsung_galaxybook"
  item sis.bateria-80       f "Limite da bateria em 80%"                     "[ \$(cat /sys/class/power_supply/BAT1/charge_control_end_threshold) = 80 ]"
  item sis.bateria-regra    f "Regra permanente do limite de bateria"        "grep -q ' 80\$' /etc/tmpfiles.d/bateria-limite.conf"
  item sis.registros        f "Limite dos registros do sistema (200 MB)"     "grep -q 'SystemMaxUse=200M' /etc/systemd/journald.conf.d/limite.conf"
  item sis.rede-boot        f "Espera pela rede no boot desativada"          "[ \$(systemctl is-enabled NetworkManager-wait-online.service) = disabled ]"
  item sis.casper           f "casper-md5check silenciado"                   "[ \$(systemctl is-enabled casper-md5check.service) = masked ]"
  item sis.servicos         f "Nenhum serviço com falha"                     "c_servicos"
  item sis.servicos-usuario f "Nenhum serviço do usuário com falha"          "c_servicos --user"
  item sis.espaco           f "Espaço livre no disco (mínimo 10 GB)"         "c_espaco"
  item sis.pacotes          f "Nenhum pacote quebrado ou instalado pela metade" "c_pacotes"
  item sis.cinnamon         f "Cinnamon rodando (sessão X11)"                "c_cinnamon"
  item sis.kernel-novo      a "Usando o kernel mais novo instalado"          "c_kernel"
  item sis.reinicio         a "Sem reinício pendente"                        "c_reinicio"
  item sis.internet         a "Internet funcionando"                         "c_internet"

  grupo "Tela"
  item tela.protecao        f "Sem proteção de tela por inatividade"         "[ \"\$(g org.cinnamon.desktop.session idle-delay)\" = 'uint32 0' ]"
  item tela.bloqueio        f "Sem bloqueio automático"                      "[ \"\$(g org.cinnamon.desktop.screensaver lock-enabled)\" = false ]"
  item tela.escurecer       f "Sem escurecer na bateria"                     "[ \"\$(g org.cinnamon.settings-daemon.plugins.power idle-dim-battery)\" = false ]"

  grupo "S-Pen / tela de toque"
  item spen.libwacom        f "Cadastro da caneta no libwacom"               "libwacom-list-local-devices | grep -q 0x0135"
  item spen.wacom-config    f "Caneta no driver Wacom (config)"              "grep -q 'Driver \"wacom\"' /etc/X11/xorg.conf.d/72-galaxybook-spen.conf"
  item spen.wacom-uso       f "Caneta no driver Wacom (em uso)"              "xinput list | grep -q 'WCOM0134.*Stylus stylus'"
  item spen.menu            f "Menu da S-Pen rodando"                        "pgrep -f 'bin/spen-menu.py'"
  item spen.menu-login      f "Menu da S-Pen no login"                       "[ -f ~/.config/autostart/spen-menu.desktop ]"
  item spen.mapear          f "Caneta/toque presos à tela interna (login)"   "[ -f ~/.config/autostart/mapear-caneta-toque.desktop ]"

  grupo "Teclado virtual"
  item tec.onboard          f "Onboard rodando (ou fechado por você)"        "pgrep -f '^/usr/bin/python3 /usr/bin/onboard' || [ -f ~/.cache/onboard-fechado-por-voce ]"
  item tec.vigia            f "Vigia do teclado rodando e no login"          "pgrep -f 'bin/onboard-sempre' && grep -q onboard-sempre ~/.config/autostart/onboard-autostart.desktop"
  item tec.abrir-sozinho    f "Abrir sozinho ligado"                         "[ \"\$(g org.onboard.auto-show enabled)\" = true ]"
  item tec.filtro-fisico    f "Filtro de teclado físico ligado"              "[ \"\$(g org.onboard.auto-show tablet-mode-detection-enabled)\" = true ]"
  item tec.pausa            f "Pausa de 5 min"                               "[ \"\$(g org.onboard.auto-show hide-on-key-press-pause)\" = 300.0 ]"
  item tec.cinnamon-off     f "Teclado do Cinnamon desligado (evita dois teclados)" "[ \"\$(g org.cinnamon.desktop.a11y.applications screen-keyboard-enabled)\" = false ]"
  item tec.sensor-regra     f "Regra de leitura do sensor de modo tablet"    "grep -q 'Intel HID switches' /etc/udev/rules.d/70-sensor-modo-tablet.rules"
  item tec.sensor           f "Sensor de modo tablet legível"                "python3 -c \"import glob,os; [open('/dev/input/'+os.path.basename(d),'rb') for d in glob.glob('/sys/class/input/event*') if open(d+'/device/name').read().strip()=='Intel HID switches']\""
  item tec.modo-tablet      f "Ajudante do modo tablet rodando e no login"   "pgrep -f 'bin/modo-tablet-teclado' && [ -f ~/.config/autostart/modo-tablet-teclado.desktop ]"

  grupo "LibreOffice no modo tablet (dedo, S-Pen, teclado, macros)"
  item lo.toque             f "Ajudante de toque do LibreOffice rodando e no login" "pgrep -f '^python3 $HOME/.local/bin/toque-libreoffice' && [ -f ~/.config/autostart/toque-libreoffice.desktop ]"
  item lo.rolagem           f "Rolagem suave (mouse virtual do ajudante) presente" "xinput list | grep -q 'toque-libreoffice rolagem'"
  item lo.uinput            f "Permissão para criar o mouse virtual (/dev/uinput)" "[ -w /dev/uinput ]"
  item lo.spen              f "Menu da S-Pen deixa a caneta com o ajudante no LibreOffice" "grep -q 'quem cuida da caneta é o toque-libreoffice' ~/.local/bin/spen-menu.py"
  item lo.phone-x           f "Teclado virtual com X de fechar (layout Phone-X)" "g org.onboard layout | grep -q Phone-X && grep -q 'id=\"hide\" svg_id=\"AC10\"' ~/.local/share/onboard/layouts/Phone-X.onboard"
  # o antigo procurava só nos 120 primeiros caracteres da lista; o financas-drive põe o Drive no fim dela
  item lo.macros-area       f "Macros da Área de trabalho sem aviso (local confiável)" "grep 'oor:name=\"SecureURL\"' ~/.config/libreoffice/4/user/registrymodifications.xcu | grep -q '%C3%81rea%20de%20trabalho'"
  item lo.instalado         f "LibreOffice instalado"                        "c_libreoffice"

  grupo "Acessibilidade (o que faz o teclado perceber caixas de texto)"
  item a11y.sessao          f "Acessibilidade ligada na sessão"              "[ \"\$(g org.gnome.desktop.interface toolkit-accessibility)\" = true ] && grep -q GNOME_ACCESSIBILITY ~/.xsessionrc"
  item a11y.repasse         f "Repassada a apps que se reiniciam sozinhos"   "grep -q dbus-update-activation-environment ~/.xsessionrc"
  item a11y.flatpak         f "Apps Flatpak com acessibilidade (Qt/GTK)"     "flatpak override --user --show | grep -q QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1"
  item a11y.firefox         f "Firefox com rolagem por toque"                "flatpak override --user --show org.mozilla.firefox | grep -q MOZ_USE_XINPUT2=1"
  item a11y.claude-interm   f "Intermediário do Claude"                      "grep -q force-renderer-accessibility ~/.local/bin/claude-desktop"
  # o antigo falhava com o Claude fechado; agora só falha se ele estiver aberto sem a acessibilidade
  item a11y.claude-aberto   f "Claude aberto com acessibilidade"             "if pgrep -f '^/usr/lib/claude-desktop/claude-desktop' >/dev/null; then pgrep -f '^/usr/lib/claude-desktop/claude-desktop --force-renderer-accessibility'; else det 'Claude fechado'; fi"
  item a11y.claude-atalho   f "Atalho do Claude chama o intermediário"       "grep -q '^Exec=claude-desktop' ~/.local/share/applications/com.anthropic.Claude.desktop"
  item a11y.chrome          f "Intermediários do Chrome (Chrome + apps web)" "grep -q force-renderer-accessibility ~/.local/bin/google-chrome-stable && grep -q force-renderer-accessibility ~/.local/bin/google-chrome && grep -q force-renderer-accessibility ~/.local/share/applications/google-chrome.desktop"
  item a11y.spotify         f "Intermediário do Spotify"                     "grep -q force-renderer-accessibility ~/.local/bin/spotify"

  grupo "Visual e painel"
  item vis.tema             f "Tema Mint-Y-Dark-Aqua"                        "[ \"\$(g org.cinnamon.desktop.interface gtk-theme)\" = \"'Mint-Y-Dark-Aqua'\" ] && [ \"\$(g org.cinnamon.theme name)\" = \"'Mint-Y-Dark-Aqua'\" ]"
  item vis.icones           f "Ícones Papirus-Dark"                          "[ \"\$(g org.cinnamon.desktop.interface icon-theme)\" = \"'Papirus-Dark'\" ]"
  item vis.fonte            f "Fonte Ubuntu Sans"                            "g org.cinnamon.desktop.interface font-name | grep -q 'Ubuntu Sans'"
  item vis.lupa             f "Extensão da lupa/painel ativa e carregada"    "g org.cinnamon enabled-extensions | grep -q panel-hover-zoom@local && cin 'let n=0; const w=a=>{if(a._hoverZoom)n++; a.get_children().forEach(w)}; imports.ui.main.panelManager.getPanels().forEach(p=>p&&w(p.actor)); n' | grep -qE \"[1-9]\""
  item vis.lupa-volta       f "Lupa do painel: ícones voltam na hora ao sair (dica não prende)" "grep -q snapBack ~/.local/share/cinnamon/extensions/panel-hover-zoom@local/extension.js"
  item vis.painel           f "Painel sempre transparente"                   "cin 'imports.ui.main.panelManager.getPanels().filter(p=>p)[0].actor.style_class' | grep -q panel-sempre-transparente"
  item vis.blur             f "Blur ativo"                                   "g org.cinnamon enabled-extensions | grep -q BlurCinnamon"
  item vis.relogio          f "Relógio da área de trabalho"                  "g org.cinnamon enabled-desklets | grep -q relogio-bonito@local"
  item vis.webapps          f "Ícones dos apps web (Netflix/HBO)"            "grep -q '^Icon=netflix' ~/.local/share/applications/WebApp-NetFlix0441.desktop && grep -q hbomax.png ~/.local/share/applications/WebApp-HBO7628.desktop"
  item vis.extensoes        f "Extensões, applets e desklets ligados existem no disco" "py extensoes"

  grupo "Área de trabalho"
  item area.icones          f "Ícones da área de trabalho na tela"           "c_icones"
  item area.nemo-hidamari   f "Nemo ignora o Hidamari (ícones não somem ao reabrir)" "c_nemo_hidamari"
  item area.hidamari        f "Ícones por cima do Hidamari (ajudante rodando e no login)" "pgrep -f 'bin/hidamari-com-icones' && [ -f ~/.config/autostart/hidamari-com-icones.desktop ]"
  item area.hidamari-aberto a "Hidamari (papel de parede animado) aberto"    "c_hidamari_aberto"
  item area.lixeira         a "Lixeira na linha da HBO, logo à esquerda"     "py lixeira"
  item area.atalhos         f "Atalhos da área de trabalho apontam para programas que existem" "py atalhos \"\$TM_DESK\""

  grupo "Início automático e ajudantes"
  item ini.autostart        f "Programas do início automático existem"       "py atalhos ~/.config/autostart"
  item ini.sintaxe          f "Ajudantes e scripts sem erro de sintaxe"      "py sintaxe ~/.local/bin ~/.local/share/personalizacoes ~/.local/share/personalizacoes/scripts-sistema"

  grupo "Apps"
  item app.flatpaks         f "Apps Flatpak principais instalados"           "c_flatpaks"
  item app.foliate          f "Foliate: personalizações compatíveis e ativas" "~/.local/bin/verificar-foliate --status | grep -q 'compatível' && ~/.local/bin/verificar-foliate --status | grep -q ATIVAS"
  item app.foliate-escuro   f "Foliate: modo escuro"                         "flatpak run --command=gsettings com.github.johnfactotum.Foliate get com.github.johnfactotum.Foliate color-scheme | grep -q 4"
  item app.foliate-vigia    f "Foliate: vigia de atualização ativa"          "systemctl --user is-active verificar-foliate.path"
  item app.xournal-borracha f "Xournal++: botão da caneta = borracha"        "awk '/<data name=\"stylus\">/,/<\\/data>/' $X/settings.xml | grep -q 'value=\"eraser\"'"
  item app.xournal-pagina   f "Xournal++: página lisa e comprida"            "grep pageTemplate $X/settings.xml | grep -q 'backgroundType=plain' && grep pageTemplate $X/settings.xml | grep -q 8418"
  item app.xournal-barra    f "Xournal++: barra Tablet + botão do teclado"   "grep -q 'selectedToolbar\" value=\"Tablet' $X/settings.xml && grep -q TEXTO_TECLADO $X/toolbar.ini && [ -f $X/plugins/TecladoTexto/main.lua ]"
  item app.xournal-teclado  f "Xournal++: permissão para abrir o teclado"    "flatpak override --user --show com.github.xournalpp.xournalpp | grep -q org.onboard.Onboard"
  item app.rnote            f "Rnote: botão da caneta = borracha temporária" "grep -q '\"stylus_primary_button\":{\"change_pen_style\":{\"style\":\"eraser\",\"mode\":\"temporary\"}}' ~/.var/app/com.github.flxzt.rnote/config/glib-2.0/settings/keyfile"
  item app.celluloid        f "Celluloid: regra sem legenda (Eu, Robô)"      "[ \"\$(g io.github.celluloid-player.Celluloid mpv-config-enable)\" = true ] && grep -q sem-legenda ~/.config/celluloid/mpv.conf"
  item app.audio-filmes     f "Áudio de filmes sem mudo"                     "grep -q 'media.role:Movie:mute=false' ~/.local/state/wireplumber/restore-stream"
  item app.hidamari-audio   f "Regra: Hidamari não muta mais os filmes"      "[ -f ~/.config/wireplumber/main.lua.d/51-hidamari-sem-restaurar.lua ]"
  item app.localsend        f "LocalSend em janela normal"                   "python3 -c \"import json,os; d=json.load(open(os.path.expanduser('~/.var/app/org.localsend.localsend_app/data/org.localsend.localsend_app/shared_preferences.json'))); exit(d['flutter.ls_window_width']!=900)\""
  item app.qbittorrent      f "qBittorrent padrão para torrents"             "[ \"\$(xdg-mime query default x-scheme-handler/magnet)\" = org.qbittorrent.qBittorrent.desktop ]"
  item app.telegram         f "Telegram: botões ±10 s no player (rodando e no login)" "pgrep -f 'bin/telegram-botoes-video' && [ -f ~/.config/autostart/telegram-botoes-video.desktop ]"

  grupo "Planilha FINANÇAS (Drive)"
  item fin.atalho           f "Atalho FINANÇAS (Drive) e ajudante financas-drive" "c_financas"
  item fin.macros           a "Macros da FINANÇAS.ods do Drive liberadas"    "c_financas_macros"
  item fin.drive            a "Google Drive da planilha aparece em Rede"     "c_drive"

  grupo "Jogos (Hearthstone)"
  item jogo.zram            f "Memória comprimida (zram) grande, zstd"       "[ \$(zramctl --noheadings --bytes --output DISKSIZE /dev/zram0) -gt 6000000000 ] && zramctl --noheadings --output ALGORITHM /dev/zram0 | grep -q zstd"
  item jogo.hdt             f "Deck Tracker: atalho e programa"              "[ -x ~/.local/bin/hearthstone-deck-tracker ] && [ -f ~/GAMES/teste/HDT/'Hearthstone Deck Tracker'/'Hearthstone Deck Tracker.exe' ]"
  item jogo.hdt-battlenet   f "Deck Tracker: abre o Battle.net pela Steam antes" "grep -q rungameid ~/.local/bin/hearthstone-deck-tracker"
  item jogo.dotnet          f "Deck Tracker: .NET 4.8 no prefixo do Battle.net" "grep -aq 'Release\"=dword:00080eb1' ~/.steam/debian-installation/steamapps/compatdata/2298413468/pfx/system.reg"
  item jogo.arena           f "Arena Helper: atualização diária dos dados ativa" "systemctl --user is-enabled atualizar-arena-hdt.timer"

  grupo "Bluetooth (Buds3)"
  item bt.config            f "Configuração de reconexão"                    "grep -q '^JustWorksRepairing = always' /etc/bluetooth/main.conf && grep -q '^ReconnectAttempts = 7' /etc/bluetooth/main.conf"
  item bt.ligado            a "Bluetooth ligado"                             "bluetoothctl show | grep -q 'Powered: yes'"
  item bt.buds              f "Buds3 pareado"                                "for m in \$(bluetoothctl devices 2>/dev/null | grep -i buds | awk '{print \$2}'); do bluetoothctl info \$m | grep -q 'Paired: yes' && exit 0; done; exit 1"
  item bt.atalho            f "Atalho Conectar Buds"                         "[ -x ~/.local/bin/conectar-buds ]"

  grupo "Backup"
  item bkp.comando          f "Comando de backup presente"                   "[ -x ~/.local/bin/backup-personalizacoes ]"
  item bkp.recente          a "Backup das personalizações dos últimos 14 dias" "c_backup"
  item bkp.teste            f "Teste automático ligado (atualizações e login)" "systemctl --user is-enabled $UNIDADE.path && [ -f '$AUTOSTART' ]"

  # shellcheck disable=SC1090  # só para teste: itens extras de um arquivo
  if [ -n "${TESTE_MINT_EXTRA:-}" ] && [ -f "$TESTE_MINT_EXTRA" ]; then grupo "Extra"; source "$TESTE_MINT_EXTRA"; fi
}

# ---------------------------------------------------------------------------------------------------------
# Ajudante em Python (itens que leem vários arquivos)
# ---------------------------------------------------------------------------------------------------------
escrever_py() {
cat > "$TM_PY" <<'PY_FIM'
import ast, glob, os, re, shlex, shutil, subprocess, sys

def det(msg):
    try:
        with open(3, "w", closefd=False) as f:
            f.write(msg + "\n")
    except OSError:
        pass

def ler_desktop(caminho):
    d = {}
    grupo = None
    try:
        with open(caminho, encoding="utf-8", errors="replace") as f:
            for linha in f:
                linha = linha.strip()
                if linha.startswith("["):
                    grupo = linha
                elif grupo == "[Desktop Entry]" and "=" in linha and not linha.startswith("#"):
                    k, v = linha.split("=", 1)
                    d.setdefault(k.strip(), v.strip())
    except OSError:
        pass
    return d

def flatpaks():
    try:
        r = subprocess.run(["flatpak", "list", "--app", "--columns=application"], capture_output=True, text=True, timeout=20)
        return set(r.stdout.split())
    except (OSError, subprocess.TimeoutExpired):
        return None

def comando_existe(exe, apps):
    """Devolve None se o programa do Exec= existe, ou o texto do que falta."""
    try:
        partes = shlex.split(exe)
    except ValueError:
        partes = exe.split()
    while partes and (partes[0] == "env" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", partes[0])):
        partes.pop(0)
    if not partes:
        return None
    p0 = os.path.expandvars(os.path.expanduser(partes[0]))
    if os.path.basename(p0) in ("sh", "bash", "dash") and "-c" in partes:
        return None
    if os.path.basename(p0) == "flatpak" and "run" in partes:
        resto = [x for x in partes[partes.index("run") + 1:] if not x.startswith("-") and not x.startswith("%")]
        if resto and apps is not None and resto[0] not in apps:
            return "Flatpak " + resto[0]
        return None
    if "/" in p0:
        return None if os.access(p0, os.X_OK) else p0
    return None if shutil.which(p0) else p0

def atalhos(pastas):
    apps = flatpaks()
    faltam = []
    total = 0
    for pasta in pastas:
        for f in sorted(glob.glob(os.path.join(pasta, "*.desktop"))):
            d = ler_desktop(f)
            if d.get("Type", "Application") != "Application" or d.get("Hidden", "").lower() == "true":
                continue
            if d.get("X-GNOME-Autostart-enabled", "true").lower() == "false":
                continue
            so = [x for x in d.get("OnlyShowIn", "").split(";") if x]
            nao = [x for x in d.get("NotShowIn", "").split(";") if x]
            if (so and not {"X-Cinnamon", "Cinnamon"} & set(so)) or {"X-Cinnamon", "Cinnamon"} & set(nao):
                continue
            total += 1
            te = d.get("TryExec")
            if te and comando_existe(te, apps):
                continue  # TryExec ausente: o próprio sistema esconde o atalho
            falta = comando_existe(d.get("Exec", ""), apps)
            if falta:
                faltam.append(f"{os.path.basename(f)} -> {falta}")
    if faltam:
        det("não acho: " + "; ".join(faltam))
        return 1
    det(f"{total} atalho(s) conferido(s)")
    return 0

def sintaxe(pastas):
    ruins = []
    total = 0
    for pasta in pastas:
        for f in sorted(glob.glob(os.path.join(pasta, "*"))):
            nome = os.path.basename(f)
            if not os.path.isfile(f) or ".bak" in nome or ".antes" in nome or nome.endswith((".pyc", ".desktop")):
                continue
            try:
                with open(f, "rb") as fh:
                    cabeca = fh.readline(200).decode("utf-8", "replace")
            except OSError:
                continue
            tipo = None
            if cabeca.startswith("#!") and "python" in cabeca or nome.endswith(".py"):
                tipo = "py"
            elif cabeca.startswith("#!") and re.search(r"\b(ba)?sh\b", cabeca) or nome.endswith(".sh"):
                tipo = "sh"
            if not tipo:
                continue
            total += 1
            if tipo == "py":
                try:
                    with open(f, encoding="utf-8", errors="replace") as fh:
                        compile(fh.read(), f, "exec", dont_inherit=True)
                except SyntaxError as e:
                    ruins.append(f"{nome} (linha {e.lineno})")
                except (OSError, ValueError):
                    pass
            else:
                r = subprocess.run(["bash", "-n", f], capture_output=True, text=True)
                if r.returncode != 0:
                    m = re.search(r"line (\d+)|linha (\d+)", r.stderr)
                    ruins.append(nome + (f" (linha {m.group(1) or m.group(2)})" if m else ""))
    if ruins:
        det("com erro: " + ", ".join(ruins))
        return 1
    det(f"{total} arquivo(s) conferido(s)")
    return 0

def gs_lista(esquema, chave):
    try:
        r = subprocess.run(["gsettings", "get", esquema, chave], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    v = r.stdout.strip()
    if r.returncode != 0:
        return None
    if v.startswith("@as"):
        v = v[3:].strip()
    try:
        return list(ast.literal_eval(v))
    except (ValueError, SyntaxError):
        return None

def extensoes():
    base_u = os.path.expanduser("~/.local/share/cinnamon")
    faltam = []
    total = 0
    for chave, tipo, campo in (("enabled-extensions", "extensions", None), ("enabled-applets", "applets", 3),
                               ("enabled-desklets", "desklets", 0)):
        lista = gs_lista("org.cinnamon", chave)
        if lista is None:
            det("não consegui ler org.cinnamon " + chave)
            return 1
        for e in lista:
            if campo is None:
                uuid = e[1:] if e.startswith("!") else e
            else:
                p = e.split(":")
                if len(p) <= campo:
                    continue
                uuid = p[campo]
            total += 1
            if not any(os.path.isdir(os.path.join(b, tipo, uuid)) for b in (base_u, "/usr/share/cinnamon")):
                faltam.append(uuid)
    if faltam:
        det("não estão no disco: " + ", ".join(faltam))
        return 1
    det(f"{total} ligados, todos no disco")
    return 0

def posicao(texto):
    m = re.search(r"(-?\d+),(-?\d+)", texto or "")
    return (int(m.group(1)), int(m.group(2))) if m else None

def lixeira():
    desk = os.environ.get("TM_DESK", os.path.expanduser("~/Desktop"))
    hbo = sorted(glob.glob(os.path.join(desk, "WebApp-HBO*.desktop")))
    if not hbo:
        det("não achei o ícone da HBO na área de trabalho")
        return 1
    try:
        r = subprocess.run(["gio", "info", "-a", "metadata::nemo-icon-position", hbo[0]], capture_output=True,
                           text=True, timeout=10)
        ph = posicao(r.stdout.split("nemo-icon-position:", 1)[1]) if "nemo-icon-position:" in r.stdout else None
    except (OSError, subprocess.TimeoutExpired):
        ph = None
    pt = None
    try:
        with open(os.path.expanduser("~/.config/nemo/desktop-metadata"), encoding="utf-8") as f:
            grupo = None
            for linha in f:
                linha = linha.strip()
                if linha.startswith("["):
                    grupo = linha
                elif grupo == "[trash]" and linha.startswith("nemo-icon-position="):
                    pt = posicao(linha.split("=", 1)[1])
    except OSError:
        pass
    if not ph or not pt:
        det("sem posição gravada da HBO ou da Lixeira")
        return 1
    det(f"Lixeira em {pt[0]},{pt[1]}; HBO em {ph[0]},{ph[1]}")
    if abs(pt[1] - ph[1]) <= 40 and 0 < ph[0] - pt[0] <= 260:
        return 0
    det("fora do lugar: rode de novo organizar-area-de-trabalho.sh")
    return 1

def apt_desde(desde):
    """Transações do apt depois do instante 'desde' (epoch), resumidas."""
    import datetime
    blocos, atual = [], {}
    try:
        with open("/var/log/apt/history.log", encoding="utf-8", errors="replace") as f:
            for linha in f:
                linha = linha.rstrip("\n")
                if not linha.strip():
                    if atual:
                        blocos.append(atual)
                    atual = {}
                    continue
                if ": " in linha:
                    k, v = linha.split(": ", 1)
                    atual[k] = v
        if atual:
            blocos.append(atual)
    except OSError:
        return 0
    for b in blocos:
        try:
            t = datetime.datetime.strptime(b.get("Start-Date", ""), "%Y-%m-%d  %H:%M:%S").timestamp()
        except ValueError:
            continue
        if t < desde:
            continue
        print(f"  {b.get('Start-Date', '')}  {b.get('Commandline', b.get('Requested-By', ''))[:160]}")
        for k in ("Install", "Reinstall", "Upgrade", "Downgrade", "Remove", "Purge"):
            if k in b:
                pacotes = re.sub(r"\([^)]*\)", "", b[k])
                pacotes = ", ".join(p.strip().split(":")[0] for p in pacotes.split(",") if p.strip())
                print(f"    {k}: {pacotes[:400]}{' ...' if len(pacotes) > 400 else ''}")
    return 0

if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "atalhos":
        sys.exit(atalhos(args))
    if cmd == "sintaxe":
        sys.exit(sintaxe(args))
    if cmd == "extensoes":
        sys.exit(extensoes())
    if cmd == "lixeira":
        sys.exit(lixeira())
    if cmd == "apt-desde":
        sys.exit(apt_desde(float(args[0])))
    sys.exit(2)
PY_FIM
}

# ---------------------------------------------------------------------------------------------------------
# Rodar os itens
# ---------------------------------------------------------------------------------------------------------
preparar() {
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  TM_PY="$TMPD/ajudante.py"; escrever_py
  TM_DOWN="$(xdg-user-dir DOWNLOAD 2>/dev/null)"; [ -n "$TM_DOWN" ] && [ "$TM_DOWN" != "$HOME" ] || TM_DOWN="$HOME/Downloads"
  TM_DESK="$(xdg-user-dir DESKTOP 2>/dev/null)"; [ -n "$TM_DESK" ] && [ "$TM_DESK" != "$HOME" ] || TM_DESK="$HOME/Desktop"
  local pid=$$; TM_PAIS=""
  while [ "${pid:-0}" -gt 1 ]; do TM_PAIS+="$pid "; pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"; done
  TM_PRELUDIO="$(declare -f g cin det aviso py pgrep c_servicos c_espaco c_pacotes c_reinicio c_kernel c_internet \
    c_cinnamon c_libreoffice c_icones hidamari_instalado c_nemo_hidamari c_hidamari_aberto c_flatpaks c_financas \
    c_financas_macros c_drive c_backup)"
  mkdir -p "$RES" "$TM_DOWN"
  definir_itens
}

# Quando roda sozinho (systemd), pega DISPLAY e o barramento da sessão do Cinnamon aberto ($1 = forcar: mesmo
# com DISPLAY já definido, usa os valores do Cinnamon).
importar_sessao() {
  [ -n "${DISPLAY:-}" ] && [ "${1:-}" != forcar ] && return 0
  local pid kv
  pid="$(pgrep -u "$(id -u)" -x cinnamon | head -1)"
  [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' kv; do
    case "$kv" in
      DISPLAY=*|XAUTHORITY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*|XDG_RUNTIME_DIR=*) export "${kv?}" ;;
    esac
  done < "/proc/$pid/environ"
  [ -n "${DISPLAY:-}" ]
}

rodar_item() {  # $1 = índice; deixa R_ST e R_DET
  local i=$1 rc
  : > "$TMPD/det"
  TM_PRELUDIO="$TM_PRELUDIO" TM_CMD="${I_CMD[$i]}" TM_PY="$TM_PY" TM_DOWN="$TM_DOWN" TM_DESK="$TM_DESK" TM_PAIS="$TM_PAIS" X="$X" \
    timeout -k 3 "$LIMITE" bash -c 'eval "$TM_PRELUDIO"; eval "$TM_CMD"' 3>"$TMPD/det" >/dev/null 2>&1 </dev/null 9>&-
  rc=$?
  R_DET="$(tr '\t\n' '  ' < "$TMPD/det" | sed 's/  */ /g; s/^ //; s/ $//')"; R_DET="${R_DET:0:300}"
  if [ $rc -eq 0 ]; then R_ST=OK
  elif [ $rc -eq 42 ] || [ "${I_NIVEL[$i]}" = a ]; then R_ST=AVISO
  else R_ST=FALHA; fi
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then R_DET="demorou mais de ${LIMITE}s${R_DET:+; $R_DET}"; fi
}

linha_tsv() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

rodar_todos() {  # $1 = arquivo de saída, $2 = motivo
  local saida=$1 i n=${#I_ID[@]}
  {
    printf '# versao=%s\n# motivo=%s\n# carimbo=%s\n# epoch=%s\n' "$VERSAO" "$2" "$(date '+%d/%m/%Y %H:%M:%S')" "$(date +%s)"
    for ((i = 0; i < n; i++)); do
      [ -t 2 ] && printf '\r  conferindo %d de %d...' $((i + 1)) "$n" >&2
      rodar_item "$i"
      linha_tsv "${I_ID[$i]}" "$R_ST" "${I_GRP[$i]}" "${I_TIT[$i]}" "$R_DET"
    done
    legado_extras
  } > "$saida"
  [ -t 2 ] && printf '\r%*s\r' 40 '' >&2
}

# Se o verificar-personalizacoes.sh ganhou itens depois de 15/10, roda ele e traz só os itens que faltam aqui.
legado_extras() {
  [ -f "$LEGADO" ] || return 0
  [ "$(sha256sum "$LEGADO" | cut -d' ' -f1)" = "$LEGADO_SHA" ] && return 0
  local st tit i conhecido
  while IFS=$'\t' read -r st tit; do
    conhecido=0
    for ((i = 0; i < ${#I_TIT[@]}; i++)); do [ "${I_TIT[$i]}" = "$tit" ] && { conhecido=1; break; }; done
    [ $conhecido -eq 1 ] && continue
    [ "$st" = OK ] || st=FALHA
    linha_tsv "antigo.$(printf '%s' "$tit" | md5sum | cut -c1-8)" "$st" "Itens novos do verificar-personalizacoes.sh" "$tit" ""
  done < <(timeout 300 bash "$LEGADO" 2>/dev/null </dev/null 9>&- | sed 's/\x1b\[[0-9;]*m//g' \
           | sed -n 's/^  \(OK\|FALHA\) \+\(.*[^ ]\) *$/\1\t\2/p')
}

# ---------------------------------------------------------------------------------------------------------
# Comparar
# ---------------------------------------------------------------------------------------------------------
declare -A A_ST=() B_ST=() B_DET=() B_TIT=() B_GRP=()
B_ORDEM=()
ler_meta() { sed -n "s/^# $2=//p" "$1" 2>/dev/null | head -1; }
carregar_antes() {
  A_ST=()
  [ -f "${1:-}" ] || return 0
  local id st grp tit dt
  while IFS=$'\t' read -r id st grp tit dt; do [ "${id:0:1}" = "#" ] || A_ST[$id]=$st; done < "$1"
}
carregar_depois() {
  B_ST=(); B_DET=(); B_TIT=(); B_GRP=(); B_ORDEM=()
  local id st grp tit dt
  while IFS=$'\t' read -r id st grp tit dt; do
    [ "${id:0:1}" = "#" ] && continue
    B_ST[$id]=$st; B_DET[$id]=$dt; B_TIT[$id]=$tit; B_GRP[$id]=$grp; B_ORDEM+=("$id")
  done < "$1"
}
comparar() {
  QUEBROU=(); VOLTOU=(); JA_FALHAVA=(); AVISOS=()
  N_OK=0; N_FALHA=0; N_AVISO=0
  local id a
  for id in "${B_ORDEM[@]}"; do
    a="${A_ST[$id]:-}"
    case "${B_ST[$id]}" in
      OK) N_OK=$((N_OK + 1)); [ "$a" = FALHA ] && VOLTOU+=("$id") ;;
      AVISO) N_AVISO=$((N_AVISO + 1)); AVISOS+=("$id") ;;
      FALHA) N_FALHA=$((N_FALHA + 1))
             if [ "$a" = OK ] || [ "$a" = AVISO ]; then QUEBROU+=("$id"); else JA_FALHAVA+=("$id"); fi ;;
    esac
  done
}
# Um item que acabou de parar ganha até $ESPERA s para voltar sozinho (ex.: ícones reabrindo depois da mudança).
assentar() {  # $1 = arquivo do depois
  local espera=0 id i mudou=0
  while [ ${#QUEBROU[@]} -gt 0 ] && [ "$espera" -lt "$ESPERA" ]; do
    [ -t 1 ] && printf '  %d item(ns) com falha; esperando %d s para ver se voltam sozinhos...\n' ${#QUEBROU[@]} 10
    sleep 10; espera=$((espera + 10))
    for id in "${QUEBROU[@]}"; do
      i="${IDX[$id]:-}"; [ -n "$i" ] || continue
      rodar_item "$i"; B_ST[$id]=$R_ST; B_DET[$id]=$R_DET; mudou=1
    done
    comparar
  done
  [ $mudou -eq 1 ] || return 0
  local tmp="$TMPD/regravar"
  { grep '^#' "$1"; for id in "${B_ORDEM[@]}"; do linha_tsv "$id" "${B_ST[$id]}" "${B_GRP[$id]}" "${B_TIT[$id]}" "${B_DET[$id]}"; done; } > "$tmp"
  cat "$tmp" > "$1"
}

# ---------------------------------------------------------------------------------------------------------
# Relatório
# ---------------------------------------------------------------------------------------------------------
listar() {  # $1 = rótulo; resto = ids
  local rot=$1 id; shift
  for id in "$@"; do printf '  %-6s %s%s\n' "$rot" "${B_TIT[$id]}" "${B_DET[$id]:+  [${B_DET[$id]}]}"; done
}
escrever_relatorio() {  # $1 = destino, $2 = título, $3 = arquivo antes (ou vazio), $4 = arquivo depois, $5 = extra
  local dest=$1 titulo=$2 antes=$3 depois=$4 extra=${5:-} id grp_atual="" desde
  desde="$(ler_meta "$antes" epoch)"; [ -n "$desde" ] || desde="$(ler_meta "$depois" epoch)"
  {
    echo "Teste do Mint: $titulo"
    echo "Gerado em $(date '+%d/%m/%Y %H:%M:%S') por teste-mint $VERSAO"
    echo "Sistema: $(sed -n 's/^DESCRIPTION="\?\([^"]*\)"\?/\1/p' /etc/linuxmint/info 2>/dev/null | head -1) | kernel $(uname -r) | $(cinnamon --version 2>/dev/null) | ligado $(uptime -p 2>/dev/null | sed 's/^up //')"
    if [ -n "$antes" ]; then
      echo "Comparado com: $(ler_meta "$antes" motivo) ($(ler_meta "$antes" carimbo))"
    else
      echo "Comparado com: nada (primeiro teste; as falhas abaixo são o estado atual)"
    fi
    echo "Conferido em: $(ler_meta "$depois" carimbo)"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    echo
    if [ ${#QUEBROU[@]} -gt 0 ]; then
      echo "RESULTADO: ATENÇÃO, ${#QUEBROU[@]} item(ns) pararam de funcionar."
    else
      echo "RESULTADO: OK, nada parou de funcionar."
    fi
    echo "Totais: $N_OK OK, $N_FALHA falha(s), $N_AVISO aviso(s), de ${#B_ORDEM[@]} itens."
    echo
    echo "== Pararam de funcionar"; [ ${#QUEBROU[@]} -gt 0 ] && listar FALHA "${QUEBROU[@]}" || echo "  (nenhum)"
    echo
    echo "== Voltaram a funcionar"; [ ${#VOLTOU[@]} -gt 0 ] && listar OK "${VOLTOU[@]}" || echo "  (nenhum)"
    echo
    if [ -n "$antes" ]; then echo "== Já estavam com falha antes (não foi esta mudança)"
    else echo "== Com falha agora (primeiro teste, sem comparação)"; fi
    [ ${#JA_FALHAVA[@]} -gt 0 ] && listar FALHA "${JA_FALHAVA[@]}" || echo "  (nenhum)"
    echo
    echo "== Avisos (dependem do que está aberto, ou são lembretes)"; [ ${#AVISOS[@]} -gt 0 ] && listar AVISO "${AVISOS[@]}" || echo "  (nenhum)"
    echo
    echo "== Pacotes instalados ou atualizados desde a comparação"
    py apt-desde "${desde:-0}" 2>/dev/null | tail -n 40 | grep . || echo "  (nenhum pelo apt)"
    if command -v flatpak >/dev/null && [ -n "$desde" ]; then
      flatpak history --since="$(date -d "@$desde" '+%Y-%m-%d %H:%M:%S')" --columns=time,change,application 2>/dev/null \
        | tail -n 20 | sed 's/^/  flatpak: /'
    fi
    echo
    echo "== Erros do sistema registrados desde a comparação (últimos 30)"
    journalctl -b --since "@${desde:-0}" -p err -q --no-pager -o short 2>/dev/null | tail -n 30 | cut -c1-300 | sed 's/^/  /' | grep . \
      || echo "  (nenhum)"
    echo
    echo "== Lista completa"
    for id in "${B_ORDEM[@]}"; do
      [ "${B_GRP[$id]}" = "$grp_atual" ] || { grp_atual="${B_GRP[$id]}"; echo "-- $grp_atual"; }
      printf '  %-6s %s%s\n' "${B_ST[$id]}" "${B_TIT[$id]}" "${B_DET[$id]:+  [${B_DET[$id]}]}"
    done
  } > "$dest"
}

resumo_terminal() {  # $1 = relatório
  if [ ${#QUEBROU[@]} -gt 0 ]; then
    echo "  ${VERM}${NEG}✘ ${#QUEBROU[@]} item(ns) pararam de funcionar:${FIM}"
    local id; for id in "${QUEBROU[@]}"; do echo "     - ${B_TIT[$id]}${B_DET[$id]:+ (${B_DET[$id]})}"; done
  else
    echo "  ${VERDE}${NEG}✔ Nada parou de funcionar.${FIM}"
  fi
  [ ${#VOLTOU[@]} -eq 0 ] || echo "  ${VERDE}✔ Voltaram a funcionar: $(for id in "${VOLTOU[@]}"; do printf '%s; ' "${B_TIT[$id]}"; done)${FIM}"
  echo "  Totais: $N_OK OK, $N_FALHA falha(s) (${#JA_FALHAVA[@]} já vinham de antes), $N_AVISO aviso(s)."
  echo "  Relatório: $1"
  echo "  ${NEG}Mande esse arquivo para o Claude.${FIM}"
}

guardar() {  # $1 = arquivo; vira o "último" e limpa os antigos
  cp -f "$1" "$DADOS/ultimo.tsv"
  ls -1t "$RES"/*.tsv 2>/dev/null | tail -n +$((GUARDAR + 1)) | xargs -r -d '\n' rm -f
}

contar() {  # $1 = arquivo -> "N OK, N falha(s), N aviso(s)"
  awk -F'\t' '!/^#/ {n[$2]++} END {printf "%d OK, %d falha(s), %d aviso(s)", n["OK"], n["FALHA"], n["AVISO"]}' "$1"
}

travar() {  # $1 = segundos de espera
  mkdir -p "$HOME/.cache"
  exec 9>"$HOME/.cache/teste-mint.lock"
  flock -w "$1" 9
}

# ---------------------------------------------------------------------------------------------------------
# Modos
# ---------------------------------------------------------------------------------------------------------
foto_antes() {  # $1 = nome da mudança
  local f="$RES/$CARIMBO-antes.tsv"
  echo "${NEG}== Teste do Mint: foto de ANTES da mudança \"$1\"${FIM}"
  rodar_todos "$f" "antes da mudança \"$1\""
  cp -f "$f" "$DADOS/antes-pendente.tsv"; printf '%s\n' "$1" > "$DADOS/antes-pendente.nome"
  guardar "$f"
  echo "  $(contar "$f")"
  log "antes \"$1\": $(contar "$f")"
}

conferir_depois() {  # $1 = nome, $2 = texto extra para o relatório; devolve 1 se algo parou
  local nome=$1 extra=${2:-} antes="$DADOS/antes-pendente.tsv" f="$RES/$CARIMBO-depois.tsv" rel
  if [ ! -f "$antes" ]; then antes="$DADOS/ultimo.tsv"; [ -f "$antes" ] || antes=""; fi
  echo "${NEG}== Teste do Mint: conferindo DEPOIS da mudança \"$nome\"${FIM}"
  rodar_todos "$f" "depois da mudança \"$nome\""
  carregar_antes "$antes"; carregar_depois "$f"; comparar; assentar "$f"
  rel="$TM_DOWN/relatorio-teste-mint-$CARIMBO.txt"
  escrever_relatorio "$rel" "mudança \"$nome\"" "$antes" "$f" "$extra"
  [ "$antes" != "$DADOS/antes-pendente.tsv" ] || rm -f "$DADOS/antes-pendente.tsv" "$DADOS/antes-pendente.nome"
  guardar "$f"
  resumo_terminal "$rel"
  log "depois \"$nome\": $(contar "$f"); pararam ${#QUEBROU[@]}; relatório $rel"
  [ ${#QUEBROU[@]} -eq 0 ]
}

modo_manual() {  # $1 = motivo
  local f="$RES/$CARIMBO-manual.tsv" antes="$DADOS/ultimo.tsv" rel
  [ -f "$antes" ] || antes=""
  echo "${NEG}== Teste do Mint: $1${FIM}"
  rodar_todos "$f" "$1"
  carregar_antes "$antes"; carregar_depois "$f"; comparar; assentar "$f"
  rel="$TM_DOWN/relatorio-teste-mint-$CARIMBO.txt"
  escrever_relatorio "$rel" "$1" "$antes" "$f"
  guardar "$f"
  resumo_terminal "$rel"
  log "manual \"$1\": $(contar "$f"); pararam ${#QUEBROU[@]}"
  [ ${#QUEBROU[@]} -eq 0 ]
}

esperar_atualizacoes() {  # espera 1 min sem apt/dpkg/flatpak rodando (no máximo 30 min)
  local calmo=0 t=0
  while [ $t -lt 1800 ] && [ $calmo -lt 60 ]; do
    if pgrep -x 'apt|apt-get|aptitude|dpkg|synaptic|unattended-upgr|flatpak' >/dev/null; then calmo=0; else calmo=$((calmo + 10)); fi
    sleep 10; t=$((t + 10))
  done
}

modo_automatico() {  # $1 = login | atualizacao
  local motivo f antes="$DADOS/ultimo.tsv" rel texto
  case "$1" in
    login) motivo="depois de entrar na sessão" ;;
    atualizacao) motivo="depois de uma atualização do sistema ou de Flatpak"; esperar_atualizacoes ;;
    *) motivo="$1" ;;
  esac
  importar_sessao forcar || { log "automático ($1): sem sessão do Cinnamon aberta; não conferi"; return 0; }
  preparar
  travar 1800 || { log "automático ($1): outro teste rodando; pulei"; return 0; }
  f="$RES/$CARIMBO-auto.tsv"
  rodar_todos "$f" "$motivo"
  if [ ! -f "$antes" ]; then guardar "$f"; log "automático ($1): primeiro resultado guardado"; return 0; fi
  cp -f "$antes" "$TMPD/antes.tsv"; antes="$TMPD/antes.tsv"  # o guardar abaixo troca o ultimo.tsv
  carregar_antes "$antes"; carregar_depois "$f"; comparar; assentar "$f"
  guardar "$f"
  if [ ${#QUEBROU[@]} -eq 0 ]; then log "automático ($1): $(contar "$f"); nada parou"; return 0; fi
  rel="$TM_DOWN/relatorio-teste-mint-$CARIMBO.txt"
  escrever_relatorio "$rel" "conferência automática $motivo" "$antes" "$f"
  texto="${#QUEBROU[@]} item(ns) pararam de funcionar $motivo: $(for id in "${QUEBROU[@]}"; do printf '%s; ' "${B_TIT[$id]}"; done)"
  notify-send -a "Teste do Mint" -i dialog-warning "Teste do Mint: algo parou de funcionar" \
    "$texto Relatório em Downloads: $(basename "$rel"). Mande para o Claude." 2>/dev/null || true
  log "automático ($1): $(contar "$f"); pararam ${#QUEBROU[@]}; relatório $rel"
  return 1
}

modo_mudanca() {  # $1 = nome; resto = comando
  local nome=$1 rc ini dur extra interrompido=0; shift
  [ $# -gt 0 ] || morrer "Falta o comando depois de --: teste-mint --mudanca \"Nome\" -- bash script.sh"
  if [ -n "${TESTE_MINT_DENTRO:-}" ]; then exec "$@"; fi
  preparar
  travar 300 || morrer "Outro teste do Mint está rodando; tente de novo em alguns minutos."
  foto_antes "$nome"
  echo "${NEG}== Rodando a mudança:${FIM} $*"
  ini=$(date +%s)
  trap 'interrompido=1' INT
  TESTE_MINT_DENTRO=1 "$@" 9>&-
  rc=$?
  trap - INT
  dur=$(( $(date +%s) - ini ))
  extra="Comando: $*"$'\n'"Saída do comando: $rc$( [ $rc -eq 0 ] && echo ' (terminou bem)' || echo ' (terminou com erro)')$( [ $interrompido -eq 1 ] && echo ', interrompido com Ctrl+C'); duração ${dur}s"
  echo "${NEG}== A mudança terminou (saída $rc).${FIM} Conferindo em ${PAUSA}s..."
  sleep "$PAUSA"
  conferir_depois "$nome" "$extra"; local ok=$?
  [ $rc -eq 0 ] || return $rc
  return $ok
}

mostrar_lista() {
  local i grp_atual=""
  for ((i = 0; i < ${#I_ID[@]}; i++)); do
    [ "${I_GRP[$i]}" = "$grp_atual" ] || { grp_atual="${I_GRP[$i]}"; echo "== $grp_atual"; }
    printf '  %-24s %s %s\n' "${I_ID[$i]}" "$( [ "${I_NIVEL[$i]}" = a ] && echo aviso || echo falha)" "${I_TIT[$i]}"
  done
  echo "${#I_ID[@]} itens."
}

instalar() {
  mkdir -p "$HOME/.local/bin" "$RES" "$HOME/.config/systemd/user" "$HOME/.config/autostart" "$HOME/.cache"
  if [ "$EU" != "$(readlink -f "$BIN" 2>/dev/null)" ]; then
    if [ -f "$BIN" ] && ! cmp -s "$EU" "$BIN"; then cp -a "$BIN" "$DADOS/teste-mint.antes-$CARIMBO"; fi
    install -m 755 "$EU" "$BIN"
  fi
  cat > "$HOME/.config/systemd/user/$UNIDADE.path" <<EOF
[Unit]
Description=Teste do Mint depois de atualizações (apt e Flatpak)

[Path]
PathModified=/var/log/apt/history.log
PathModified=/var/lib/flatpak/.changed
PathModified=%h/.local/share/flatpak/.changed
Unit=$UNIDADE.service

[Install]
WantedBy=default.target
EOF
  cat > "$HOME/.config/systemd/user/$UNIDADE.service" <<EOF
[Unit]
Description=Teste do Mint depois de atualizações (apt e Flatpak)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/teste-mint --automatico atualizacao
Nice=10
EOF
  cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Teste do Mint ao entrar
Comment=Confere em silêncio se tudo continua funcionando e só avisa se algo parou
Exec=$BIN --automatico login
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=120
NoDisplay=true
EOF
  if systemctl --user daemon-reload && systemctl --user enable --now "$UNIDADE.path" >/dev/null 2>&1; then
    echo "Teste automático depois de atualizações: ligado."
  else
    echo "${AMAR}Não consegui ligar o teste depois de atualizações (systemctl --user). O resto funciona.${FIM}"
  fi
  echo "Teste ao entrar na sessão: ligado (2 min depois do login)."
  echo "Comando instalado: $BIN"
  log "instalado ($VERSAO)"
  exec "$BIN" --manual "instalação do teste automático"
}

desinstalar() {
  systemctl --user disable --now "$UNIDADE.path" >/dev/null 2>&1
  rm -f "$HOME/.config/systemd/user/$UNIDADE.path" "$HOME/.config/systemd/user/$UNIDADE.service" "$AUTOSTART"
  systemctl --user daemon-reload 2>/dev/null
  mkdir -p "$DADOS"
  [ -f "$BIN" ] && mv -f "$BIN" "$DADOS/teste-mint.desinstalado-$CARIMBO"
  log "desinstalado"
  echo "Teste automático desligado. Resultados e uma cópia do comando ficaram em $DADOS."
}

ajuda() { sed -n '2,/^set -uo/p' "$EU" | sed '$d; s/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || morrer "Rode sem sudo: teste-mint"
case "${1:-}" in
  --instalar) instalar ;;
  --desinstalar) desinstalar ;;
  --automatico) modo_automatico "${2:-login}"; exit $? ;;
  --ajuda|-h|--help) ajuda ;;
  --lista) preparar; mostrar_lista ;;
  --mudanca)
    [ $# -ge 3 ] && [ "$3" = "--" ] || morrer "Uso: teste-mint --mudanca \"Nome da mudança\" -- COMANDO"
    nome=$2; shift 3
    [ -n "${DISPLAY:-}" ] || importar_sessao || echo "${AMAR}Aviso: sem DISPLAY; rode pelo Terminal da área de trabalho.${FIM}"
    modo_mudanca "$nome" "$@"; exit $? ;;
  --antes)
    [ -z "${TESTE_MINT_DENTRO:-}" ] || exit 0
    [ -n "${DISPLAY:-}" ] || importar_sessao || echo "${AMAR}Aviso: sem DISPLAY; rode pelo Terminal da área de trabalho.${FIM}"
    preparar; travar 300 || morrer "Outro teste do Mint está rodando."; foto_antes "${2:-mudança}" ;;
  --depois)
    [ -z "${TESTE_MINT_DENTRO:-}" ] || exit 0
    [ -n "${DISPLAY:-}" ] || importar_sessao || echo "${AMAR}Aviso: sem DISPLAY; rode pelo Terminal da área de trabalho.${FIM}"
    preparar; travar 300 || morrer "Outro teste do Mint está rodando."
    nome="${2:-$(cat "$DADOS/antes-pendente.nome" 2>/dev/null || echo mudança)}"
    conferir_depois "$nome"; exit $? ;;
  ""|--manual)
    [ -n "${DISPLAY:-}" ] || importar_sessao || echo "${AMAR}Aviso: sem DISPLAY; rode pelo Terminal da área de trabalho.${FIM}"
    preparar; travar 300 || morrer "Outro teste do Mint está rodando."
    modo_manual "${2:-conferência pedida por você}"; exit $? ;;
  *) morrer "Opção desconhecida: $1 (veja teste-mint --ajuda)" ;;
esac
