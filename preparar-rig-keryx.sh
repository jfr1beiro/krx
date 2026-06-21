#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# PREPARAÇÃO DE RIG HIVEOS PARA KERYX (SOLO via node próprio / Tailscale)
# - Garante o Tailscale conectado e o node acessível
# - Limpa espaço em disco (preservando o escrow)
# - Atualiza o driver NVIDIA para a série 580
# - Atualiza o CUDA runtime para a série 13
# - Mantém compatibilidade com instalar-keryx-novas-rigs.txt
# ============================================================

KEEP_DIR='/hive/KEEP_ESCROW'
CUSTOM_DIR='/hive/miners/custom'
DRIVER_TARGET='580'
CUDA_PKG='cuda-runtime-13-3'
NODE_IP='100.111.122.11'
NODE_PORT='22112'

section() {
  printf '\n============================================================\n %s\n============================================================\n' "$*"
}

fail() {
  printf '\nERRO: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "execute como root."

mkdir -p "$KEEP_DIR"
chmod 700 "$KEEP_DIR"

# ------------------------------------------------------------
section "0a. PREPARANDO TAILSCALE"
# ------------------------------------------------------------

command -v curl >/dev/null 2>&1 || {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
}

mkdir -p /dev/net /etc/modules-load.d /run/tailscale /var/lib/tailscale
printf 'tun\n' >/etc/modules-load.d/tun.conf
modprobe tun 2>/dev/null || true

if [ ! -c /dev/net/tun ]; then
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
fi

if [ ! -c /dev/net/tun ]; then
  printf '\nAVISO: /dev/net/tun não está disponível. O Tailscale pode não funcionar.\n'
fi

if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
  printf 'Instalando Tailscale...\n'
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl unmask tailscaled 2>/dev/null || true
systemctl daemon-reload
systemctl enable tailscaled >/dev/null 2>&1 || true
systemctl restart tailscaled

for _ in $(seq 1 20); do
  { [ -S /run/tailscale/tailscaled.sock ] || [ -S /var/run/tailscale/tailscaled.sock ]; } && break
  sleep 1
done

if ! systemctl is-active --quiet tailscaled; then
  printf '\nAVISO: tailscaled não iniciou corretamente.\n'
  systemctl status tailscaled --no-pager -l || true
  journalctl -u tailscaled -n 40 --no-pager || true
fi

if ! tailscale ip -4 2>/dev/null | grep -q '^100\.'; then
  printf '\nAutorize esta rig no Tailscale usando a URL exibida abaixo.\n\n'
  tailscale up --reset --hostname="$(hostname)" --accept-dns=false
fi

if tailscale ip -4 2>/dev/null | grep -q '^100\.'; then
  printf 'Tailscale conectado: %s\n' "$(tailscale ip -4 | head -n1)"
else
  printf '\nAVISO: Tailscale não ficou conectado. O minerador solo não vai alcançar o node até isso ser resolvido.\n'
fi

# ------------------------------------------------------------
section "0b. TESTANDO O NODE ($NODE_IP:$NODE_PORT)"
# ------------------------------------------------------------

NODE_OK=0
for tentativa in 1 2 3 4 5; do
  if timeout 7 bash -c "exec 3<>/dev/tcp/$NODE_IP/$NODE_PORT" 2>/dev/null; then
    NODE_OK=1
    break
  fi
  printf 'Tentativa %s/5 sem resposta do node.\n' "$tentativa"
  tailscale ping -c 1 "$NODE_IP" 2>/dev/null || true
  sleep 3
done

if [ "$NODE_OK" -eq 1 ]; then
  printf 'Node acessível em %s:%s\n' "$NODE_IP" "$NODE_PORT"
else
  printf '\nAVISO: node inacessível em %s:%s. O minerador pode falhar ao iniciar.\n' "$NODE_IP" "$NODE_PORT"
  printf 'Verifique se o node está rodando e se o Tailscale autorizou esta rig.\n'
fi

# ------------------------------------------------------------
section "0. BACKUP DE SEGURANÇA DO ESCROW (antes de qualquer limpeza)"
# ------------------------------------------------------------

STAMP="$(date +%Y%m%d_%H%M%S)"
FOUND_ANY_ESCROW=0

if [ -d "$CUSTOM_DIR" ]; then
  while IFS= read -r -d '' keyfile; do
    FOUND_ANY_ESCROW=1
    printf 'Encontrado: %s\n' "$keyfile"

    # Preserva a primeira chave válida e não vazia em KEEP_DIR,
    # sem nunca sobrescrever uma já existente.
    if [ ! -s "$KEEP_DIR/escrow.key" ] && [ -s "$keyfile" ]; then
      cp -a "$keyfile" "$KEEP_DIR/escrow.key"
      chmod 600 "$KEEP_DIR/escrow.key"
      printf '  -> preservado como %s/escrow.key\n' "$KEEP_DIR"
    fi

    # Backup individual com timestamp e nome da pasta de origem,
    # para nunca perder rastro de chaves diferentes entre versões.
    SAFE_NAME="$(printf '%s' "$keyfile" | sed 's#/#_#g')"
    cp -a "$keyfile" "$KEEP_DIR/backup_${STAMP}_${SAFE_NAME}.key" 2>/dev/null || true
  done < <(find "$CUSTOM_DIR" -iname "escrow.key" -print0 2>/dev/null)

  while IFS= read -r -d '' statefile; do
    if [ ! -s "$KEEP_DIR/escrow_state.json" ] && [ -s "$statefile" ]; then
      cp -a "$statefile" "$KEEP_DIR/escrow_state.json"
      chmod 600 "$KEEP_DIR/escrow_state.json"
      printf 'Estado de escrow preservado a partir de: %s\n' "$statefile"
    fi
  done < <(find "$CUSTOM_DIR" -iname "escrow_state.json" -print0 2>/dev/null)
fi

if [ "$FOUND_ANY_ESCROW" -eq 0 ]; then
  printf 'Nenhum escrow.key encontrado nas pastas de minerador. Nada a preservar.\n'
else
  printf '\nEscrow ativo preservado em: %s/escrow.key\n' "$KEEP_DIR"
  if [ -s "$KEEP_DIR/escrow.key" ]; then
    printf 'SHA256: %s\n' "$(sha256sum "$KEEP_DIR/escrow.key" | awk '{print $1}')"
  fi
fi

# ------------------------------------------------------------
section "1. ESPAÇO EM DISCO ANTES DA LIMPEZA"
# ------------------------------------------------------------
df -h / || true

# ------------------------------------------------------------
section "2. PARANDO O MINERADOR ANTES DE LIMPAR"
# ------------------------------------------------------------
miner stop 2>/dev/null || true
pkill -9 -f '[k]eryx-miner' 2>/dev/null || true
sleep 2

# ------------------------------------------------------------
section "3. LIMPEZA DE DISCO (sem tocar no escrow)"
# ------------------------------------------------------------

printf 'Limpando cache do apt...\n'
apt-get clean -y || true

printf 'Removendo pacotes não usados...\n'
apt-get autoremove -y || true

printf 'Limpando journal antigo...\n'
journalctl --vacuum-time=3d || true

printf 'Removendo logs antigos do minerador (mantém os últimos 7 dias)...\n'
find /var/log/miner -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true

# Remove modelos LLM e binários de versões antigas/duplicadas do keryx-miner,
# mas NUNCA remove escrow.key ou escrow_state.json (já preservados no KEEP_DIR).
if [ -d "$CUSTOM_DIR" ]; then
  printf '\nPastas de minerador encontradas:\n'
  find "$CUSTOM_DIR" -maxdepth 1 -type d -iname "*keryx*" -printf '  %p\n' 2>/dev/null || true

  printf '\nRemovendo apenas /models duplicados das pastas keryx-miner antigas (mantém binários e configs)...\n'
  while IFS= read -r -d '' modeldir; do
    printf '  removendo: %s\n' "$modeldir"
    rm -rf "$modeldir"
  done < <(find "$CUSTOM_DIR" -mindepth 2 -maxdepth 2 -type d -iname "models" -path "*keryx-miner*" -print0 2>/dev/null)
fi

printf '\nEspaço em disco após a limpeza:\n'
df -h / || true

AVAILABLE_KB="$(df --output=avail / | tail -n1 | tr -d ' ')"
AVAILABLE_MB=$((AVAILABLE_KB / 1024))
printf 'Disponível: %s MB\n' "$AVAILABLE_MB"

if [ "$AVAILABLE_MB" -lt 3000 ]; then
  printf '\nAVISO: menos de 3GB livres. A instalação do CUDA 13 pode falhar por falta de espaço.\n'
  printf 'Considere remover manualmente pastas antigas extras em %s antes de continuar.\n' "$CUSTOM_DIR"
fi

# ------------------------------------------------------------
section "4. ATUALIZANDO O DRIVER NVIDIA PARA A SÉRIE $DRIVER_TARGET"
# ------------------------------------------------------------

CURRENT_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
printf 'Driver atual: %s\n' "${CURRENT_DRIVER:-desconhecido}"

DRIVER_CHANGED=0

if [[ "$CURRENT_DRIVER" == "${DRIVER_TARGET}."* ]]; then
  printf '\nO driver já está na série %s (%s). Nenhuma alteração necessária.\n' "$DRIVER_TARGET" "$CURRENT_DRIVER"
elif command -v nvidia-driver-update >/dev/null 2>&1; then
  printf '\nVersões de driver disponíveis (apenas leitura, sem interação):\n'
  # --list é interativo (abre prompt "Enter the version to install").
  # Redirecionamos um Enter vazio para capturar a listagem sem travar
  # o script esperando input do usuário.
  LIST_OUTPUT="$(printf '\n' | nvidia-driver-update --list 2>/dev/null || true)"
  printf '%s\n' "$LIST_OUTPUT"

  TARGET_VERSION="$(
    printf '%s\n' "$LIST_OUTPUT" \
      | grep -oE "${DRIVER_TARGET}\.[0-9]+\.[0-9]+" \
      | sort -V \
      | tail -n1
  )"

  if [ -n "$TARGET_VERSION" ]; then
    printf '\nInstalando driver %s (não-interativo)...\n' "$TARGET_VERSION"
    printf '%s\n' "$TARGET_VERSION" | nvidia-driver-update "$TARGET_VERSION" </dev/null || true
    DRIVER_CHANGED=1
  else
    printf '\nAVISO: nenhuma versão %s.x disponível no catálogo do nvidia-driver-update.\n' "$DRIVER_TARGET"
    printf 'Como o driver atual (%s) já é diferente do alvo, a troca precisa ser feita manualmente:\n' "${CURRENT_DRIVER:-desconhecido}"
    printf '  nvidia-driver-update --list\n'
    printf '  nvidia-driver-update <versao_580.x_desejada>\n'
    printf 'Script seguirá sem alterar o driver.\n'
  fi
