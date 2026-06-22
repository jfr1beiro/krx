#!/usr/bin/env bash
set -Euo pipefail

# ============================================================
# INSTALADOR KERYX (KRX) PARA A POOL BAIKALMINE — HiveOS
#
# Ordem corrigida (resolve o problema de "parar no driver"):
#   1. Wallet / worker
#   2. Backup de escrow (se houver)
#   3. Parar minerador + limpar disco
#   4. Instalar o minerador oficial + gerar Flight Sheet
#      (TUDO que define a mineração fica pronto AQUI, antes do reboot)
#   5. CUDA runtime  -> BEST-EFFORT, nunca derruba o script
#   6. Driver NVIDIA -> série 580 (ÚLTIMA etapa; pode exigir reboot)
#   7. Resumo / reboot / teste manual opcional
#
# Importante: os erros de PTX (sm_86 / UNSUPPORTED_PTX_VERSION) são
# resolvidos pelo DRIVER 580. O cuda-runtime é só um extra.
#
# Uso:
#   sudo ./instalar-keryx-baikalmine.sh
#   sudo ./instalar-keryx-baikalmine.sh keryx:SEU_ENDERECO_AQUI
# ============================================================

POOL_URL='krx.baikalmine.com'
POOL_PORT='9020'
DRIVER_TARGET='580'
CUDA_PKG='cuda-runtime-13-3'

CUSTOM_NAME='keryx-miner-v0.1.2.6-OPoI'
MINER_URL='https://github.com/BaikalMine/krx-miner/releases/download/v0.1.3.1/keryx-miner-v0.1.3.1-OPoI-hiveos.tar.gz'
INSTALL_DIR="/hive/miners/custom/$CUSTOM_NAME"
CUSTOM_DIR='/hive/miners/custom'
KEEP_DIR='/hive/KEEP_ESCROW'
LOG_DIR='/var/log/miner/custom'
LOG_FILE="$LOG_DIR/$CUSTOM_NAME.log"
TMP_DIR="/tmp/keryx-install-$$"
STATE_FILE="/hive/.keryx-baikalmine-state"

section() {
  printf '\n============================================================\n %s\n============================================================\n' "$*"
}

warn() {
  printf '\nAVISO: %s\n' "$*" >&2
}

fail() {
  printf '\nERRO: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "execute como root (use sudo)."

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# ------------------------------------------------------------
section "0. SUA WALLET KERYX (KRX)"
# ------------------------------------------------------------

# Se já rodamos antes (state file existe) e a wallet foi salva, reaproveita
# para que o re-run após o reboot não precise pedir tudo de novo.
SAVED_WALLET=''
SAVED_WORKER=''
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE" 2>/dev/null || true
  SAVED_WALLET="${STATE_WALLET:-}"
  SAVED_WORKER="${STATE_WORKER:-}"
fi

if [ -n "$SAVED_WALLET" ]; then
  printf 'Detectei uma instalação anterior para a wallet:\n  %s (worker: %s)\n\n' \
    "$SAVED_WALLET" "${SAVED_WORKER:-?}"
  read -rp 'Continuar com esses dados? [S/n]: ' REUSE
  case "$REUSE" in
    n|N) SAVED_WALLET=''; SAVED_WORKER='' ;;
    *) WALLET="$SAVED_WALLET"; WORKER_NAME="$SAVED_WORKER" ;;
  esac
fi

