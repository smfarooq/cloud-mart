#!/usr/bin/env bash
# Phase 15: the legacy shop's product photos, one folder per product, the way its file server kept them. cloud-init
# runs this once at first boot; it does nothing when the folder already exists.
#
# Two photos are there to be found by the migration, the way real file shares hide surprises:
#   - fabrikam-studio-mic/scan.bmp: a format CloudMart's upload pipeline refuses (PNG, JPEG, WebP and GIF only).
#   - legacy-gift-card/photo.png: a product the new shop doesn't sell.
set -euo pipefail

root=/srv/legacy-shop/images
[[ -d $root ]] && exit 0

draw() { # <product id> <label> <colour> <file name>
  mkdir -p "$root/$1"
  convert -size 800x600 "gradient:$3-white" -font DejaVu-Sans -fill '#1b1b1b' \
    -gravity center -pointsize 44 -annotate +0-20 "$2" \
    -pointsize 22 -annotate +0+40 "Legacy shop photo: $1" \
    "$root/$1/$4"
}

while IFS='|' read -r id label colour; do
  draw "$id" "$label" "$colour" photo.png
done <<'EOF'
contoso-ultrabook-14|Contoso Ultrabook 14|#9ecae1
contoso-workstation-16|Contoso Workstation 16|#6baed6
fabrikam-anc-headphones|Fabrikam ANC Headphones|#c7e9c0
northwind-mech-keyboard|Northwind Mechanical Keyboard|#fdd0a2
northwind-4k-monitor|Northwind 27" 4K Monitor|#fdae6b
tailspin-smart-speaker|Tailspin Smart Speaker|#dadaeb
woodgrove-desk-lamp|Woodgrove Desk Lamp|#fee391
legacy-gift-card|Gift card (discontinued)|#fcbba1
EOF

draw fabrikam-studio-mic 'Fabrikam Studio Mic' '#a1d99b' scan.bmp

find "$root" -type f | sort
du -sh "$root"