else
  printf '\nAVISO: nvidia-driver-update não encontrado neste sistema. Pulei a etapa de driver.\n'
fi

# ------------------------------------------------------------
section "5. ATUALIZANDO O CUDA RUNTIME PARA A SÉRIE 13"
# ------------------------------------------------------------

apt-get update || fail "apt-get update falhou."

printf 'Instalando %s...\n' "$CUDA_PKG"
if apt-get install -y "$CUDA_PKG"; then
  printf '\nCUDA 13 instalado/atualizado com sucesso.\n'
else
  printf '\nAVISO: falha ao instalar %s. Verifique espaço em disco e repositórios.\n' "$CUDA_PKG"
fi

ldconfig

printf '\nBibliotecas CUDA/cuBLAS disponíveis agora:\n'
ldconfig -p | grep -i cublas || printf '  nenhuma libcublas encontrada.\n'

# ------------------------------------------------------------
section "6. CONFERINDO ESCROW APÓS TODAS AS OPERAÇÕES"
# ------------------------------------------------------------

if [ -s "$KEEP_DIR/escrow.key" ]; then
  printf 'Escrow intacto em %s/escrow.key\n' "$KEEP_DIR"
  printf 'SHA256: %s\n' "$(sha256sum "$KEEP_DIR/escrow.key" | awk '{print $1}')"
