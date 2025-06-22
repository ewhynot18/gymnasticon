#!/bin/bash -e

NODE_VERSION="v12.18.3"
NODE_FILENAME="node-${NODE_VERSION}-linux-armv6l"
NODE_URL="https://unofficial-builds.nodejs.org/download/release/${NODE_VERSION}/${NODE_FILENAME}.tar.gz"
NODE_SHASUM256="de4440edf147d6b534b7dea61ef2e05eb8b7844dec93bdf324ce2c83cf7a7f3c"

NPM_VERSION="6.14.6"
NPM_TARBALL_URL="https://registry.npmjs.org/npm/-/npm-${NPM_VERSION}.tgz"

GYMNASTICON_USER=${FIRST_USER_NAME}
GYMNASTICON_GROUP=${FIRST_USER_NAME}

# Retry function for apt-get
retry_apt_get_update() {
  for i in {1..5}; do
    if on_chroot <<EOF
apt-get update --fix-missing
EOF
    then
      break
    else
      echo "apt-get update failed... retrying in $((i * 5)) seconds"
      sleep $((i * 5))
    fi
  done
}

# Retry function for curl
retry_curl_download() {
  local url="$1"
  local output="$2"
  for i in {1..5}; do
    if curl -fL --retry 5 --retry-delay 3 -o "$output" "$url"; then
      return 0
    else
      echo "curl failed... retrying in $((i * 5)) seconds"
      sleep $((i * 5))
    fi
  done
  echo "curl failed after retries."
  return 1
}

# Install Node.js
if [ ! -x "${ROOTFS_DIR}/opt/gymnasticon/node/bin/node" ]; then
  TMPD=$(mktemp -d)
  trap 'rm -rf $TMPD' EXIT
  retry_curl_download "$NODE_URL" "$TMPD/node.tar.gz"
  echo "$NODE_SHASUM256 $TMPD/node.tar.gz" | sha256sum -c
  install -v -m 644 "$TMPD/node.tar.gz" "${ROOTFS_DIR}/tmp/node.tar.gz"
  on_chroot <<EOF
    mkdir -p /opt/gymnasticon/node
    cd /opt/gymnasticon/node
    tar zxvf /tmp/node.tar.gz --strip 1

    # Fallback install of npm if not present
    if [ ! -x /opt/gymnasticon/node/bin/npm ]; then
      echo "npm not found, installing manually..."
      cd /tmp
      curl -LO ${NPM_TARBALL_URL}
      tar -xzf npm-${NPM_VERSION}.tgz
      cd package
      /opt/gymnasticon/node/bin/node bin/npm-cli.js install -g .
    fi

    chown -R "${GYMNASTICON_USER}:${GYMNASTICON_GROUP}" /opt/gymnasticon
    echo "export PATH=/opt/gymnasticon/node/bin:\$PATH" >> /home/${GYMNASTICON_USER}/.profile
    echo "raspi-config nonint get_overlay_now || export PROMPT_COMMAND=\"echo  -e '\033[1m(rw-mode)\033[0m\c'\"" >> /home/${GYMNASTICON_USER}/.profile
    echo "overctl -s" >> /home/${GYMNASTICON_USER}/.profile
EOF
fi

# Ensure git is installed
on_chroot <<EOF
  apt-get update
  apt-get install -y git
EOF

# Clone and build Gymnasticon
on_chroot <<EOF
  export PATH=/opt/gymnasticon/node/bin:\$PATH

  rm -rf /opt/gymnasticon

  for i in {1..5}; do
    if git clone https://github.com/ewhynot18/gymnasticon.git /opt/gymnasticon; then
      break
    else
      echo "git clone failed... retrying in \$((i * 5)) seconds"
      sleep \$((i * 5))
    fi
  done

  cd /opt/gymnasticon
  git checkout speed-test

  chown -R ${GYMNASTICON_USER}:${GYMNASTICON_GROUP} /opt/gymnasticon

  echo "DEBUG: node version: \$(/opt/gymnasticon/node/bin/node -v)"
  echo "DEBUG: npm version: \$(/opt/gymnasticon/node/bin/npm -v || echo 'npm not found')"

  su - ${GYMNASTICON_USER} -c '
    export PATH=/opt/gymnasticon/node/bin:\$PATH
    cd /opt/gymnasticon
    /opt/gymnasticon/node/bin/npm install
    /opt/gymnasticon/node/bin/npm run build
  '
EOF

# Fix potential apt errors early
retry_apt_get_update

# Install services and config
install -v -m 644 files/gymnasticon.json "${ROOTFS_DIR}/etc/gymnasticon.json"
install -v -m 644 files/gymnasticon.service "${ROOTFS_DIR}/etc/systemd/system/gymnasticon.service"
install -v -m 644 files/gymnasticon-mods.service "${ROOTFS_DIR}/etc/systemd/system/gymnasticon-mods.service"
install -v -m 644 files/lockrootfs.service "${ROOTFS_DIR}/etc/systemd/system/lockrootfs.service"
install -v -m 644 files/bootfs-ro.service "${ROOTFS_DIR}/etc/systemd/system/bootfs-ro.service"
install -v -m 644 files/overlayfs.sh "${ROOTFS_DIR}/etc/profile.d/overlayfs.sh"
install -v -m 755 files/overctl "${ROOTFS_DIR}/usr/local/sbin/overctl"
install -v -m 644 files/watchdog.conf "${ROOTFS_DIR}/etc/watchdog.conf"

# Enable services and system clean-up
on_chroot <<EOF
  echo 'dtparam=watchdog=on' >> /boot/config.txt
  systemctl enable watchdog
  systemctl enable gymnasticon
  systemctl enable gymnasticon-mods
  systemctl enable lockrootfs
  dphys-swapfile swapoff
  dphys-swapfile uninstall
  systemctl disable dphys-swapfile.service
  apt-get remove -y --purge logrotate fake-hwclock rsyslog || true
EOF

install -v -m 644 files/motd "${ROOTFS_DIR}/etc/motd"
install -v -m 644 files/51-garmin-usb.rules "${ROOTFS_DIR}/etc/udev/rules.d/51-garmin-usb.rules"
