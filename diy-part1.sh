#!/bin/bash
# ==============================================================================
# ZTE E8820V2 Custom OpenWrt 21.02 Firmware Builder (900-Router Yemen AP Edition)
# ==============================================================================
# Verified against your ZTE E8820V2 hardware dump:
#   - Partition layout: mtd0="u-boot" (0x30000), mtd1="u-boot-env" (0x10000),
#     mtd2="factory" (0x10000), mtd3="firmware" (0xfb0000)
#   - Confirmed TAGH0201 header at /dev/mtd0 offset 0x20000:
#     * 0x20014 (decimal 131092): 8c:68:c8:b1:77:a8 (Original Sticker LAN/2.4G MAC)
#     * 0x20024 (decimal 131108): 8c:68:c8:b1:77:a9 (Original 5G MAC)
#     * 0x2F000 (decimal 192512): Original 2.4GHz MT7603 EEPROM calibration
#     * 0x2F800 (decimal 194560): Original 5GHz MT7612 EEPROM calibration
#
# What this firmware does automatically on all 900 routers upon first boot:
# 1. English Language Only: Removes Chinese packages and forces English UI.
# 2. Automatic Hardware MAC & EEPROM Restoration (Zero Manual Work):
#    Extracts each router's true sticker MAC (0x20014 & 0x20024) and original RF
#    calibration (0x2F000 & 0x2F800) from /dev/mtd0, injects the 5GHz high-power
#    PA boost bytes at 0x81E0, writes them permanently into the `factory` (mtd2)
#    partition AND UCI network/wireless configs.
# 3. Maximum Wi-Fi TX Power (30 dBm / 1000mW) Unlocked:
#    Patches wireless-regdb to 30 dBm across all 2.4GHz & 5GHz channels, zeroes
#    antenna gain reduction (`iw phy set antenna_gain 0`), and unlocks PA power.
# 4. DHCP & Unused Services Permanently Disabled:
#    Disables IPv4 & IPv6 DHCP servers, removes IPv6 ULA prefix, and permanently
#    stops & disables `odhcpd`, `firewall`, `dnsmasq`, and `log` at startup.
# 5. Correct Switch Port Mapping (All 5 Gigabit Ports Bridged for AP Mode):
#    Orders LAN1, LAN2, LAN3, LAN4, WAN cleanly and bridges them for AP usage.
# 6. Built-in Quick Setup Web UI (واجهة البرمجة السريعة):
#    Available from LuCI > System > "البرمجة السريعة" or at
#    http://192.168.1.1/cgi-bin/quick to change IP, SSID, Password, and TX Power.
# ==============================================================================

set -e

# Detect if running inside an existing OpenWrt source directory (GitHub Actions)
if [ -f "Config.in" ] && [ -d "target/linux/ramips" ]; then
    OPENWRT_DIR="$(pwd)"
    IN_GITHUB_ACTIONS=1
    echo ">>> Detected existing OpenWrt source tree at: ${OPENWRT_DIR}"
else
    WORK_DIR="$(pwd)/openwrt_e8820v2_build"
    OPENWRT_BRANCH="openwrt-21.02"
    IN_GITHUB_ACTIONS=0

    echo "=== [1/7] Installing build dependencies (Ubuntu/Debian) ==="
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y build-essential clang flex bison g++ gawk \
            gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
            python3-distutils rsync unzip zlib1g-dev file wget
    fi

    echo "=== [2/7] Cloning OpenWrt ${OPENWRT_BRANCH} source tree ==="
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"
    if [ ! -d "openwrt" ]; then
        git clone https://github.com/openwrt/openwrt.git -b "${OPENWRT_BRANCH}" openwrt
    fi
    cd openwrt
    OPENWRT_DIR="$(pwd)"
fi

echo "=== [3/7] Injecting ZTE E8820V2 Device Tree (DTS) with Writable Factory Partition ==="
# Note: `factory` partition at 0x40000 is intentionally made writable (no read-only)
# so the first-boot script can permanently sync each router's real MAC from 0x20014!
cat > ./target/linux/ramips/dts/mt7621_zte_e8820v2.dts << 'EOF'
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT
#include "mt7621.dtsi"
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/input/input.h>