else
  printf 'Nenhum escrow preservado (não havia chave anterior nesta rig).\n'
fi

# ------------------------------------------------------------
section "7. PRÓXIMO PASSO"
# ------------------------------------------------------------

if [ "${DRIVER_CHANGED:-0}" -eq 1 ]; then
  printf '\nO driver NVIDIA foi atualizado. É NECESSÁRIO reiniciar a rig agora.\n'
  printf 'O script NÃO vai iniciar o minerador automaticamente neste caso,\n'
  printf 'pois o driver novo só é aplicado de fato após o reboot.\n'
  printf '\nExecute manualmente:\n'
  printf '  reboot\n'
  printf '\nApós o reboot, confirme o driver e inicie o minerador com:\n'
  printf '  nvidia-smi --query-gpu=driver_version --format=csv\n'
  printf '  miner start\n'
  printf '  miner\n'

  section "RESUMO FINAL"
  printf 'Driver alvo: série %s (reboot pendente)\n' "$DRIVER_TARGET"
  printf 'CUDA instalado: %s\n' "$CUDA_PKG"
  printf 'Node: %s:%s\n' "$NODE_IP" "$NODE_PORT"
  printf 'Tailscale: %s\n' "$(tailscale ip -4 2>/dev/null | head -n1 || echo 'não conectado')"
  printf 'Escrow preservado em: %s/escrow.key\n' "$KEEP_DIR"
  printf 'Espaço em disco final:\n'
  df -h / || true
  exit 0
