#!/bin/sh
# BookFetch – VPN vezérlő Kindle-re (OpenVPN + IPv6-tiltás + kill switch + DNS)
#
# Használat:
#   sh vpn.sh up <fajl.ovpn> <auth.txt>
#   sh vpn.sh down
#   sh vpn.sh status
#
# Kimenet utolsó sora mindig:  "OK ..."  vagy  "HIBA ..."

DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/bin"
ST=/tmp/bookfetch
LOG="$ST/ovpn.log"
PIDF="$ST/ovpn.pid"
CHAIN=BF_KILL
FALLBACK_DNS=1.1.1.1

mkdir -p "$ST"

fail() { echo "HIBA $*"; exit 1; }

is_running() {
    [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null
}

# ---------- IPv6 (különben az otthoni IPv6-cím kiszivárog) ----------
ipv6_off() {
    for ifc in all default wlan0; do
        p=/proc/sys/net/ipv6/conf/$ifc/disable_ipv6
        [ -f "$p" ] || continue
        [ -f "$ST/v6_$ifc" ] || cat "$p" > "$ST/v6_$ifc"
        echo 1 > "$p"
    done
}

ipv6_restore() {
    for ifc in all default wlan0; do
        p=/proc/sys/net/ipv6/conf/$ifc/disable_ipv6
        if [ -f "$ST/v6_$ifc" ]; then
            [ -f "$p" ] && cat "$ST/v6_$ifc" > "$p"
            rm -f "$ST/v6_$ifc"
        fi
    done
}

# ---------- Tűzfal: tun0 válaszok engedése + kill switch ----------
fw_up() {
    server="$1"
    lan="$2"
    rproto="$3"
    rport="$4"
    # A Kindle tűzfala csak a wlan0-n érkező válaszokat engedi – tun0 kell mellé
    iptables -I INPUT -i tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Kill switch: kifelé csak a VPN-alagút, a VPN-szerver és a helyi hálózat
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    iptables -A "$CHAIN" -o lo -j ACCEPT
    iptables -A "$CHAIN" -o tun0 -j ACCEPT
    [ -n "$server" ] && iptables -A "$CHAIN" -d "$server" -j ACCEPT
    # Az alagút saját forgalma a VPN-portra – akkor is, ha az OpenVPN másik
    # szerver-IP-re kapcsolódik újra (remote-random), vagy a napló nem adta meg az IP-t
    [ -n "$rport" ] && iptables -A "$CHAIN" -o wlan0 -p "$rproto" --dport "$rport" -j ACCEPT
    # DHCP (különben órák múlva lejár a wifi címbérlete)
    iptables -A "$CHAIN" -o wlan0 -p udp --dport 67:68 -j ACCEPT
    # DNS a saját feloldóinkhoz wlan0-n is: hogy ha a wifi lealszik és az alagút
    # leesik, az OpenVPN fel tudja oldani a szerver nevét és újracsatlakozzon.
    for d in "$FALLBACK_DNS" 8.8.8.8; do
        iptables -A "$CHAIN" -o wlan0 -d "$d" -p udp --dport 53 -j ACCEPT
        iptables -A "$CHAIN" -o wlan0 -d "$d" -p tcp --dport 53 -j ACCEPT
    done
    [ -n "$lan" ] && iptables -A "$CHAIN" -d "$lan" -j ACCEPT
    iptables -A "$CHAIN" -j DROP
    iptables -I OUTPUT 1 -j "$CHAIN"
}

# ---------- Wifi ébren tartása (a Kindle pár perc tétlenség után kikapcsolja) ----------
wifi_keepawake() {
    # energiatakarékos mód ki a wlan0-n (ha az iwconfig/driver támogatja)
    iwconfig wlan0 power off 2>/dev/null
    for ps in /sys/class/net/wlan0/device/power/control; do
        [ -w "$ps" ] && echo on > "$ps" 2>/dev/null
    done
    # a Kindle energiakezelőjének szólunk, hogy tartsa a wifit (ha elérhető)
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null || true
    lipc-set-prop com.lab126.wifid enable 1 2>/dev/null || true
}

# VPN-kikapcsoláskor visszaállítjuk az energiatakarékos módot, hogy ne fogyjon
# többet az olvasó, mint VPN nélkül.
wifi_restore() {
    iwconfig wlan0 power on 2>/dev/null
    for ps in /sys/class/net/wlan0/device/power/control; do
        [ -w "$ps" ] && echo auto > "$ps" 2>/dev/null
    done
}

fw_down() {
    while iptables -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    iptables -F "$CHAIN" 2>/dev/null
    iptables -X "$CHAIN" 2>/dev/null
    while iptables -D INPUT -i tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
}

# ---------- DNS (különben a router látja, mit keresel) ----------
# A Kindle hálózati démona visszaírhatja a resolv.conf-ot a router DNS-ére,
# amit a kill switch blokkol -> DNS elhal. Ezért zároljuk (chattr +i).
# Megbízható, az alagúton át (0.0.0.0/1 route) elérhető DNS-t használunk.
dns_set() {
    vpn_dns="$1"
    # ha resolv.conf szimbolikus link, előbb feloldjuk valódi fájllá
    if [ -L /etc/resolv.conf ]; then
        # a KÖZVETLEN link-célt mentjük (nem a végső fájlt), hogy pontosan visszaállítható legyen
        tgt=$(readlink /etc/resolv.conf 2>/dev/null)
        rm -f /etc/resolv.conf
        : > /etc/resolv.conf
        [ -n "$tgt" ] && echo "$tgt" > "$ST/resolv.link"
    fi
    [ -f "$ST/resolv.bak" ] || cat /etc/resolv.conf > "$ST/resolv.bak" 2>/dev/null
    chattr -i /etc/resolv.conf 2>/dev/null
    {
        [ -n "$vpn_dns" ] && [ "$vpn_dns" != "$FALLBACK_DNS" ] && printf 'nameserver %s\n' "$vpn_dns"
        printf 'nameserver %s\n' "$FALLBACK_DNS"
        printf 'nameserver %s\n' 8.8.8.8
    } > /etc/resolv.conf
    # zárolás, hogy a rendszer ne írja vissza (ha az fs/chattr támogatja)
    chattr +i /etc/resolv.conf 2>/dev/null
}

dns_restore() {
    chattr -i /etc/resolv.conf 2>/dev/null
    if [ -f "$ST/resolv.link" ]; then
        # eredetileg szimbolikus link volt -> visszaállítjuk a LINKET, hogy a rendszer
        # DNS-démona újra kezelhesse (különben beragad a statikus fájl -> nincs névfeloldás)
        tgt=$(cat "$ST/resolv.link" 2>/dev/null)
        rm -f /etc/resolv.conf
        [ -n "$tgt" ] && ln -s "$tgt" /etc/resolv.conf 2>/dev/null
        rm -f "$ST/resolv.link" "$ST/resolv.bak"
    elif [ -f "$ST/resolv.bak" ]; then
        cat "$ST/resolv.bak" > /etc/resolv.conf 2>/dev/null
        rm -f "$ST/resolv.bak"
    fi
}

# ---------- Fő műveletek ----------
do_down() {
    if [ -f "$PIDF" ]; then
        kill "$(cat "$PIDF")" 2>/dev/null
        i=0
        while is_running && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
        is_running && kill -9 "$(cat "$PIDF")" 2>/dev/null
        rm -f "$PIDF"
    fi
    fw_down
    dns_restore
    ipv6_restore
    wifi_restore
    rm -f "$ST/auth" "$ST/cfg.ovpn"
}

do_up() {
    ovpn="$1"
    auth="$2"
    [ -f "$ovpn" ] || fail "Nem található az .ovpn fájl: $ovpn"
    [ -f "$auth" ] || fail "Nem található az auth.txt"
    [ -x "$BIN/openvpn" ] || chmod +x "$BIN/openvpn" 2>/dev/null

    if is_running; then
        echo "OK $(wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null)"
        exit 0
    fi

    # Esetleges korábbi maradványok eltakarítása
    do_down

    # Windows-sorvégek és OpenVPN 2.6-ban már hibás direktívák kiszűrése
    tr -d '\r' < "$ovpn" | grep -v -E '^[[:space:]]*(keysize|auth-user-pass)' > "$ST/cfg.ovpn"
    tr -d '\r' < "$auth" > "$ST/auth"
    chmod 600 "$ST/auth"

    ipv6_off
    wifi_keepawake
    rm -f "$LOG"

    # --ping/--ping-restart: ha a wifi lealszik és visszajön, az OpenVPN magától
    #   újraépíti az alagutat (nem kell kézzel újracsatlakozni).
    # --persist-tun: a tun0 és a route-ok megmaradnak a reconnect alatt.
    "$BIN/openvpn" --config "$ST/cfg.ovpn" \
        --auth-user-pass "$ST/auth" --auth-nocache \
        --pull-filter ignore "ifconfig-ipv6" \
        --pull-filter ignore "route-ipv6" \
        --ping 10 --ping-restart 60 --persist-tun --persist-key \
        --connect-retry-max 0 \
        --daemon bookfetch-ovpn --log "$LOG" --writepid "$PIDF"

    i=0
    while [ $i -lt 40 ]; do
        if grep -q "Initialization Sequence Completed" "$LOG" 2>/dev/null; then
            break
        fi
        if grep -q -E "AUTH_FAILED|Options error|Exiting due to fatal error" "$LOG" 2>/dev/null; then
            err=$(grep -E "AUTH_FAILED|Options error|fatal error" "$LOG" | tail -n 1 | cut -c21-)
            do_down
            fail "OpenVPN: $err"
        fi
        if [ $i -gt 3 ] && ! is_running; then
            err=$(tail -n 1 "$LOG" 2>/dev/null | cut -c21-)
            do_down
            fail "Az OpenVPN leállt: $err"
        fi
        sleep 1
        i=$((i + 1))
    done
    if [ $i -ge 40 ]; then
        do_down
        fail "Időtúllépés (40 mp) – nincs kapcsolat a VPN-szerverrel"
    fi

    # VPN-szerver címe (ezt az útvonalat az OpenVPN maga veszi fel)
    server=$(grep -o 'net_route_v4_add: [0-9.]*/32 via' "$LOG" | tail -n 1 | awk '{print $2}' | cut -d/ -f1)
    # Helyi hálózat (pl. 10.0.0.0/24) – hogy az SSH a gépről továbbra is menjen
    lan=$(ip route 2>/dev/null | awk '/dev wlan0/ && /scope link/ {print $1; exit}')
    if [ -z "$lan" ]; then
        # tartalék, ha nincs "ip" parancs: route -n (hálózat + maszk)
        lan=$(route -n 2>/dev/null | awk '$8=="wlan0" && $2=="0.0.0.0" && $1!="0.0.0.0" {print $1"/"$3; exit}')
    fi
    # VPN-szerver portja és protokollja a konfigurációból
    rport=$(awk '/^[[:space:]]*remote[[:space:]]/ && $3 != "" {print $3; exit}' "$ST/cfg.ovpn")
    [ -n "$rport" ] || rport=$(awk '/^[[:space:]]*port[[:space:]]/ {print $2; exit}' "$ST/cfg.ovpn")
    [ -n "$rport" ] || rport=1194
    rproto=$(awk '/^[[:space:]]*proto[[:space:]]/ {print $2; exit}' "$ST/cfg.ovpn")
    case "$rproto" in tcp*) rproto=tcp ;; *) rproto=udp ;; esac
    # A VPN által adott DNS
    dns=$(grep -o 'dhcp-option DNS [0-9.]*' "$LOG" | tail -n 1 | awk '{print $3}')
    [ -n "$dns" ] || dns=$FALLBACK_DNS

    fw_up "$server" "$lan" "$rproto" "$rport"
    dns_set "$dns"

    ip=$(wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null)
    [ -n "$ip" ] || ip="(az IP-cím lekérdezése nem sikerült)"
    echo "OK $ip"
}

do_status() {
    if is_running && [ -e /sys/class/net/tun0 ] && grep -q "Initialization Sequence Completed" "$LOG" 2>/dev/null; then
        echo "OK BE $(wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null)"
    else
        echo "OK KI"
    fi
}

# ön-gyógyítás: ha a VPN NEM fut, de maradt beragadt kill switch vagy zárolt/statikus
# resolv.conf egy korábbi (megszakadt) futásból, takarítsuk ki, hogy legyen internet.
do_heal() {
    is_running && return 0
    fw_down 2>/dev/null
    # a resolv.conf feloldása mindenképp (az immutable flag túléli az újraindítást is!)
    chattr -i /etc/resolv.conf 2>/dev/null
    dns_restore
    ipv6_restore 2>/dev/null
    wifi_restore 2>/dev/null
}

case "$1" in
    up)     do_up "$2" "$3" ;;
    down)   do_down; echo "OK" ;;
    heal)   do_heal; echo "OK" ;;
    status) do_status ;;
    *)      fail "Használat: vpn.sh up <ovpn> <auth> | down | heal | status" ;;
esac