/ {
	compatible = "zte,e8820v2", "mediatek,mt7621-soc";
	model = "ZTE E8820V2";

	aliases {
		led-boot = &led_sys;
		led-failsafe = &led_sys;
		led-running = &led_sys;
		led-upgrade = &led_sys;
		label-mac-device = &gmac0;
	};

	chosen {
		bootargs = "console=ttyS0,115200 rootfstype=squashfs,jffs2";
	};

	memory@0 {
		device_type = "memory";
		reg = <0x0 0x4000000>;
	};

	leds {
		compatible = "gpio-leds";

		led_sys: sys {
			label = "white:sys";
			gpios = <&gpio 29 GPIO_ACTIVE_LOW>;
		};

		led_power: power {
			label = "white:power";
			gpios = <&gpio 31 GPIO_ACTIVE_LOW>;
		};
	};

	keys {
		compatible = "gpio-keys";

		reset {
			label = "reset";
			gpios = <&gpio 18 GPIO_ACTIVE_LOW>;
			linux,code = <KEY_RESTART>;
		};

		wps {
			label = "wps";
			gpios = <&gpio 24 GPIO_ACTIVE_LOW>;
			linux,code = <KEY_WPS_BUTTON>;
		};
	};
};

&spi0 {
	status = "okay";

	flash@0 {
		compatible = "jedec,spi-nor";
		reg = <0>;
		spi-max-frequency = <25000000>;
		broken-flash-reset;

		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;

			partition@0 {
				label = "u-boot";
				reg = <0x0 0x30000>;
			};

			partition@30000 {
				label = "u-boot-env";
				reg = <0x30000 0x10000>;
			};

			factory: partition@40000 {
				label = "factory";
				reg = <0x40000 0x10000>;
			};

			partition@50000 {
				compatible = "denx,uimage";
				label = "firmware";
				reg = <0x50000 0xfb0000>;
			};
		};
	};
};

&pcie {
	status = "okay";
};

&pcie0 {
	mt76@0,0 {
		reg = <0x0000 0 0 0 0>;
		mediatek,mtd-eeprom = <&factory 0x0000>;
		ieee80211-freq-limit = <2400000 2500000>;
		led {
			led-active-low;
		};
	};
};

&pcie1 {
	mt76@0,0 {
		reg = <0x0000 0 0 0 0>;
		mediatek,mtd-eeprom = <&factory 0x8000>;
		ieee80211-freq-limit = <5000000 6000000>;
		led {
			led-sources = <2>;
			led-active-low;
		};
	};
};

&gmac0 {
	mtd-mac-address = <&factory 0xe000>;
};

&switch0 {
	ports {
		port@0 {
			status = "okay";
			label = "lan1";
		};

		port@1 {
			status = "okay";
			label = "lan2";
		};

		port@2 {
			status = "okay";
			label = "lan3";
		};

		port@3 {
			status = "okay";
			label = "lan4";
		};

		port@4 {
			status = "okay";
			label = "wan";
			mtd-mac-address = <&factory 0xe006>;
		};
	};
};

&state_default {
	gpio {
		groups = "i2c", "uart2", "uart3", "wdt";
		function = "gpio";
	};
};
EOF

# Register ZTE E8820V2 in mt7621.mk (with broad SUPPORTED_DEVICES so Web UI flashing never complains)
if ! grep -q "Device/zte_e8820v2" ./target/linux/ramips/image/mt7621.mk; then
cat >> ./target/linux/ramips/image/mt7621.mk << 'EOF'

define Device/zte_e8820v2
  $(Device/dsa-migration)
  $(Device/uimage-lzma-loader)
  IMAGE_SIZE := 16064k
  DEVICE_VENDOR := ZTE
  DEVICE_MODEL := E8820V2
  SUPPORTED_DEVICES += zte,e8820v2 e8820v2 zte,e8822
  DEVICE_PACKAGES := kmod-mt7603 kmod-mt76x2 kmod-usb3 kmod-usb-ledtrig-usbport wpad-basic-wolfssl iw iwinfo luci
