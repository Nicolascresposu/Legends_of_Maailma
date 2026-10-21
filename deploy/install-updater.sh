#!/bin/sh
# Installs the maailma-update timer, which runs deploy/update.sh every two
# minutes as the owner of this checkout, with Docker access for that service
# alone. Run once with sudo; run again if the checkout moves.
set -eu

deploy=$(cd "$(dirname "$0")" && pwd)
owner=$(stat -c %U "$deploy")

cat > /etc/systemd/system/maailma-update.service <<EOF
[Unit]
Description=Bring Maailma up to date with main
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
User=$owner
SupplementaryGroups=docker
ExecStart=/bin/sh $deploy/update.sh
EOF

cat > /etc/systemd/system/maailma-update.timer <<EOF
[Unit]
Description=Check for a new Maailma release every two minutes

[Timer]
OnBootSec=2min
OnUnitInactiveSec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now maailma-update.timer
echo "Installed for $owner. Follow it with: journalctl -fu maailma-update"
