#!/usr/bin/env bash
set -euo pipefail

die() { echo "[!] $*" >&2; exit 1; }
hr()  { echo "------------------------------------------------------------"; }
blank(){ echo; }
sudocmd() { sudo "$@"; }

# UI package zip (must exist in the repo as: imapsync-ui-package.zip)
: "${PACKAGE_URL:=https://raw.githubusercontent.com/BytesPulse-OE/ImapSync-With-UI/main/imapsync-ui-package.zip}"

banner() {
  blank
  hr
  echo " IMAPSYNC + Modern UI (HestiaCP / Ubuntu 24.04)"
  echo " - installs deps"
  echo " - installs imapsync to /usr/local/bin/imapsync"
  echo " - downloads UI package zip and deploys it (index + api + assets)"
  echo " - installs engine outside webroot + jobs/"
  echo " - AUTO patches open_basedir + disable_functions + restarts correct php-fpm"
  hr
  blank
}

prompt_domain() {
  echo -n "Enter subdomain (e.g. imapsync.example.com): "
  read -r DOMAIN
  DOMAIN="$(echo "${DOMAIN}" | tr -d ' ')"
  [[ -n "${DOMAIN}" ]] || die "Domain is required."
  blank
  echo "[*] Domain: ${DOMAIN}"
  blank
}

find_imapsync_source() {
  WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if sudocmd test -f "${WORKDIR}/imapsync"; then
    IMAPSYNC_SRC="${WORKDIR}/imapsync"
  elif sudocmd test -f "${WORKDIR}/imapsync source code.txt"; then
    IMAPSYNC_SRC="${WORKDIR}/imapsync source code.txt"
  else
    die "Cannot find imapsync source next to this script. Put 'imapsync' next to it."
  fi

  echo "[*] Script dir:   ${WORKDIR}"
  echo "[*] imapsync src: ${IMAPSYNC_SRC}"
  blank
}

find_webroot() {
  WEBROOT="$(sudocmd find /home -maxdepth 4 -type d -path "/home/*/web/${DOMAIN}/public_html" 2>/dev/null | head -n 1 || true)"
  [[ -n "${WEBROOT}" ]] || die "Could not find webroot for ${DOMAIN} at /home/*/web/${DOMAIN}/public_html. Create the domain/subdomain in Hestia first."

  PUBLIC_HTML="${WEBROOT}"
  BASE_DIR="$(dirname "${WEBROOT}")" # /home/<user>/web/<domain>
  ENGINE_DIR="${BASE_DIR}/imapsync-ui/engine"
  BACKUP_DIR="${BASE_DIR}/imapsync-ui/backup-$(date +%Y%m%d-%H%M%S)"

  echo "[*] Webroot: ${PUBLIC_HTML}"
  echo "[*] Engine:  ${ENGINE_DIR}"
  echo "[*] Backup:  ${BACKUP_DIR}"
  blank
}

detect_php_version_from_socket() {
  SOCK="$(ls -1 /run/php/php*-fpm-"${DOMAIN}".sock 2>/dev/null | head -n 1 || true)"
  if [[ -n "${SOCK}" ]]; then
    PHP_VER="$(basename "${SOCK}" | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm-.+\.sock$/\1/p')"
    [[ -n "${PHP_VER}" ]] || die "Found socket ${SOCK} but could not parse PHP version."
    echo "[*] Detected PHP version: ${PHP_VER}"
    echo "[*] Socket: ${SOCK}"
    blank
    return 0
  fi

  POOL_ANY="$(sudocmd grep -RIl "^\[${DOMAIN}\]" /etc/php/*/fpm/pool.d --include="*.conf" 2>/dev/null | head -n 1 || true)"
  [[ -n "${POOL_ANY}" ]] || die "Could not detect PHP version (no socket and no pool config found)."
  PHP_VER="$(echo "${POOL_ANY}" | sed -nE 's#^/etc/php/([0-9]+\.[0-9]+)/fpm/pool\.d/.*#\1#p')"
  [[ -n "${PHP_VER}" ]] || die "Could not parse PHP version from pool file: ${POOL_ANY}"
  echo "[*] Detected PHP version: ${PHP_VER}"
  echo "[*] Pool file: ${POOL_ANY}"
  blank
}