endef
TARGET_DEVICES += zte_e8820v2
EOF
fi

# Add LED definitions
if ! grep -q "zte,e8820v2)" ./target/linux/ramips/mt7621/base-files/etc/board.d/01_leds; then
sed -i 's/^esac/zte,e8820v2)\n\tucidef_set_led_netdev "sys" "SYS_LED" "white:sys" "eth0" "tx rx"\n\tucidef_set_led_timer "power" "POWER_LED" "white:power" "100" "8000"\n\t;;\nesac/g' ./target/linux/ramips/mt7621/base-files/etc/board.d/01_leds
fi

echo "=== [4/7] Unlocking 30 dBm (1000mW) TX Power in RegDB ==="
mkdir -p ./package/firmware/wireless-regdb/patches
cat > ./package/firmware/wireless-regdb/patches/999-unlock-max-txpower-yemen.patch << 'EOF'
--- a/db.txt
+++ b/db.txt
@@ -1,8 +1,8 @@
 country 00:
-	(2402 - 2472 @ 40), (20)
-	(2457 - 2482 @ 20), (20), AUTO-BW, PASSIVE-SCAN
-	(2474 - 2494 @ 20), (20), NO-OFDM, PASSIVE-SCAN
-	(5170 - 5250 @ 80), (20), AUTO-BW, PASSIVE-SCAN
-	(5250 - 5330 @ 80), (20), DFS, AUTO-BW, PASSIVE-SCAN
-	(5490 - 5730 @ 160), (20), DFS, PASSIVE-SCAN
-	(5735 - 5835 @ 80), (20), PASSIVE-SCAN
+	(2402 - 2482 @ 40), (30)
+	(5170 - 5250 @ 80), (30), AUTO-BW
+	(5250 - 5330 @ 80), (30), AUTO-BW
+	(5490 - 5730 @ 160), (30), AUTO-BW
+	(5735 - 5835 @ 80), (30), AUTO-BW
EOF

echo "=== [5/7] Creating Embedded Files: Auto-MAC/EEPROM Sync, Service Disabler & Quick Setup UI ==="
mkdir -p ./files/etc/uci-defaults
mkdir -p ./files/etc/hotplug.d/ieee80211
mkdir -p ./files/www/cgi-bin
mkdir -p ./files/www
mkdir -p ./files/usr/lib/lua/luci/controller

# 5.3 Add a LuCI menu entry for the existing Quick Setup page
cat > ./files/usr/lib/lua/luci/controller/quicksetup.lua << 'EOF'
module("luci.controller.quicksetup", package.seeall)

function index()
    entry({"admin", "system", "quicksetup"}, call("action_index"), _("البرمجة السريعة"), 90)
end

function action_index()
    luci.http.redirect("/cgi-bin/quick")
end
EOF

# 5.1 Hotplug script to zero out antenna_gain reduction so full 30 dBm reaches the PA
cat > ./files/etc/hotplug.d/ieee80211/99-max-txpower << 'EOF'
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
if command -v iw >/dev/null 2>&1; then
    iw phy "${DEVICENAME}" set antenna_gain 0 2>/dev/null || true
fi
EOF
chmod +x ./files/etc/hotplug.d/ieee80211/99-max-txpower

# 5.2 Create uci-defaults script (runs automatically on first boot after flashing)
cat > ./files/etc/uci-defaults/99-yemen-ap-custom << 'EOF'
#!/bin/sh

# ------------------------------------------------------------------------------
# 1. Force System Language to English & Set Timezone to Yemen (AST-3)
# ------------------------------------------------------------------------------
uci set system.@system[0].hostname='ZTE-E8820V2'
uci set system.@system[0].zonename='Asia/Aden'
uci set system.@system[0].timezone='<+03>-3'
uci set luci.main.lang='en'
uci commit system
uci commit luci

