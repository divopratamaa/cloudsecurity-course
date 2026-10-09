#!/usr/bin/env bash
#
# siapkan-lab.sh
# Image Docker untuk studi kasus TokoNusa.
#
# Pemakaian:
#   ./siapkan-lab.sh cek       Memeriksa image yang sudah/belum ada, tanpa mengunduh apa pun
#   ./siapkan-lab.sh minimal   Menarik MinIO saja, untuk menguji Docker dan koneksi internet
#   ./siapkan-lab.sh lengkap   Menarik seluruh image yang diperlukan
#
# Prinsip:
#   - Image yang sudah ada di laptop dilewati, sehingga skrip aman dijalankan
#     berulang kali dan tidak mengubah image yang sedang dipakai.
#   - Kegagalan satu image tidak menghentikan image lain. Ringkasan di akhir
#     menunjukkan image yang ditarik, dilewati, dan gagal.

set -uo pipefail

# ---------------------------------------------------------------------------
# Konfigurasi
# ---------------------------------------------------------------------------

# Image uji coba (mode minimal)
IMAGE_MINIMAL=(
  "minio/minio"
)

# Image tambahan untuk mode lengkap.
# kindest/node tidak memiliki tag "latest", sehingga versinya wajib ditulis.
IMAGE_LENGKAP=(
  "quay.io/keycloak/keycloak:latest"
  "hashicorp/vault"
  "aquasec/trivy"
  "kindest/node:v1.33.12"
  "aquasec/kube-bench"
  "toniblyx/prowler"
)

# Wazuh dipasang lewat docker compose resmi, bukan docker pull satu per satu.
WAZUH_REPO="https://github.com/wazuh/wazuh-docker.git"
WAZUH_REF="stable"
WAZUH_DIR="$HOME/wazuh-docker"
WAZUH_COMPOSE="$WAZUH_DIR/single-node/docker-compose.yml"

# Ruang kosong minimum (GB) yang disarankan untuk mode lengkap
DISK_MIN_GB=6

# ---------------------------------------------------------------------------
# Tampilan
# ---------------------------------------------------------------------------

HIJAU=$'\e[32m'; KUNING=$'\e[33m'; MERAH=$'\e[31m'; TEBAL=$'\e[1m'; RESET=$'\e[0m'

judul()      { printf '\n%s== %s ==%s\n' "$TEBAL" "$1" "$RESET"; }
ok()         { printf '  %s[OK]%s      %s\n' "$HIJAU" "$RESET" "$1"; }
lewati()     { printf '  %s[LEWATI]%s  %s\n' "$KUNING" "$RESET" "$1"; }
gagal()      { printf '  %s[GAGAL]%s   %s\n' "$MERAH" "$RESET" "$1"; }
peringatan() { printf '  %s[PERHATIAN]%s %s\n' "$KUNING" "$RESET" "$1"; }

DITARIK=()
DILEWATI=()
GAGAL=()

# ---------------------------------------------------------------------------
# Pemeriksaan awal
# ---------------------------------------------------------------------------

cek_prasyarat() {
  judul "Memeriksa prasyarat"

  if ! command -v docker >/dev/null 2>&1; then
    gagal "Perintah docker tidak ditemukan. Aktifkan WSL Integration di Docker Desktop."
    exit 1
  fi
  ok "Perintah docker tersedia ($(docker --version))"

  if ! docker info >/dev/null 2>&1; then
    gagal "Docker daemon tidak merespons. Pastikan Docker Desktop sedang berjalan."
    exit 1
  fi
  ok "Docker daemon merespons"
}

cek_ruang_disk() {
  # Secara default, Docker Desktop menyimpan image di disk virtual pada drive C:
  # Windows, sehingga yang diperiksa adalah ruang kosong drive C:.
  local lokasi="/mnt/c"
  [ -d "$lokasi" ] || lokasi="$HOME"

  local sisa_gb
  sisa_gb=$(df -Pk "$lokasi" | awk 'NR==2 {printf "%d", $4/1048576}')

  if [ "$sisa_gb" -lt "$DISK_MIN_GB" ]; then
    peringatan "Ruang kosong di $lokasi tinggal ${sisa_gb} GB, disarankan minimal ${DISK_MIN_GB} GB."
  else
    ok "Ruang kosong di $lokasi: ${sisa_gb} GB"
  fi
}

# ---------------------------------------------------------------------------
# Pengelolaan image
# ---------------------------------------------------------------------------

ada_di_lokal() {
  docker image inspect "$1" >/dev/null 2>&1
}