find_pool_file_and_user_group() {
  POOL_FILE="$(sudocmd grep -RIl "^\[${DOMAIN}\]" "/etc/php/${PHP_VER}/fpm/pool.d" --include="*.conf" 2>/dev/null | head -n 1 || true)"
  if [[ -z "${POOL_FILE}" ]]; then
    POOL_FILE="$(sudocmd grep -RIl "${DOMAIN}" "/etc/php/${PHP_VER}/fpm/pool.d" --include="*.conf" 2>/dev/null | head -n 1 || true)"
  fi
  [[ -n "${POOL_FILE}" ]] || die "Could not locate PHP-FPM pool file for ${DOMAIN} under /etc/php/${PHP_VER}/fpm/pool.d"

  FPM_USER="$(sudocmd awk -F= '/^\s*user\s*=/ {gsub(/[ \t]/,"",$2); print $2; exit}' "${POOL_FILE}" || true)"
  FPM_GROUP="$(sudocmd awk -F= '/^\s*group\s*=/ {gsub(/[ \t]/,"",$2); print $2; exit}' "${POOL_FILE}" || true)"
  [[ -n "${FPM_USER}" ]] || die "Could not parse 'user=' from ${POOL_FILE}"
  [[ -n "${FPM_GROUP}" ]] || FPM_GROUP="${FPM_USER}"

  echo "[*] Pool file: ${POOL_FILE}"
  echo "[*] PHP-FPM user:  ${FPM_USER}"
  echo "[*] PHP-FPM group: ${FPM_GROUP}"
  blank
}

install_deps() {
  hr
  echo "[*] Installing dependencies…"
  hr
  blank

  sudocmd apt-get update -y
  sudocmd apt-get install -y \
    perl ca-certificates curl unzip \
    libauthen-ntlm-perl \
    libcgi-pm-perl \
    libcrypt-openssl-rsa-perl \
    libdata-uniqid-perl \
    libencode-imaputf7-perl \
    libfile-copy-recursive-perl \
    libfile-tail-perl \
    libhttp-daemon-perl \
    libhttp-daemon-ssl-perl \
    libhttp-message-perl \
    libio-socket-inet6-perl \
    libio-socket-ssl-perl \
    libio-tee-perl \
    libhtml-parser-perl \
    libjson-webtoken-perl \
    libmail-imapclient-perl \
    libmodule-scandeps-perl \
    libnet-server-perl \
    libnet-dns-perl \
    libparse-recdescent-perl \
    libproc-processtable-perl \
    libreadonly-perl \
    libregexp-common-perl \
    libsys-meminfo-perl \
    libterm-readkey-perl \
    libtest-mockobject-perl \
    libunicode-string-perl \
    liburi-perl \
    libwww-perl \
    make time cpanminus \
    php-cli php-curl

  blank
}

install_imapsync() {
  hr
  echo "[*] Installing imapsync…"
  hr
  blank

  sudocmd install -m 0755 "${IMAPSYNC_SRC}" /usr/local/bin/imapsync
  sudocmd chmod 0755 /usr/local/bin/imapsync

  echo "[*] Verifying imapsync:"
  sudocmd /usr/local/bin/imapsync --version

  blank
}

download_and_deploy_zip() {
  hr
  echo "[*] Downloading UI package…"
  echo "[*] PACKAGE_URL: ${PACKAGE_URL}"
  hr
  blank

  TMPDIR="$(mktemp -d)"
  sudocmd chmod 755 "${TMPDIR}"

  ZIPFILE="${TMPDIR}/imapsync-ui-package.zip"
  sudocmd curl -fsSL "${PACKAGE_URL}" -o "${ZIPFILE}"
  sudocmd unzip -q "${ZIPFILE}" -d "${TMPDIR}/pkg"

  [[ -d "${TMPDIR}/pkg/engine" ]] || die "Package missing 'engine' folder"
  [[ -d "${TMPDIR}/pkg/public" ]] || die "Package missing 'public' folder"

  # Prepare dirs
  sudocmd mkdir -p "${ENGINE_DIR}" "${BACKUP_DIR}"

  # Backup current public entrypoints/assets
  if sudocmd test -f "${PUBLIC_HTML}/index.php"; then sudocmd cp -a "${PUBLIC_HTML}/index.php" "${BACKUP_DIR}/index.php"; fi
  if sudocmd test -d "${PUBLIC_HTML}/api"; then sudocmd cp -a "${PUBLIC_HTML}/api" "${BACKUP_DIR}/api"; fi
  if sudocmd test -d "${PUBLIC_HTML}/assets"; then sudocmd cp -a "${PUBLIC_HTML}/assets" "${BACKUP_DIR}/assets"; fi

  # Deploy engine (replace)
  sudocmd rm -rf "${ENGINE_DIR}"
  sudocmd mkdir -p "${ENGINE_DIR}"
  sudocmd cp -a "${TMPDIR}/pkg/engine/." "${ENGINE_DIR}/"

  # Deploy public folder (index + api + assets + anything else)
  sudocmd cp -a "${TMPDIR}/pkg/public/." "${PUBLIC_HTML}/"

  # Ensure assets permissions (static files)
  if sudocmd test -d "${PUBLIC_HTML}/assets"; then
    sudocmd chmod 755 "${PUBLIC_HTML}/assets" || true
    sudocmd find "${PUBLIC_HTML}/assets" -type d -exec chmod 755 {} \; 2>/dev/null || true
    sudocmd find "${PUBLIC_HTML}/assets" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi

  # Symlinks for config/lib/jobs (webroot points to engine)
  sudocmd rm -rf "${PUBLIC_HTML}/config" "${PUBLIC_HTML}/lib" "${PUBLIC_HTML}/jobs"
  sudocmd ln -s "${ENGINE_DIR}/config" "${PUBLIC_HTML}/config"
  sudocmd ln -s "${ENGINE_DIR}/lib" "${PUBLIC_HTML}/lib"
  sudocmd ln -s "${ENGINE_DIR}/jobs" "${PUBLIC_HTML}/jobs"

  # Ensure jobs perms
  sudocmd mkdir -p "${ENGINE_DIR}/jobs"
  sudocmd chown -R "${FPM_USER}:${FPM_GROUP}" "${ENGINE_DIR}/jobs"
  sudocmd chmod -R 770 "${ENGINE_DIR}/jobs"

  sudocmd rm -rf "${TMPDIR}"

  blank
}