# ------------------------------------------------------------------------------
# 2. Automatic Original Sticker MAC & Factory EEPROM Sync (Verified on TAGH0201)
# ------------------------------------------------------------------------------
# Confirmed on your ZTE E8820V2 dump (/dev/mtd0):
#   - 0x20000 (131072): "TAGH0201" ZTE header
#   - 0x20014 (131092): 6-byte Original Sticker MAC (e.g. 8c:68:c8:b1:77:a8)
#   - 0x20024 (131108): 6-byte Original 5GHz MAC    (e.g. 8c:68:c8:b1:77:a9)
#   - 0x2F000 (192512): Original 2.4GHz MT7603 EEPROM calibration (starts 03 76)
#   - 0x2F800 (194560): Original 5GHz MT7612 EEPROM calibration   (starts 62 76)

read_mac_hex() {
    local mtd_dev="$1"
    local offset="$2"
    dd if="$mtd_dev" bs=1 skip=$((offset)) count=6 2>/dev/null | hexdump -v -e '1/1 "%02x:"' | sed 's/:$//'
}

is_valid_mac() {
    local mac="$1"
    [ -z "$mac" ] && return 1
    [ "$mac" = "ff:ff:ff:ff:ff:ff" ] && return 1
    [ "$mac" = "00:00:00:00:00:00" ] && return 1
    local first_byte="0x$(echo "$mac" | cut -d: -f1)"
    [ $((first_byte & 1)) -eq 0 ] || return 1
    return 0
}

increment_mac() {
    local mac="$1"
    local step="$2"
    local prefix=$(echo "$mac" | cut -d: -f1-5)
    local last="0x$(echo "$mac" | cut -d: -f6)"
    local next=$(( (last + step) & 0xff ))
    printf "%s:%02x" "$prefix" "$next"
}

ORIG_MAC_2G=$(read_mac_hex /dev/mtd0 131092)
ORIG_MAC_5G=$(read_mac_hex /dev/mtd0 131108)
FAC_MAC_E000=$(read_mac_hex /dev/mtd2 57344)
FAC_MAC_0004=$(read_mac_hex /dev/mtd2 4)

if is_valid_mac "$ORIG_MAC_2G"; then
    if ! is_valid_mac "$ORIG_MAC_5G" || [ "$ORIG_MAC_5G" = "$ORIG_MAC_2G" ]; then
        ORIG_MAC_5G=$(increment_mac "$ORIG_MAC_2G" 1)
    fi

    # Check if /dev/mtd2 (factory) has a duplicated/mismatched MAC or needs PA boost
    if [ "$FAC_MAC_E000" != "$ORIG_MAC_2G" ] || [ "$FAC_MAC_0004" != "$ORIG_MAC_2G" ]; then
        dd if=/dev/mtd2 of=/tmp/factory.bin bs=65536 count=1 2>/dev/null

        # If original ZTE 2.4G calibration exists at 0x2F000 (192512), copy it
        SIG_2G=$(dd if=/dev/mtd0 bs=1 skip=192512 count=2 2>/dev/null | hexdump -v -e '1/1 "%02x"')
        if [ "$SIG_2G" = "0376" ]; then
            dd if=/dev/mtd0 of=/tmp/factory.bin bs=1 skip=192512 seek=0 count=304 conv=notrunc 2>/dev/null
        fi

        # If original ZTE 5G calibration exists at 0x2F800 (194560), copy it
        SIG_5G=$(dd if=/dev/mtd0 bs=1 skip=194560 count=2 2>/dev/null | hexdump -v -e '1/1 "%02x"')
        if [ "$SIG_5G" = "6276" ]; then
            dd if=/dev/mtd0 of=/tmp/factory.bin bs=1 skip=194560 seek=32768 count=496 conv=notrunc 2>/dev/null
        fi

        # Write high-power 5GHz external PA calibration bytes at 0x81E0 (33248)
        printf '\xc0\x81\x82\xc3\x04\x45\x46\x07\x08\x09' | dd of=/tmp/factory.bin bs=1 seek=33248 count=10 conv=notrunc 2>/dev/null

        # Write original 2.4G/LAN MAC (0x20014) to factory 0x0004 (4) and 0xE000 (57344)
        dd if=/dev/mtd0 of=/tmp/factory.bin bs=1 skip=131092 seek=4 count=6 conv=notrunc 2>/dev/null
        dd if=/dev/mtd0 of=/tmp/factory.bin bs=1 skip=131092 seek=57344 count=6 conv=notrunc 2>/dev/null

        # Write original 5G MAC (0x20024) to factory 0x8004 (32772) and 0xE006 (57350)
        dd if=/dev/mtd0 of=/tmp/factory.bin bs=1 skip=131108 seek=32772 count=6 conv=notrunc 2>/dev/null
        dd if=/dev/mtd0 of=/tmp/factory.bin bs=1 skip=131108 seek=57350 count=6 conv=notrunc 2>/dev/null

        # Flash updated factory partition permanently
        mtd write /tmp/factory.bin factory 2>/dev/null || true
        rm -f /tmp/factory.bin
    fi

    # Set MAC addresses explicitly in UCI configs as well
    uci set network.lan.macaddr="$ORIG_MAC_2G"
    uci set network.wan.macaddr="$ORIG_MAC_5G"
    uci set wireless.radio0.macaddr="$ORIG_MAC_2G"
    uci set wireless.radio1.macaddr="$ORIG_MAC_5G"