siapkan_image() {
  local image="$1"

  if ada_di_lokal "$image"; then
    lewati "$image (sudah ada)"
    DILEWATI+=("$image")
    return
  fi

  printf '  [TARIK]   %s\n' "$image"
  if docker pull "$image"; then
    ok "$image"
    DITARIK+=("$image")
  else
    gagal "$image"
    GAGAL+=("$image")
  fi
}

status_image() {
  if ada_di_lokal "$1"; then
    printf '  %s[ADA]%s     %s\n' "$HIJAU" "$RESET" "$1"
  else
    printf '  %s[BELUM]%s   %s\n' "$MERAH" "$RESET" "$1"
  fi
}

# ---------------------------------------------------------------------------
# Wazuh
# ---------------------------------------------------------------------------

daftar_image_wazuh() {
  # Membaca nama image langsung dari file compose resmi, sehingga versinya
  # selalu sesuai dengan konfigurasi Wazuh yang dipakai.
  docker compose -f "$WAZUH_COMPOSE" config --images 2>/dev/null
}

siapkan_wazuh() {
  judul "Menyiapkan Wazuh (docker compose resmi)"

  if [ -d "$WAZUH_DIR" ]; then
    lewati "Repo wazuh-docker sudah ada di $WAZUH_DIR"
  else
    if ! command -v git >/dev/null 2>&1; then
      gagal "git belum terpasang. Pasang dengan: sudo apt install git"
      GAGAL+=("wazuh-docker (repo)")
      return
    fi
    if git clone --depth 1 -b "$WAZUH_REF" "$WAZUH_REPO" "$WAZUH_DIR"; then
      ok "Repo wazuh-docker di-clone ke $WAZUH_DIR"
    else
      gagal "Clone repo wazuh-docker gagal"
      GAGAL+=("wazuh-docker (repo)")
      return
    fi
  fi

  local daftar
  if ! daftar=$(daftar_image_wazuh) || [ -z "$daftar" ]; then
    gagal "Daftar image tidak bisa dibaca dari $WAZUH_COMPOSE"
    GAGAL+=("wazuh (daftar image)")
    return
  fi

  local image
  while IFS= read -r image; do
    [ -n "$image" ] && siapkan_image "$image"
  done <<< "$daftar"
}

# ---------------------------------------------------------------------------
# Mode
# ---------------------------------------------------------------------------

mode_cek() {
  judul "Status image di laptop"
  local image
  for image in "${IMAGE_MINIMAL[@]}" "${IMAGE_LENGKAP[@]}"; do
    status_image "$image"
  done

  if [ -f "$WAZUH_COMPOSE" ]; then
    while IFS= read -r image; do
      [ -n "$image" ] && status_image "$image"
    done <<< "$(daftar_image_wazuh)"
  else
    printf '  %s[BELUM]%s   repo wazuh-docker (belum di-clone)\n' "$MERAH" "$RESET"
  fi
}

mode_minimal() {
  judul "Mode minimal: uji coba dengan MinIO"
  local image
  for image in "${IMAGE_MINIMAL[@]}"; do
    siapkan_image "$image"
  done
}

mode_lengkap() {
  cek_ruang_disk
  judul "Mode lengkap: seluruh image semester"
  local image
  for image in "${IMAGE_MINIMAL[@]}" "${IMAGE_LENGKAP[@]}"; do
    siapkan_image "$image"
  done
  siapkan_wazuh
}

ringkasan() {
  judul "Ringkasan"
  printf '  Ditarik  : %d\n' "${#DITARIK[@]}"
  printf '  Dilewati : %d\n' "${#DILEWATI[@]}"
  printf '  Gagal    : %d\n' "${#GAGAL[@]}"

  if [ "${#GAGAL[@]}" -gt 0 ]; then
    printf '\n  Yang gagal:\n'
    printf '    - %s\n' "${GAGAL[@]}"
    printf '\n  Jalankan ulang skrip setelah koneksi stabil; yang sudah berhasil akan dilewati.\n'
  fi

  judul "Image di laptop"
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
}

bantuan() {
  cat <<EOF
Pemakaian: ./siapkan-lab.sh <mode>

Mode:
  cek       Memeriksa image yang sudah/belum ada, tanpa mengunduh apa pun
  minimal   Menarik MinIO saja, untuk menguji Docker dan koneksi internet
  lengkap   Menarik seluruh image yang dipakai sepanjang semester
EOF
}

# ---------------------------------------------------------------------------
# Program utama
# ---------------------------------------------------------------------------

case "${1:-}" in
  cek)
    cek_prasyarat
    mode_cek
    ;;
  minimal)
    cek_prasyarat
    mode_minimal
    ringkasan
    ;;
  lengkap)
    cek_prasyarat
    mode_lengkap
    ringkasan
    ;;
  *)
    bantuan
    exit 1
    ;;
esac

[ "${#GAGAL[@]}" -eq 0 ]
