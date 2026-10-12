#!/usr/bin/env bash
# Render the XPAM brand kit into every repo. Needs rsvg-convert and a running jms_core (Pillow, for .ico/.icns).
set -euo pipefail
cd "$(dirname "$0")"
python3 make_brand.py
O=out; C=/opt/xpam-core/apps/static/img; W=/opt/xpam-web/src/assets/img; S=/opt/xpam-workspace; E=$S/electron/assets/icons; L=$S/applets/weblite/assets
png() { rsvg-convert "${@:3}" "$O/$1" -o "$2"; }

# core
png icon.svg $C/logo.png -w 256 -h 256
png mark-white.svg $C/logo_white.png -w 256 -h 256
png logo-text-teal.svg $C/logo_text.png -h 100
png logo-text-white.svg $C/logo_text_white.png -h 60
cp $O/logo-text-white.svg $C/logo_text_white.svg
cp $O/logo-text-white.svg $C/JumpServer_white_logo.svg
png icon-mac.svg $C/login_image.png -w 800 -h 800
# web
cp $O/icon.svg $W/logo.svg
png logo-text-teal.svg $W/logo_text_green.png -h 40
png logo-text-white.svg $W/logo_text_white_spaced.png -h 60
# workspace
png icon.svg $S/public/logo.png -w 256 -h 256
cp $O/icon.svg $S/ui/assets/logo.svg
# desktop client
for n in 32:32x32.png 128:128x128.png 256:128x128@2x.png 512:icon.png 512:icon-appimage.png 373:icon3.png; do
  png icon.svg "$E/${n#*:}" -w "${n%%:*}" -h "${n%%:*}"
done
png icon-mac.svg $E/icon-mac.png -w 512 -h 512
png mark-teal.svg $E/tray-mac.png -w 156 -h 156
cp $O/icon.svg $E/icon.svg; cp $O/icon.svg $E/icon-windows.svg
# WebLite helper
cp $O/icon.svg $L/icon.svg; png icon.svg $L/icon.png -w 512 -h 512

# .ico / .icns through Pillow inside the core container
png icon.svg $O/_icon1024.png -w 1024 -h 1024
png icon-mac.svg $O/_mac1024.png -w 1024 -h 1024
docker exec jms_core mkdir -p /tmp/brand
docker cp $O/_icon1024.png jms_core:/tmp/brand/icon.png
docker cp $O/_mac1024.png jms_core:/tmp/brand/mac.png
docker exec jms_core /opt/py3/bin/python -c "
from PIL import Image
i = Image.open('/tmp/brand/icon.png').convert('RGBA')
i.save('/tmp/brand/favicon.ico', sizes=[(16,16),(32,32),(48,48),(64,64)])
i.save('/tmp/brand/icon.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
Image.open('/tmp/brand/mac.png').convert('RGBA').save('/tmp/brand/icon.icns')
"
docker cp jms_core:/tmp/brand/favicon.ico $O/favicon.ico
docker cp jms_core:/tmp/brand/icon.ico $O/icon.ico
docker cp jms_core:/tmp/brand/icon.icns $O/icon.icns
docker exec jms_core rm -rf /tmp/brand; rm -f $O/_icon1024.png $O/_mac1024.png
cp $O/favicon.ico $C/facio.ico; cp $O/favicon.ico $S/ui/assets/facio.ico
cp $O/icon.ico $E/icon.ico; cp $O/icon.icns $E/icon.icns; cp $O/icon.ico $L/icon.ico
echo "brand kit applied"
