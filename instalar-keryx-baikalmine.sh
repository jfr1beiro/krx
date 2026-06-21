#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# INSTALADOR KERYX (KRX) PARA A POOL BAIKALMINE — HiveOS
# - Pede a wallet do usuário interativamente
# - Limpa espaço em disco (preservando escrow, se existir)
# - Confere/atualiza driver NVIDIA para a série 580
# - Confere/atualiza CUDA runtime para a série 13
# - Instala o minerador oficial da pool (BaikalMine/krx-miner)
# - Inicia a mineração e abre a visualização em tempo real
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
MINER_URL='https://github.com/BaikalMine/krx-miner/releases/download/v0.1.2.6-beta/keryx-miner-v0.1.2.6-OPoI-hiveos.tar.gz'
INSTALL_DIR="/hive/miners/custom/$CUSTOM_NAME"
CUSTOM_DIR='/hive/miners/custom'
KEEP_DIR='/hive/KEEP_ESCROW'
LOG_DIR='/var/log/miner/custom'
LOG_FILE="$LOG_DIR/$CUSTOM_NAME.log"
TMP_DIR="/tmp/keryx-install-$$"

section() {
  printf '\n============================================================\n %s\n============================================================\n' "$*"
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
  printf 'Informe o endereço da sua wallet Keryx (formato: keryx:....)\n'
  printf 'Você pode obter um endereço em: https://keryx-labs.com/wallet\n\n'
  read -rp 'Wallet: ' WALLET
fi

# Validação simples do formato esperado.
if [[ ! "$WALLET" =~ ^keryx:[a-z0-9]{40,80}$ ]]; then
  printf '\nAVISO: o endereço informado não parece seguir o formato esperado\n'
  printf '(deve começar com "keryx:" seguido de letras minúsculas e números).\n'
  read -rp 'Confirma que deseja usar este endereço mesmo assim? [s/N]: ' CONFIRM
  case "$CONFIRM" in
    s|S|y|Y) ;;
    *) fail "instalação cancelada pelo usuário." ;;
  esac
fi

printf '\nWallet configurada: %s\n' "$WALLET"

read -rp 'Nome deste worker (ex.: rig01) [padrão: hostname atual]: ' WORKER_NAME
WORKER_NAME="${WORKER_NAME:-$(hostname)}"
printf 'Worker: %s\n' "$WORKER_NAME"

# ------------------------------------------------------------
section "1. BACKUP DE SEGURANÇA DE ESCROW EXISTENTE (se houver)"
# ------------------------------------------------------------

mkdir -p "$KEEP_DIR"
chmod 700 "$KEEP_DIR"

STAMP="$(date +%Y%m%d_%H%M%S)"
FOUND_ANY_ESCROW=0

if [ -d "$CUSTOM_DIR" ]; then
  while IFS= read -r -d '' keyfile; do
    FOUND_ANY_ESCROW=1
    if [ ! -s "$KEEP_DIR/escrow.key" ] && [ -s "$keyfile" ]; then
      cp -a "$keyfile" "$KEEP_DIR/escrow.key"
      chmod 600 "$KEEP_DIR/escrow.key"
      printf 'Escrow preservado a partir de: %s\n' "$keyfile"
    fi
  done < <(find "$CUSTOM_DIR" -iname "escrow.key" -print0 2>/dev/null)
fi

if [ "$FOUND_ANY_ESCROW" -eq 0 ]; then
  printf 'Nenhum escrow anterior encontrado. Não é necessário para mineração em pool —\n'
  printf 'a Baikalmine reivindica o escrow de coinbase automaticamente em seu nome.\n'
fi

# ------------------------------------------------------------
section "2. PARANDO MINERADOR E LIMPANDO ESPAÇO EM DISCO"
# ------------------------------------------------------------

miner stop 2>/dev/null || true
pkill -9 -f '[k]eryx-miner' 2>/dev/null || true
sleep 2

printf 'Espaço antes da limpeza:\n'
df -h / || true

apt-get clean -y || true
apt-get autoremove -y || true
journalctl --vacuum-time=3d || true
find /var/log/miner -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true

if [ -d "$CUSTOM_DIR" ]; then
  while IFS= read -r -d '' modeldir; do
    printf 'Removendo modelos antigos/duplicados: %s\n' "$modeldir"
    rm -rf "$modeldir"
  done < <(find "$CUSTOM_DIR" -mindepth 2 -maxdepth 2 -type d -iname "models" -path "*keryx-miner*" -print0 2>/dev/null)
