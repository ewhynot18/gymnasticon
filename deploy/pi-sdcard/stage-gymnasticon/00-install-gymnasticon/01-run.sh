#!/bin/bash -e

NODE_SHASUM256=de4440edf147d6b534b7dea61ef2e05eb8b7844dec93bdf324ce2c83cf7a7f3c
NODE_URL=https://unofficial-builds.nodejs.org/download/release/v12.18.3/node-v12.18.3-linux-armv6l.tar.gz
NPM_VERSION=6.14.6
GYMNASTICON_USER=${FIRST_USER_NAME}
GYMNASTICON_GROUP=${FIRST_USER_NAME}

# Install Node.js
if [ ! -x "${ROOTFS_DIR}/opt/gymnasticon/node/bin/node" ]; then
  TMPD=$(mktemp -d)
  trap 'rm -rf $TMPD' EXIT
  curl -Lo $TMPD/node.tar.gz ${NODE_URL}
  sha256sum -c <(echo "$NODE_SHASUM256 $TMPD/node.tar.gz")
  install -v -m 644 "$TMPD/node.tar.gz" "${ROOTFS_DIR}/tmp/node.tar.gz"
  on_chroot <<EOF
    mkdir -p /opt/gymnasticon/node
    cd /opt/gymnasticon/node
    tar zxvf /tmp/node.tar.gz --strip 1
    chown -R "${GYMNASTICON_USER}:${GYMNASTICON_GROUP}" /opt/gymnasticon
    echo "export PATH=/opt/gymnasticon/node/bin:\$PATH" >> /home/pi/.profile
    echo "raspi-config nonint get_overlay_now || export PROMPT_COMMAND=\"echo  -e '\033[1m(rw-mode)\033[0m\c'\"" >> /home/pi/.profile
    echo "overctl -s" >> /home/pi/.profile
EOF
fi

# Copy npm tarball into image
install -v -m 644 files/npm-${NPM_VERSION}.tgz "${ROOTFS_DIR}/opt/gymnasticon/npm-${NPM_VERSION}.tgz"

# Install Gymnasticon from your repo and run npm install/build
on_chroot <<EOF
  export PATH=/opt/gymnasticon/node/bin:\$PATH

  # Remove old install
  rm -rf /opt/gymnasticon

  # Install npm manually
  mkdir -p /opt/npm
  tar -xzf /opt/gymnasticon/npm-${NPM_VERSION}.tgz -C /opt/npm --strip-components=1
  cd /opt/npm
  /opt/gymnasticon/node/bin/node bin/npm-cli.js install -g npm@${NPM_VERSION}

  # Clone your fork and branch
  git clone https://github.com/ewhynot18/gymnasticon.git /opt/gymnasticon
  cd /opt/gymnasticon
  git checkout speed-test
  chown -R ${GYMNASTICON_USER}:${GYMNASTICON_GROUP} /opt/gymnasticon

  # Install dependencies and build
  su - ${GYMNASTICON_USER} -c '
    export PATH=/opt/gymnasticon/node/bin:\$PATH
    cd /opt/gymnasticon
    npm install
    npm run build
  '
EOF

# Install services and files
install -v -m 644 files/gymnasticon.json "${ROOTFS_DIR}/etc/gymnasticon.json"
install -v -m 644 files/gymnasticon.service "${ROOTFS_DIR}/etc/systemd/system/gymnasticon.service"
install -v -m 644 files/gymnasticon-mods.service "${ROOTFS_DIR}/etc/systemd/system/gymnasticon-mods.service"
install -v -m 644 files/lockrootfs.service "${ROOTFS_DIR}/etc/systemd/system/lockrootfs.service"
install -v -m 644 files/bootfs-ro.service "${ROOTFS_DIR}/etc/systemd/system/bootfs-ro.service"
install -v -m 644 files/overlayfs.sh "${ROOTFS_DIR}/etc/profile.d/overlayfs.sh"
install -v -m 755 files/overctl "${ROOTFS_DIR}/usr/local/sbin/overctl"
install -v -m 644 files/watchdog.conf "${ROOTFS_DIR}/etc/watchdog.conf"
install -v -m 644 files/motd "${ROOTFS_DIR}/etc/motd"
install -v -m 644 files/51-garmin-usb.rules "${ROOTFS_DIR}/etc/udev/rules.d/51-garmin-usb.rules"

# Enable services and clean system
on_chroot <<EOF
  echo 'dtparam=watchdog=on' >> /boot/config.txt
  systemctl enable watchdog
  systemctl enable gymnasticon
  systemctl enable gymnasticon-mods
  systemctl enable lockrootfs
  dphys-swapfile swapoff
  dphys-swapfile uninstall
  systemctl disable dphys-swapfile.service
  apt-get remove -y --purge logrotate fake-hwclock rsyslog
EOF
