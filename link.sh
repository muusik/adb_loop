# shellcheck shell=sh
# shellcheck disable=SC2034  # the link_* variables are read by pull.sh
# link.sh: what the link to the phone is, in words: the Wi-Fi it is on (its generation, the band and channel, the access
# point's name, the signal, the rate the phone sends at), whether the screen is off and Wi-Fi's power save with it,
# battery saver, a VPN on the phone and which way adb goes. Sourced by pull.sh, which shows it while a pull runs.
#
# One adb call of about half a second (cmd wifi status, dumpsys deviceidle, settings, ip); not dumpsys wifi, which on a
# phone with a long connection history prints megabytes and took over a minute. ADB_LOOP_LINK=0 asks nothing.
#
# What slows a pull, measured on a Moto Z2 over wireless adb (2026-11-11): the screen off, ~7 → ~1 MB/s on the same
# 5 GHz access point, since Android turns on Wi-Fi's power save with it ("suspend optimizations"); 2.4 GHz with a weak
# signal, ~1 MB/s with the screen on.

# the phone's side, as lines; the WifiInfo line is Android's own (cmd wifi from Android 11, dumpsys wifi before)
# shellcheck disable=SC2016  # expanded on the phone
link_probe_cmd='cmd wifi status </dev/null 2>/dev/null | grep -m1 "WifiInfo:" || dumpsys wifi </dev/null 2>/dev/null | grep -m1 "mWifiInfo"
echo "screen: $(dumpsys deviceidle </dev/null 2>/dev/null | grep -m1 -o "mScreenOn=[a-z]*")"
echo "saver: $(settings get global low_power </dev/null 2>/dev/null)"
echo "suspendopt: $(settings get global wifi_suspend_optimizations_enabled </dev/null 2>/dev/null)"
echo "vpn: $(ip -o -4 addr 2>/dev/null | grep -m1 -oE "(tun|ppp|wg|ipsec)[0-9]+ +inet [0-9.]+")"
echo "vpnapp: $(dumpsys connectivity </dev/null 2>/dev/null | grep -m1 -oE "VPN:[A-Za-z0-9_.]+")"'

link_probe() {
  [ "${ADB_LOOP_LINK:-1}" != 0 ] || return 0
  case "${ANDROID_SERIAL:-}" in emulator-*) return 0 ;; esac
  timeout 10 adb exec-out "$link_probe_cmd" 2>/dev/null | tr -d '\r'
}

# sets the link_* variables from link_probe's text
link_read() {
  link_info=$(printf '%s\n' "$1" | grep -m1 -E 'WifiInfo')
  link_ssid=$(printf '%s' "$link_info" | sed -n 's/^[^"]*SSID: "\([^"]*\)".*/\1/p')
  link_bssid=$(printf '%s' "$link_info" | sed -n 's/.*BSSID: \([0-9a-f:]*\).*/\1/p')
  link_ip=$(printf '%s' "$link_info" | sed -n 's|.*IP: /\([0-9.]*\).*|\1|p')
  link_std=$(printf '%s' "$link_info" | sed -n 's/.*Wi-Fi standard: \([^,]*\),.*/\1/p')
  link_rssi=$(printf '%s' "$link_info" | sed -n 's/.*RSSI: \(-\{0,1\}[0-9]*\),.*/\1/p')
  link_tx=$(printf '%s' "$link_info" | sed -n 's/.*, Tx Link speed: \(-\{0,1\}[0-9]*\)Mbps.*/\1/p')
  [ -n "$link_tx" ] || link_tx=$(printf '%s' "$link_info" | sed -n 's/.*, Link speed: \(-\{0,1\}[0-9]*\)Mbps.*/\1/p')
  link_txmax=$(printf '%s' "$link_info" | sed -n 's/.*Max Supported Tx Link speed: \(-\{0,1\}[0-9]*\)Mbps.*/\1/p')
  link_freq=$(printf '%s' "$link_info" | sed -n 's/.*Frequency: \(-\{0,1\}[0-9]*\)MHz.*/\1/p')
  case "$link_info" in
    *"Supplicant state: COMPLETED"*) link_wifi=yes ;;
    "") link_wifi= ;;
    *) link_wifi=no ;;
  esac
  case "$1" in
    *"mScreenOn=true"*) link_screen=on ;;
    *"mScreenOn=false"*) link_screen=off ;;
    *) link_screen= ;;
  esac
  link_saver=$(printf '%s\n' "$1" | sed -n 's/^saver: //p')
  link_suspend=$(printf '%s\n' "$1" | sed -n 's/^suspendopt: //p')
  link_vpn_if=$(printf '%s\n' "$1" | sed -n 's/^vpn: \([a-z]*[0-9]*\) .*/\1/p')
  link_vpn_ip=$(printf '%s\n' "$1" | sed -n 's/^vpn: .* inet \([0-9.]*\)$/\1/p')
  # com.tailscale.ipn → tailscale
  link_vpn_app=$(printf '%s\n' "$1" | sed -n 's/^vpnapp: VPN:[a-z]*\.\([A-Za-z0-9_]*\).*/\1/p')
  [ -z "$link_vpn_if" ] || [ -n "$link_vpn_app" ] || link_vpn_app=$link_vpn_if
  # Wi-Fi's power save follows the screen unless the setting turns it off (unset is on)
  link_powersave=
  if [ "$link_screen" = off ] && [ "$link_suspend" != 0 ]; then link_powersave=on
  elif [ -n "$link_screen" ]; then link_powersave=off; fi
  link_derive
}