fi

printf '\nEspaço após a limpeza:\n'
df -h / || true

# ------------------------------------------------------------
section "3. DRIVER NVIDIA (alvo: série $DRIVER_TARGET)"
# ------------------------------------------------------------

CURRENT_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
printf 'Driver atual: %s\n' "${CURRENT_DRIVER:-desconhecido}"

DRIVER_CHANGED=0

if [[ "$CURRENT_DRIVER" == "${DRIVER_TARGET}."* ]]; then
  printf 'Driver já está na série %s. Nenhuma alteração necessária.\n' "$DRIVER_TARGET"
elif command -v nvidia-driver-update >/dev/null 2>&1; then
  LIST_OUTPUT="$(printf '\n' | nvidia-driver-update --list 2>/dev/null || true)"
  TARGET_VERSION="$(
    printf '%s\n' "$LIST_OUTPUT" \
      | grep -oE "${DRIVER_TARGET}\.[0-9]+\.[0-9]+" \
      | sort -V \
      | tail -n1
  )"

  if [ -n "$TARGET_VERSION" ]; then
    printf 'Instalando driver %s...\n' "$TARGET_VERSION"
    printf '%s\n' "$TARGET_VERSION" | nvidia-driver-update "$TARGET_VERSION" </dev/null || true
    DRIVER_CHANGED=1
  else
    printf 'AVISO: série %s não encontrada no catálogo. Driver atual (%s) mantido.\n' "$DRIVER_TARGET" "${CURRENT_DRIVER:-desconhecido}"
    printf 'Se necessário, troque manualmente com: nvidia-driver-update <versao>\n'
  fi
else
  printf 'AVISO: nvidia-driver-update não encontrado. Pulando esta etapa.\n'
fi

# ------------------------------------------------------------
section "4. CUDA RUNTIME (alvo: série 13)"
# ------------------------------------------------------------

apt-get update || fail "apt-get update falhou."

if apt-get install -y "$CUDA_PKG"; then
  printf 'CUDA 13 instalado/atualizado com sucesso.\n'
else
  printf 'AVISO: falha ao instalar %s. Verifique espaço em disco e repositórios.\n' "$CUDA_PKG"
fi

ldconfig

# ------------------------------------------------------------
section "5. INSTALANDO O MINERADOR (BaikalMine/krx-miner)"
# ------------------------------------------------------------

mkdir -p "$INSTALL_DIR" "$LOG_DIR"

printf 'Baixando %s...\n' "$MINER_URL"
curl -fL --retry 10 --retry-delay 5 --connect-timeout 30 \
  -o "$TMP_DIR/keryx.tar.gz" "$MINER_URL"

gzip -t "$TMP_DIR/keryx.tar.gz" || fail "arquivo baixado está corrompido."

mkdir -p "$TMP_DIR/extract"
tar -xzf "$TMP_DIR/keryx.tar.gz" -C "$TMP_DIR/extract"

SOURCE_BIN="$(find "$TMP_DIR/extract" -type f -name keryx-miner -print -quit)"
[ -n "$SOURCE_BIN" ] || fail "binário keryx-miner não encontrado no pacote baixado."

SOURCE_DIR="$(dirname "$SOURCE_BIN")"
cp -a "$SOURCE_DIR"/. "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR/keryx-miner"

# Restaura escrow preservado, se houver (não é obrigatório em pool, mas não custa manter).
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

stdbuf -oL -eL "\$DIR/keryx-miner" \\
  --threads 0 \\
  --keryxd-address stratum+tcp://${POOL_URL}:${POOL_PORT} \\
  --mining-address ${WALLET}.${WORKER_NAME} \\
  2>&1 | tee -a "$LOG_FILE"

exit "\${PIPESTATUS[0]}"
EOF

chmod +x "$INSTALL_DIR/h-run.sh"
bash -n "$INSTALL_DIR/h-run.sh"

# Mantém um link estável "keryx-miner" apontando para a versão instalada,
# útil caso o painel HiveOS use esse nome fixo em outra Flight Sheet.
rm -rf "$CUSTOM_DIR/keryx-miner"
mkdir -p "$CUSTOM_DIR/keryx-miner"
cp -a "$INSTALL_DIR"/. "$CUSTOM_DIR/keryx-miner"/

# ------------------------------------------------------------
section "6. FLIGHT SHEET PARA O PAINEL HIVEOS"
# ------------------------------------------------------------