fi

# ------------------------------------------------------------------------------
# 3. Disable DHCP Server (IPv4 & IPv6) & Bridge All 5 Gigabit Ports for AP Mode
# ------------------------------------------------------------------------------
uci delete network.globals.ula_prefix 2>/dev/null || true

# Bridge lan1, lan2, lan3, lan4, and wan together so all 5 ports act as AP switch
if uci -q get network.@device[0].ports >/dev/null; then
    uci set network.@device[0].ports='lan1 lan2 lan3 lan4 wan'
fi
uci delete network.wan 2>/dev/null || true
uci delete network.wan6 2>/dev/null || true

uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.ipv6='0'

# Disable DHCPv4 & DHCPv6 on LAN completely
uci set dhcp.lan.ignore='1'
uci delete dhcp.lan.ra 2>/dev/null || true
uci delete dhcp.lan.dhcpv6 2>/dev/null || true
uci delete dhcp.lan.ndp 2>/dev/null || true
uci set dhcp.wan.ignore='1'

uci commit network
uci commit dhcp

# ------------------------------------------------------------------------------
# 4. Stop and Permanently Disable Services at Startup
#    (odhcpd, firewall, dnsmasq, log)
# ------------------------------------------------------------------------------
for svc in odhcpd firewall dnsmasq log; do
    if [ -x "/etc/init.d/$svc" ]; then
        /etc/init.d/$svc stop 2>/dev/null || true
        /etc/init.d/$svc disable 2>/dev/null || true
    fi
done

# ------------------------------------------------------------------------------
# 5. Unlock Maximum Wi-Fi TX Power (30 dBm) & Configure Default AP SSID
# ------------------------------------------------------------------------------
DEFAULT_SSID_SUFFIX=$(echo "$ORIG_MAC_2G" | awk -F: '{print toupper($5$6)}')
[ -z "$DEFAULT_SSID_SUFFIX" ] && DEFAULT_SSID_SUFFIX="AP"

uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='00'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.htmode='HT40'
uci set wireless.radio0.noscan='1'
uci set wireless.radio0.txpower='30'

uci set wireless.default_radio0.disabled='0'
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.mode='ap'
uci set wireless.default_radio0.ssid="ZTE_${DEFAULT_SSID_SUFFIX}"
uci set wireless.default_radio0.encryption='none'

uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='00'
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.htmode='VHT80'
uci set wireless.radio1.txpower='30'

uci set wireless.default_radio1.disabled='0'
uci set wireless.default_radio1.network='lan'
uci set wireless.default_radio1.mode='ap'
uci set wireless.default_radio1.ssid="ZTE_${DEFAULT_SSID_SUFFIX}_5G"
uci set wireless.default_radio1.encryption='none'

uci commit wireless

exit 0
EOF
chmod +x ./files/etc/uci-defaults/99-yemen-ap-custom