patch_open_basedir() {
  sudocmd cp -a "${POOL_FILE}" "${POOL_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

  if sudocmd grep -q "php_admin_value\[open_basedir\]" "${POOL_FILE}"; then
    if sudocmd grep -qF "${ENGINE_DIR}" "${POOL_FILE}"; then
      echo "[*] open_basedir already contains engine path."
    else
      echo "[*] Adding engine path to open_basedir…"
      # IMPORTANT: perl $1 must NOT be expanded by bash (set -u). Keep perl in single quotes.
      sudocmd perl -0777 -i -pe 's#(php_admin_value\[open_basedir\]\s*=\s*[^\n]*)#$1:'"${ENGINE_DIR}"'#m' "${POOL_FILE}"
    fi
  else
    echo "[*] No open_basedir found. Adding safe open_basedir line…"
    sudocmd bash -c "printf '\n; Added by imapsync installer\nphp_admin_value[open_basedir] = ${PUBLIC_HTML}:${ENGINE_DIR}:/tmp\n' >> '${POOL_FILE}'"
  fi
}

patch_disable_functions() {
  if sudocmd grep -q "php_admin_value\[disable_functions\]" "${POOL_FILE}"; then
    echo "[*] Patching disable_functions (enable shell_exec)…"

    sudocmd perl -i -pe '
      if (/^\s*php_admin_value\[disable_functions\]\s*=/) {
        my ($k,$v) = split(/=/,$_,2);
        $v =~ s/\s+//g;
        my @f = grep { $_ ne "" } split(/,/, $v);
        my %rm = map { $_ => 1 } qw(shell_exec exec proc_open popen);
        @f = grep { !$rm{$_} } @f;
        $_ = $k . "= " . join(",", @f) . "\n";
      }
    ' "${POOL_FILE}"
  else
    echo "[*] No disable_functions found in pool file. (If shell_exec is disabled globally in php.ini, you must change it there.)"
  fi
}

patch_pool_and_restart() {
  hr
  echo "[*] Auto patch pool (open_basedir + disable_functions) + restart php${PHP_VER}-fpm…"
  hr
  blank

  patch_open_basedir
  patch_disable_functions

  sudocmd systemctl restart "php${PHP_VER}-fpm"
  echo "[*] Restarted: php${PHP_VER}-fpm"
  blank
}

final_notes() {
  hr
  echo "[+] Done."
  echo "Visit: https://${DOMAIN}/"
  echo "Engine config: ${ENGINE_DIR}/config/config.php"
  echo "Jobs dir: ${ENGINE_DIR}/jobs"
  echo "Pool file: ${POOL_FILE}"
  hr
  blank
}

main() {
  banner
  prompt_domain
  find_imapsync_source
  find_webroot
  detect_php_version_from_socket
  find_pool_file_and_user_group

  install_deps
  install_imapsync
  download_and_deploy_zip
  patch_pool_and_restart
  final_notes
}

main "$@"