fi

# ------------------------------------------------------------
section "8. INICIANDO O MINERADOR"
# ------------------------------------------------------------

printf 'Nenhum reboot pendente. Verificando conectividade antes de iniciar...\n\n'

if ! tailscale ip -4 2>/dev/null | grep -q '^100\.'; then
  printf 'AVISO: Tailscale não está conectado agora. Tentando reconectar...\n'
  tailscale up --accept-dns=false || true
fi

if ! timeout 7 bash -c "exec 3<>/dev/tcp/$NODE_IP/$NODE_PORT" 2>/dev/null; then
  printf 'AVISO: node %s:%s ainda inacessível. O minerador será iniciado mesmo assim,\n' "$NODE_IP" "$NODE_PORT"
  printf 'mas pode falhar até a conectividade ser restabelecida.\n'
fi

printf '\nIniciando o minerador agora...\n\n'

miner start || true
sleep 5

if pgrep -af '[k]eryx-miner' >/dev/null 2>&1; then
  printf 'Minerador em execução.\n'
else
  printf 'AVISO: não foi possível confirmar o processo do minerador via pgrep.\n'
  printf 'Verifique manualmente com: miner\n'
fi

section "RESUMO FINAL"
printf 'Driver alvo: série %s\n' "$DRIVER_TARGET"
printf 'CUDA instalado: %s\n' "$CUDA_PKG"
printf 'Node: %s:%s\n' "$NODE_IP" "$NODE_PORT"
printf 'Tailscale: %s\n' "$(tailscale ip -4 2>/dev/null | head -n1 || echo 'não conectado')"
printf 'Escrow preservado em: %s/escrow.key\n' "$KEEP_DIR"
printf 'Espaço em disco final:\n'
df -h / || true

printf '\nAbrindo a visualização em tempo real do minerador (tela "miner").\n'
printf 'Para sair da tela sem parar o minerador, use: Ctrl+a depois d\n\n'
sleep 2

exec miner