if [ -z "${WALLET:-}" ]; then
  printf 'Você já precisa ter uma wallet Keryx criada ANTES de continuar.\n'
  printf 'Se ainda não tem uma, pare agora e:\n\n'
  printf '  1. Abra no navegador: https://keryx-labs.com/wallet\n'
  printf '  2. Crie sua wallet e GUARDE a frase/chave de recuperação em local seguro\n'
  printf '     (sem ela, ninguém — nem você — recupera o acesso depois).\n'
  printf '  3. Copie o endereço gerado (formato: keryx:....)\n'
  printf '  4. Só então volte aqui e cole o endereço quando for solicitado.\n\n'
  printf 'Se você já tem uma wallet, pode seguir normalmente.\n\n'

  read -rp 'Pressione ENTER para continuar (ou Ctrl+C para sair e criar sua wallet primeiro)...' _UNUSED

  WALLET="${1:-}"

  if [ -z "$WALLET" ]; then
    printf 'Informe o endereço da sua wallet Keryx (formato: keryx:....)\n\n'
    read -rp 'Wallet: ' WALLET
  fi

  if [[ ! "$WALLET" =~ ^keryx:[a-z0-9]{40,80}$ ]]; then
    printf '\nAVISO: o endereço não parece seguir o formato esperado\n'
    printf '(deve começar com "keryx:" seguido de letras minúsculas e números).\n'
    read -rp 'Confirma usar este endereço mesmo assim? [s/N]: ' CONFIRM
    case "$CONFIRM" in
      s|S|y|Y) ;;
      *) fail "instalação cancelada pelo usuário." ;;
    esac
  fi

  read -rp 'Nome deste worker (ex.: rig01) [padrão: hostname atual]: ' WORKER_NAME
  WORKER_NAME="${WORKER_NAME:-$(hostname)}"
fi

printf '\nWallet configurada: %s\n' "$WALLET"
printf 'Worker: %s\n' "$WORKER_NAME"

# Persiste para sobreviver a um reboot causado pela troca de driver.
cat >"$STATE_FILE" <<EOF
STATE_WALLET="$WALLET"
STATE_WORKER="$WORKER_NAME"
EOF
chmod 600 "$STATE_FILE"

# ------------------------------------------------------------
section "1. BACKUP DE SEGURANÇA DE ESCROW EXISTENTE (se houver)"
# ------------------------------------------------------------

mkdir -p "$KEEP_DIR"
chmod 700 "$KEEP_DIR"

# REGRA ABSOLUTA: nenhum arquivo de escrow pode ser perdido. Antes de QUALQUER
# limpeza, varremos /hive inteiro e fazemos backup de TODOS os escrow.key
# (deduplicados por conteúdo). Se acharmos um escrow e não conseguirmos
# comprovar o backup, o script ABORTA — preferimos não limpar a arriscar.

# backup_escrow ARQUIVO -> copia para $KEEP_DIR com nome único por conteúdo.
# Retorna 0 se o conteúdo já está garantido em KEEP_DIR, 1 caso contrário.
backup_escrow() {
  local src="$1" sum dest
  [ -s "$src" ] || return 0   # vazio: nada a preservar
  sum="$(sha256sum "$src" 2>/dev/null | awk '{print $1}')"
  [ -n "$sum" ] || return 1
  dest="$KEEP_DIR/escrow.$sum.key"
  if [ -s "$dest" ]; then
    return 0                  # conteúdo idêntico já preservado
  fi
  cp -a "$src" "$dest" 2>/dev/null || return 1
  chmod 600 "$dest" 2>/dev/null || true
  # Verificação: o backup precisa bater byte a byte com a origem.
  cmp -s "$src" "$dest" || return 1
  printf '%s  <-  %s\n' "$dest" "$src" >>"$KEEP_DIR/escrow-manifest.txt"
  printf 'Escrow preservado: %s\n   (origem: %s)\n' "$dest" "$src"
  # Mantém também um "escrow.key" canônico para conveniência de restauração.
  [ -s "$KEEP_DIR/escrow.key" ] || { cp -a "$src" "$KEEP_DIR/escrow.key"; chmod 600 "$KEEP_DIR/escrow.key"; }
  return 0
}

FOUND_ANY_ESCROW=0
BACKUP_FAILED=0
# Varre /hive inteiro, mas NUNCA o próprio diretório de backup.
while IFS= read -r -d '' keyfile; do
  FOUND_ANY_ESCROW=1
  if ! backup_escrow "$keyfile"; then
    warn "FALHA ao fazer backup do escrow: $keyfile"
    BACKUP_FAILED=1
  fi