FLIGHTSHEET_FILE="/hive/keryx-baikalmine-flightsheet-${WORKER_NAME}.json"
USER_CONFIG="--threads 0 --keryxd-address stratum+tcp://${POOL_URL}:${POOL_PORT} --mining-address %WAL%.%WORKER_NAME%"

cat >"$FLIGHTSHEET_FILE" <<EOF
{"name":"BaikalMine KRX - ${WORKER_NAME}","isFavorite":false,"items":[{"coin":"KRX","pool_ssl":false,"wal_id":null,"dpool_ssl":false,"miner":"custom","miner_alt":"${CUSTOM_NAME}","miner_config":{"url":"stratum+tcp://${POOL_URL}:${POOL_PORT}","miner":"${CUSTOM_NAME}","template":"%WAL%.%WORKER_NAME%","install_url":"${MINER_URL}","user_config":"${USER_CONFIG}"},"pool_geo":[]}]}
EOF

printf 'Arquivo de Flight Sheet gerado em: %s\n\n' "$FLIGHTSHEET_FILE"
printf 'Para usar pelo PAINEL WEB da HiveOS (recomendado — assim a rig aparece\n'
printf 'normalmente nas estatísticas e tem auto-restart gerenciado pela Hive):\n\n'
printf '  1. Acesse o painel da HiveOS (https://the.hiveos.farm)\n'
printf '  2. Vá em Flight Sheets > Create Flight Sheet > Import from Clipboard\n'
printf '  3. Cole o conteúdo do arquivo %s\n' "$FLIGHTSHEET_FILE"
printf '  4. Confirme/adicione sua wallet %s no campo de wallet do Flight Sheet\n' "$WALLET"
printf '  5. Aplique o Flight Sheet nesta rig\n'
printf '  6. Use os comandos normais da Hive: miner start / miner stop / miner\n\n'
printf 'Conteúdo do JSON (para copiar diretamente, se preferir):\n\n'
cat "$FLIGHTSHEET_FILE"
printf '\n'

# ------------------------------------------------------------
section "7. RESUMO DA CONFIGURAÇÃO"
# ------------------------------------------------------------

printf 'Pool: %s:%s\n' "$POOL_URL" "$POOL_PORT"
printf 'Wallet: %s\n' "$WALLET"
printf 'Worker: %s\n' "$WORKER_NAME"
printf 'Minerador instalado em: %s\n' "$INSTALL_DIR"
printf 'Driver NVIDIA: %s\n' "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo desconhecido)"

if [ "$DRIVER_CHANGED" -eq 1 ]; then
  printf '\nO driver foi atualizado. É necessário reiniciar a rig antes de minerar:\n'
  printf '  reboot\n'
  printf '\nApós o reboot, use a Flight Sheet gerada acima pelo painel da Hive,\n'
  printf 'ou inicie manualmente para teste com:\n'
  printf '  cd %s && ./h-run.sh\n' "$INSTALL_DIR"
  exit 0
fi

# ------------------------------------------------------------
section "8. TESTE IMEDIATO (OPCIONAL)"
# ------------------------------------------------------------

printf 'O caminho recomendado é aplicar a Flight Sheet gerada acima pelo painel\n'
printf 'da HiveOS — assim a Hive gerencia start/stop/restart e estatísticas.\n\n'
printf 'Se quiser apenas testar agora, direto neste terminal (sem usar a Flight\n'
printf 'Sheet), o minerador pode ser iniciado manualmente em modo de teste.\n\n'

read -rp 'Deseja iniciar um teste manual agora? [s/N]: ' START_NOW
case "$START_NOW" in
  s|S|y|Y) ;;
  *)
    printf '\nTeste manual não iniciado. Use a Flight Sheet pelo painel da Hive\n'
    printf 'quando estiver pronto.\n'
    exit 0
    ;;
esac

printf '\nIniciando teste manual na pool Baikalmine...\n\n'

cd "$INSTALL_DIR"
nohup ./h-run.sh >>"$LOG_FILE" 2>&1 &
MINER_PID=$!

sleep 5

if kill -0 "$MINER_PID" 2>/dev/null; then
  printf 'Minerador em execução (PID %s).\n' "$MINER_PID"
else
  printf 'AVISO: o processo não parece estar rodando. Verifique o log:\n'
  printf '  tail -f %s\n' "$LOG_FILE"
fi

printf '\nAcompanhando o log em tempo real (Ctrl+C para sair sem parar o minerador)...\n\n'
sleep 2

exec tail -f "$LOG_FILE"