# 5.4 Create Quick Setup Web Interface (/www/cgi-bin/quick)
cat > ./files/www/cgi-bin/quick << 'EOF'
#!/bin/sh
echo "Content-type: text/html; charset=utf-8"
echo ""

urldecode() {
    echo -e "$(echo "$1" | sed 's/+/ /g;s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

MSG=""
if [ "$REQUEST_METHOD" = "POST" ]; then
    read -r POST_DATA
    NEW_IP=$(urldecode "$(echo "$POST_DATA" | sed -n 's/.*ipaddr=\([^&]*\).*/\1/p')")
    NEW_SSID2=$(urldecode "$(echo "$POST_DATA" | sed -n 's/.*ssid2=\([^&]*\).*/\1/p')")
    NEW_SSID5=$(urldecode "$(echo "$POST_DATA" | sed -n 's/.*ssid5=\([^&]*\).*/\1/p')")
    NEW_KEY=$(urldecode "$(echo "$POST_DATA" | sed -n 's/.*wpakey=\([^&]*\).*/\1/p')")
    NEW_TX=$(urldecode "$(echo "$POST_DATA" | sed -n 's/.*txpower=\([^&]*\).*/\1/p')")

    if [ -n "$NEW_IP" ]; then
        uci set network.lan.ipaddr="$NEW_IP"
    fi
    if [ -n "$NEW_SSID2" ]; then
        uci set wireless.default_radio0.ssid="$NEW_SSID2"
    fi
    if [ -n "$NEW_SSID5" ]; then
        uci set wireless.default_radio1.ssid="$NEW_SSID5"
    fi
    if [ -n "$NEW_TX" ]; then
        uci set wireless.radio0.txpower="$NEW_TX"
        uci set wireless.radio1.txpower="$NEW_TX"
    fi
    if [ -n "$NEW_KEY" ]; then
        uci set wireless.default_radio0.encryption='psk2'
        uci set wireless.default_radio0.key="$NEW_KEY"
        uci set wireless.default_radio1.encryption='psk2'
        uci set wireless.default_radio1.key="$NEW_KEY"
    else
        uci set wireless.default_radio0.encryption='none'
        uci delete wireless.default_radio0.key 2>/dev/null || true
        uci set wireless.default_radio1.encryption='none'
        uci delete wireless.default_radio1.key 2>/dev/null || true
    fi

    uci commit network
    uci commit wireless
    (sleep 1; /etc/init.d/network reload; wifi reload) >/dev/null 2>&1 &
    MSG="<div style='background:#d1fae5;color:#065f46;padding:12px;border-radius:6px;margin-bottom:16px;'><b>Saved!</b> Wireless and IP settings are being applied.</div>"
fi

CUR_IP=$(uci -q get network.lan.ipaddr)
CUR_MAC=$(uci -q get network.lan.macaddr || cat /sys/class/net/br-lan/address 2>/dev/null)
CUR_SSID2=$(uci -q get wireless.default_radio0.ssid)
CUR_SSID5=$(uci -q get wireless.default_radio1.ssid)
CUR_KEY=$(uci -q get wireless.default_radio0.key)
CUR_TX=$(uci -q get wireless.radio0.txpower || echo "30")

cat << HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ZTE E8820V2 - Quick AP Setup</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f3f4f6; margin: 0; padding: 20px; color: #1f2937; }
  .card { max-width: 480px; margin: 20px auto; background: #fff; border-radius: 10px; box-shadow: 0 4px 12px rgba(0,0,0,0.08); padding: 24px; }
  h2 { margin-top: 0; color: #111827; border-bottom: 2px solid #e5e7eb; padding-bottom: 10px; }
  .meta { background: #f9fafb; padding: 10px 12px; border-radius: 6px; font-size: 13px; margin-bottom: 16px; border: 1px solid #e5e7eb; }
  label { display: block; font-weight: 600; margin: 12px 0 4px; font-size: 14px; }
  input, select { width: 100%; padding: 10px; border: 1px solid #d1d5db; border-radius: 6px; box-sizing: border-box; font-size: 14px; }
  button { width: 100%; margin-top: 20px; padding: 12px; background: #2563eb; color: #fff; border: none; border-radius: 6px; font-size: 15px; font-weight: 600; cursor: pointer; }
  button:hover { background: #1d4ed8; }
  .links { margin-top: 16px; text-align: center; font-size: 13px; }
  .links a { color: #2563eb; text-decoration: none; }
</style>
</head>
<body>
<div class="card">
  <h2>ZTE E8820V2 Quick Setup</h2>
  $MSG
  <div class="meta">
    <b>Original Sticker MAC:</b> ${CUR_MAC} &nbsp;|&nbsp; <b>Mode:</b> Pure Bridge AP (DHCP Off)
  </div>
  <form method="POST" action="/cgi-bin/quick">
    <label>Router LAN IP Address</label>
    <input type="text" name="ipaddr" value="${CUR_IP}" required>

    <label>2.4GHz Wi-Fi Name (SSID)</label>
    <input type="text" name="ssid2" value="${CUR_SSID2}" required>

    <label>5GHz Wi-Fi Name (SSID)</label>
    <input type="text" name="ssid5" value="${CUR_SSID5}" required>

    <label>Wi-Fi Password (leave empty for Open / Hotspot without password)</label>
    <input type="text" name="wpakey" value="${CUR_KEY}" placeholder="Open Network (No Password)">

    <label>Wi-Fi TX Power (dBm)</label>
    <select name="txpower">
      <option value="30" $( [ "$CUR_TX" = "30" ] && echo "selected" )>30 dBm (1000 mW - Maximum Yemen)</option>
      <option value="27" $( [ "$CUR_TX" = "27" ] && echo "selected" )>27 dBm (500 mW - High)</option>
      <option value="23" $( [ "$CUR_TX" = "23" ] && echo "selected" )>23 dBm (200 mW - Medium)</option>
      <option value="20" $( [ "$CUR_TX" = "20" ] && echo "selected" )>20 dBm (100 mW - Standard)</option>
    </select>

    <button type="submit">Save & Apply Settings</button>
  </form>
  <div class="links">
    <a href="/cgi-bin/luci">Go to Full OpenWrt LuCI Settings &rarr;</a>
  </div>
</div>
</body>
</html>
HTML
EOF
chmod +x ./files/www/cgi-bin/quick

if [ "$IN_GITHUB_ACTIONS" -eq 0 ]; then
    echo "=== [6/7] Updating Feeds & Writing Clean English AP .config ==="
    ./scripts/feeds update -a
    ./scripts/feeds install -a

    cat > ./.config << 'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_zte_e8820v2=y

# Web UI (English Only - No Chinese translation packages)
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-theme-bootstrap=y
# CONFIG_PACKAGE_luci-i18n-base-zh-cn is not set

# Wireless & USB Drivers + iw tool for antenna_gain zeroing
CONFIG_PACKAGE_kmod-mt7603=y
CONFIG_PACKAGE_kmod-mt76x2=y
CONFIG_PACKAGE_kmod-usb3=y
CONFIG_PACKAGE_kmod-usb-ledtrig-usbport=y
CONFIG_PACKAGE_wpad-basic-wolfssl=y
CONFIG_PACKAGE_iw=y
CONFIG_PACKAGE_iwinfo=y

# Exclude DHCPv6 daemon from image
# CONFIG_PACKAGE_odhcpd-ipv6only is not set
# CONFIG_PACKAGE_odhcpd is not set
EOF

    make defconfig

    echo "=== [7/7] Downloading Sources & Compiling Firmware ==="
    make download -j8
    make -j"$(nproc)" V=s

    echo "=============================================================================="
    echo "BUILD COMPLETE!"
    echo "Your ready-to-flash firmware file is located at:"
    echo "${OPENWRT_DIR}/bin/targets/ramips/mt7621/openwrt-ramips-mt7621-zte_e8820v2-squashfs-sysupgrade.bin"
    echo "=============================================================================="
else
    echo ">>> Patching & Embedded Files Setup Complete for GitHub Actions!"
fi