# the names people know: Wi-Fi 4/5/6/7 (802.11n/ac/ax/be), the band, its channel, the signal in a word, adb's way
link_derive() {
  case "$link_std" in
    11be) link_gen="Wi-Fi 7" ;;
    11ax) if [ "${link_freq:-0}" -ge 5925 ]; then link_gen="Wi-Fi 6E"; else link_gen="Wi-Fi 6"; fi ;;
    11ac) link_gen="Wi-Fi 5" ;;
    11n) link_gen="Wi-Fi 4" ;;
    11ad) link_gen="WiGig" ;;
    "") link_gen= ;;
    *) link_gen="older Wi-Fi" ;;
  esac
  link_band=; link_channel=
  f=${link_freq:-0}
  if [ "$f" -ge 2400 ] && [ "$f" -lt 2500 ]; then
    link_band="2.4 GHz"
    if [ "$f" -eq 2484 ]; then link_channel=14; else link_channel=$(((f - 2407) / 5)); fi
  elif [ "$f" -ge 4900 ] && [ "$f" -lt 5925 ]; then
    link_band="5 GHz"; link_channel=$(((f - 5000) / 5))
  elif [ "$f" -ge 5925 ] && [ "$f" -lt 7200 ]; then
    link_band="6 GHz"; link_channel=$(((f - 5950) / 5))
  fi
  link_signal=
  if [ -n "$link_rssi" ] && [ "$link_rssi" -lt 0 ] && [ "$link_rssi" -gt -127 ]; then
    if [ "$link_rssi" -ge -55 ]; then link_signal=strong
    elif [ "$link_rssi" -ge -67 ]; then link_signal=good
    elif [ "$link_rssi" -ge -75 ]; then link_signal=fair
    else link_signal=weak; fi
  fi
  link_route=$(link_route)
}

# which way adb reaches the phone: over its Wi-Fi address (the LAN), its VPN address, USB, or the emulator
link_route() {
  serial=${ANDROID_SERIAL:-$(timeout 5 adb get-serialno 2>/dev/null)}
  case "$serial" in
    ""|unknown) echo "unknown" ;;
    emulator-*) echo "emulator" ;;
    *:*)
      host=${serial%:*}
      addr=$host
      case "$host" in *[!0-9.]*) addr=$(getent hosts "$host" 2>/dev/null | awk '{ print $1; exit }') ;; esac
      if [ -n "$link_vpn_ip" ] && [ "$addr" = "$link_vpn_ip" ]; then echo "VPN"
      elif [ -n "$link_ip" ] && [ "$addr" = "$link_ip" ]; then echo "LAN"
      else echo "network"; fi ;;
    *) echo "USB" ;;
  esac
}

# one line: "Wi-Fi 5, 5 GHz ch 116, wepiku, signal good (-68 dBm), 130 of 433 Mbit/s | screen on | VPN tailscale | adb over LAN"
link_summary() {
  if [ "$link_route" = emulator ]; then echo "the emulator"; return; fi
  if [ "$link_wifi" = yes ]; then
    s="${link_gen:-Wi-Fi}"
    [ -z "$link_band" ] || s="$s, $link_band ch $link_channel"
    s="$s, ${link_ssid:-hidden network}"
    [ -z "$link_signal" ] || s="$s, signal $link_signal ($link_rssi dBm)"
    if [ "${link_tx:--1}" -gt 0 ]; then
      if [ "${link_txmax:--1}" -gt 0 ]; then s="$s, $link_tx of $link_txmax Mbit/s"; else s="$s, $link_tx Mbit/s"; fi
    fi
  elif [ "$link_wifi" = no ]; then s="Wi-Fi not connected"
  else s="Wi-Fi unknown"; fi
  if [ "$link_powersave" = on ]; then s="$s | screen off: power save"
  elif [ -n "$link_screen" ]; then s="$s | screen $link_screen"; fi
  [ "$link_saver" != 1 ] || s="$s | battery saver"
  [ -z "$link_vpn_app" ] || s="$s | VPN $link_vpn_app"
  [ "$link_route" = unknown ] || s="$s | adb over $link_route"
  echo "$s"
}

# what in the link slows a pull, one hint a line; nothing when nothing does
link_hints() {
  [ "$link_route" != USB ] && [ "$link_route" != emulator ] || return 0
  [ "$link_powersave" != on ] ||
    echo "the screen is off, so Wi-Fi saves power and a pull runs several times slower: turn the screen on"
  [ "$link_saver" != 1 ] || echo "battery saver is on"
  [ "$link_band" != "2.4 GHz" ] || echo "the phone is on 2.4 GHz, several times slower than 5 GHz"
  [ "$link_signal" != weak ] || echo "the signal is weak ($link_rssi dBm)"
  [ "$link_route" != VPN ] || echo "adb goes over the VPN, not the LAN"
}