done < <(find /hive -iname "escrow.key" -not -path "$KEEP_DIR/*" -print0 2>/dev/null)

if [ "$BACKUP_FAILED" -eq 1 ]; then
  fail "não consegui garantir o backup de pelo menos um escrow. ABORTANDO sem limpar nada,
      para não correr o risco de perder o escrow. Resolva o backup manualmente
      (copie os arquivos escrow.key para um local seguro) e rode o script de novo."
fi

if [ "$FOUND_ANY_ESCROW" -eq 0 ]; then
  printf 'Nenhum escrow anterior encontrado. Não é obrigatório para mineração em pool —\n'
  printf 'a Baikalmine reivindica o escrow de coinbase automaticamente em seu nome.\n'
else
  printf '\nTodos os escrows encontrados estão preservados em: %s\n' "$KEEP_DIR"
  printf 'Esse diretório NUNCA é tocado pela limpeza.\n'
fi

# ------------------------------------------------------------
section "2. PARANDO MINERADOR E LIMPANDO ESPAÇO EM DISCO"
# ------------------------------------------------------------

miner stop 2>/dev/null || true
pkill -9 -f '[k]eryx-miner' 2>/dev/null || true
sleep 2

printf 'Espaço antes da limpeza:\n'
df -h / || true

# Limpeza de sistema (segura, não envolve escrow).
apt-get clean -y 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true
journalctl --vacuum-time=2d 2>/dev/null || true
find /var/log -type f -name "*.log.*" -delete 2>/dev/null || true
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log/miner -type f -name "*.log" -mtime +3 -delete 2>/dev/null || true
rm -rf /root/.cache /home/*/.cache 2>/dev/null || true
# Remove temps de execuções ANTERIORES, mas nunca o desta execução ($$).
find /tmp -maxdepth 1 -type d -name 'keryx-install-*' ! -name "keryx-install-$$" -exec rm -rf {} + 2>/dev/null || true

# Trava de segurança: antes de remover qualquer diretório de versão antiga,
# garante que TODO escrow dentro dele já está no backup. Se algum não estiver,
# tenta o backup; se ainda assim falhar, PULA aquele diretório (não apaga).
safe_remove_dir() {
  local dir="$1" unsafe=0
  while IFS= read -r -d '' k; do
    backup_escrow "$k" || unsafe=1
  done < <(find "$dir" -iname "escrow.key" -print0 2>/dev/null)
  if [ "$unsafe" -eq 1 ]; then
    warn "PULANDO remoção de $dir — há escrow não confirmado no backup. Nada será apagado aqui."
    return 1
  fi
  rm -rf "$dir"
  return 0
}

# Remoção AGRESSIVA: para liberar espaço ao modelo de IA do OPoI, removemos
# por completo TODAS as instalações antigas do keryx-miner (cada uma carrega
# um modelo de ~2,2 GB). Preserva apenas o diretório da versão alvo.
if [ -d "$CUSTOM_DIR" ]; then
  while IFS= read -r -d '' olddir; do
    case "$olddir" in
      "$INSTALL_DIR") continue ;;              # não mexe na versão alvo
      "$CUSTOM_DIR/keryx-miner") continue ;;   # link estável, recriado depois
    esac
    printf 'Removendo instalação antiga do keryx-miner: %s\n' "$olddir"
    safe_remove_dir "$olddir" || true
  done < <(find "$CUSTOM_DIR" -mindepth 1 -maxdepth 1 -type d -iname "*keryx-miner*" -print0 2>/dev/null)
fi

printf '\nEspaço após a limpeza:\n'
df -h / || true

# O modelo de IA do OPoI PRECISA ser carregado para a mineração funcionar.
# Sem espaço suficiente, o download/carregamento do modelo falha — então aqui
# é uma PARADA DURA, não só um aviso. Limiar: ~3 GB (modelo ~2,2 GB + folga).
FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
if [ -n "${FREE_MB:-}" ] && [ "$FREE_MB" -lt 3000 ]; then
  printf '\n'
  warn "apenas ${FREE_MB} MB livres em /. O modelo de IA do OPoI (~2,2 GB) não vai caber."
  warn "Libere espaço antes de continuar. Sugestões SEGURAS (não tocam em escrow):"
  warn "  - apague imagens/arquivos grandes não usados em /home"
  warn "  - remova manualmente diretórios de mineradores que você não usa em $CUSTOM_DIR"
  warn "  - seu backup de escrow está intacto em $KEEP_DIR"
  fail "espaço insuficiente em disco para o modelo de IA. Instalação interrompida com segurança."
fi

# ------------------------------------------------------------
section "3. INSTALANDO O MINERADOR (BaikalMine/krx-miner $CUSTOM_NAME)"
#   Feito ANTES do driver de propósito: se o driver reiniciar a rig,
#   a configuração de mineração já estará 100% no disco.
# ------------------------------------------------------------

mkdir -p "$INSTALL_DIR" "$LOG_DIR"

# Garante que o diretório temporário exista (a limpeza pode tê-lo afetado).
mkdir -p "$TMP_DIR"

printf 'Baixando %s...\n' "$MINER_URL"
curl -fL --retry 10 --retry-delay 5 --connect-timeout 30 \
  -o "$TMP_DIR/keryx.tar.gz" "$MINER_URL" \
  || fail "falha ao baixar o minerador. Verifique a conexão de rede da rig."

gzip -t "$TMP_DIR/keryx.tar.gz" || fail "arquivo baixado está corrompido."

mkdir -p "$TMP_DIR/extract"
tar -xzf "$TMP_DIR/keryx.tar.gz" -C "$TMP_DIR/extract" \
  || fail "falha ao extrair o pacote do minerador."

SOURCE_BIN="$(find "$TMP_DIR/extract" -type f -name keryx-miner -print -quit)"
[ -n "$SOURCE_BIN" ] || fail "binário keryx-miner não encontrado no pacote baixado."

SOURCE_DIR="$(dirname "$SOURCE_BIN")"
cp -a "$SOURCE_DIR"/. "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR/keryx-miner"

# Restaura escrow preservado, se houver.
if [ -s "$KEEP_DIR/escrow.key" ]; then
  cp -a "$KEEP_DIR/escrow.key" "$INSTALL_DIR/escrow.key"
  chmod 600 "$INSTALL_DIR/escrow.key"
fi

cat >"$INSTALL_DIR/h-manifest.conf" <<EOF
CUSTOM_NAME=$CUSTOM_NAME
CUSTOM_VERSION=0.1.2.6-OPoI
CUSTOM_LOG_BASENAME=${LOG_FILE%.log}
EOF

cat >"$INSTALL_DIR/h-run.sh" <<EOF
#!/usr/bin/env bash
set -o pipefail

DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$DIR" || exit 1

POOL_HOST="${POOL_URL}"

# Aguarda a rede/DNS ficarem prontos antes de iniciar (evita a corrida de boot
# "Temporary failure in name resolution" logo após reiniciar a rig).
for i in \$(seq 1 30); do
  if getent hosts "\$POOL_HOST" >/dev/null 2>&1; then
    echo "DNS ok: \$POOL_HOST resolvido."
    break
  fi
  echo "aguardando rede/DNS resolver \$POOL_HOST... (\$i/30)"
  sleep 2
done

# Último recurso: se ainda não resolve e não há nameserver configurado,
# adiciona DNS público (não sobrescreve um resolv.conf já configurado).
if ! getent hosts "\$POOL_HOST" >/dev/null 2>&1; then
  if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    echo "sem nameserver — adicionando DNS público como fallback."
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >> /etc/resolv.conf 2>/dev/null || true
  fi
fi

stdbuf -oL -eL "\$DIR/keryx-miner" \\
  --threads 0 \\
  --keryxd-address stratum+tcp://${POOL_URL}:${POOL_PORT} \\
  --mining-address ${WALLET}.${WORKER_NAME} \\
  2>&1 | tee -a "$LOG_FILE"

exit "\${PIPESTATUS[0]}"
EOF

chmod +x "$INSTALL_DIR/h-run.sh"
bash -n "$INSTALL_DIR/h-run.sh" || fail "h-run.sh gerado com erro de sintaxe."

# Cópia com nome estável "keryx-miner".
rm -rf "$CUSTOM_DIR/keryx-miner"
mkdir -p "$CUSTOM_DIR/keryx-miner"
cp -a "$INSTALL_DIR"/. "$CUSTOM_DIR/keryx-miner"/

printf 'Minerador instalado em: %s\n' "$INSTALL_DIR"

# ------------------------------------------------------------
section "4. FLIGHT SHEET PARA O PAINEL HIVEOS"
# ------------------------------------------------------------

FLIGHTSHEET_FILE="/hive/keryx-baikalmine-flightsheet-${WORKER_NAME}.json"
USER_CONFIG="--threads 0 --keryxd-address stratum+tcp://${POOL_URL}:${POOL_PORT} --mining-address %WAL%.%WORKER_NAME%"

cat >"$FLIGHTSHEET_FILE" <<EOF
{"name":"BaikalMine KRX - ${WORKER_NAME}","isFavorite":false,"items":[{"coin":"KRX","pool_ssl":false,"wal_id":null,"dpool_ssl":false,"miner":"custom","miner_alt":"${CUSTOM_NAME}","miner_config":{"url":"stratum+tcp://${POOL_URL}:${POOL_PORT}","miner":"${CUSTOM_NAME}","template":"%WAL%.%WORKER_NAME%","install_url":"${MINER_URL}","user_config":"${USER_CONFIG}"},"pool_geo":[]}]}
EOF

printf 'Flight Sheet gerada em: %s\n\n' "$FLIGHTSHEET_FILE"
printf 'Para usar pelo PAINEL WEB da HiveOS (recomendado):\n'
printf '  1. Acesse https://the.hiveos.farm\n'
printf '  2. Flight Sheets > Create Flight Sheet > Import from Clipboard\n'
printf '  3. Cole o conteúdo de %s\n' "$FLIGHTSHEET_FILE"
printf '  4. Confirme sua wallet (%s) no campo de wallet do Flight Sheet\n' "$WALLET"
printf '  5. Aplique o Flight Sheet nesta rig\n\n'
printf 'Conteúdo do JSON (para copiar):\n\n'
cat "$FLIGHTSHEET_FILE"
printf '\n'

# ------------------------------------------------------------
section "5. CUDA RUNTIME (alvo: série 13) — best-effort"
#   NÃO derruba o script se falhar. Os erros de PTX são resolvidos
#   pelo DRIVER (próxima etapa), não por este pacote.
# ------------------------------------------------------------

if apt-get update 2>/dev/null; then
  if apt-get install -y "$CUDA_PKG" 2>/dev/null; then
    printf 'CUDA 13 (%s) instalado/atualizado.\n' "$CUDA_PKG"
    ldconfig 2>/dev/null || true
  else
    warn "não foi possível instalar $CUDA_PKG via apt (provavelmente o repositório CUDA"
    warn "da NVIDIA não está configurado nesta HiveOS). Isso NÃO impede a mineração:"
    warn "o que resolve o erro de PTX é o driver 580, instalado na próxima etapa."
  fi
else
  warn "apt-get update retornou erro (repositório indisponível?). Pulando o CUDA via apt."
  warn "Sem problema — o driver 580 é o que destrava o PTX."
fi

# ------------------------------------------------------------
section "6. DRIVER NVIDIA (alvo: série $DRIVER_TARGET) — ÚLTIMA etapa"
# ------------------------------------------------------------

CURRENT_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
printf 'Driver atual: %s\n' "${CURRENT_DRIVER:-desconhecido}"

DRIVER_CHANGED=0

if [[ "$CURRENT_DRIVER" == "${DRIVER_TARGET}."* ]]; then
  printf 'Driver já está na série %s. Nada a fazer.\n' "$DRIVER_TARGET"
elif command -v nvidia-driver-update >/dev/null 2>&1; then
  LIST_OUTPUT="$(nvidia-driver-update --list </dev/null 2>/dev/null || true)"
  TARGET_VERSION="$(printf '%s\n' "$LIST_OUTPUT" | grep -oE "${DRIVER_TARGET}\.[0-9]+(\.[0-9]+)?" | sort -V | tail -n1 || true)"

  printf 'Atualizando driver para a série %s...\n' "$DRIVER_TARGET"
  printf 'Isso pode demorar e a rig pode REINICIAR automaticamente ao final.\n'
  printf 'Se reiniciar: faça login e rode este script de novo — ele retoma do ponto certo.\n\n'

  if [ -n "$TARGET_VERSION" ]; then
    nvidia-driver-update "$TARGET_VERSION" </dev/null || true
  else
    # Sem versão exata no catálogo: tenta pela série (o tool aceita "580").
    nvidia-driver-update "$DRIVER_TARGET" </dev/null || true
  fi
  DRIVER_CHANGED=1
else
  warn "nvidia-driver-update não encontrado. Atualize o driver manualmente:"
  warn "  nvidia-driver-update $DRIVER_TARGET   (e depois: reboot)"
fi

# ------------------------------------------------------------
section "7. RESUMO"
# ------------------------------------------------------------

printf 'Pool: %s:%s\n' "$POOL_URL" "$POOL_PORT"
printf 'Wallet: %s\n' "$WALLET"
printf 'Worker: %s\n' "$WORKER_NAME"
printf 'Minerador: %s\n' "$INSTALL_DIR"
printf 'Driver NVIDIA: %s\n' "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo desconhecido)"

if [ "$DRIVER_CHANGED" -eq 1 ]; then
  printf '\nO driver foi atualizado. REINICIE a rig antes de minerar:\n'
  printf '  reboot\n\n'
  printf 'Após o reboot, confirme com:  nvidia-smi   (deve mostrar 580.xx)\n'
  printf 'Depois aplique a Flight Sheet pelo painel da Hive (recomendado),\n'
  printf 'ou teste manualmente com:  cd %s && ./h-run.sh\n' "$INSTALL_DIR"
  exit 0
fi

# ------------------------------------------------------------
section "8. TESTE IMEDIATO (OPCIONAL)"
# ------------------------------------------------------------

printf 'Driver já está OK e o minerador está instalado.\n'
printf 'Recomendado: aplicar a Flight Sheet pelo painel da Hive.\n\n'

read -rp 'Quer iniciar um teste manual agora neste terminal? [s/N]: ' START_NOW
case "$START_NOW" in
  s|S|y|Y) ;;
  *)
    printf '\nOk. Use a Flight Sheet pelo painel da Hive quando quiser.\n'
    exit 0
    ;;
esac

printf '\nIniciando teste manual...\n\n'
cd "$INSTALL_DIR" || fail "não consegui acessar $INSTALL_DIR"
nohup ./h-run.sh >>"$LOG_FILE" 2>&1 &
MINER_PID=$!
sleep 5

if kill -0 "$MINER_PID" 2>/dev/null; then
  printf 'Minerador em execução (PID %s).\n' "$MINER_PID"
else
  printf 'AVISO: o processo não parece estar rodando. Veja o log:\n  tail -f %s\n' "$LOG_FILE"
fi

printf '\nLog em tempo real (Ctrl+C sai sem parar o minerador):\n\n'
sleep 2
exec tail -f "$LOG_FILE"
