#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2018 Daniel Gröber
# Copyright (C) 2016-2018 Jason A. Donenfeld <Jason@zx2c4.com>.
# All Rights Reserved.

# Based on https://mullvad.net/media/files/mullvad-wg.sh but modified to be
# POSIX sh compliant and easier to review. This version also supports using a
# wireguard interface in a network namespace.

die() {
	echo "[-] Error: $1" >&2
	exit 1
}

provision() {
umask 077

ACCOUNT=
if [ -r "$HOME"/.mullvad-account ]; then
        ACCOUNT="$(cat "$HOME"/.mullvad-account)"
fi
if [ -z "$ACCOUNT" ]; then
        printf '[?] Please enter your Mullvad account number: '
        read -r ACCOUNT
fi

echo "[+] Contacting Mullvad API for server locations."

curl -LsS https://api.mullvad.net/public/relays/wireguard/v1/ \
 | jq -r \
   '( .countries[]
      | (.cities[]
        | (.relays[]
          | [.hostname, .public_key, .ipv4_addr_in])
      )
    )
    | flatten
    | join("\t")' \
 | while read -r hostname pubkey ipaddr; do
    code="${hostname%-wireguard}"
    addr="$ipaddr:51820"

    conf="/etc/wireguard/mullvad-${code}.conf"
    if [ -z "$key" ] && [ -f "$conf" ]; then
        key="$(sed -rn 's/^PrivateKey *= *([a-zA-Z0-9+/]{43}=) *$/\1/ip' <$conf)"

	if [ -n "$key" ]; then
                echo "[+] Using existing private key."
        fi
    fi

    if [ -z "$key" ]; then
	    echo "[+] Generating new private key."
	    key="$(wg genkey)"
    fi

    if [ -z "$mypubkey" ]; then
            mypubkey="$(printf '%s\n' "$key" | wg pubkey)"
    fi

    if [ -z "$myipaddr" ]; then
            echo "[+] Contacting Mullvad API."
            res="$(curl -sSL https://api.mullvad.net/wg/ \
                        -d account="$ACCOUNT" \
                        --data-urlencode pubkey="$mypubkey")"
            if ! printf '%s\n' "$res" | grep -E '^[0-9a-f:/.,]+$' >/dev/null
            then
                    die "$res"
            fi
            myipaddr=$res
    fi

    mkdir -p /etc/wireguard/
    rm -f "${conf}.tmp"
    cat > "${conf}.tmp" <<-EOF
		[Interface]
		PrivateKey = $key
		Address = $myipaddr

		[Peer]
		PublicKey = $pubkey
		Endpoint = $addr
		AllowedIPs = 0.0.0.0/0, ::/0
	EOF
    mv "${conf}.tmp" "${conf}"
done


expiry="$(curl -s -X POST https://api.mullvad.net/rpc/ \
     -H 'content-type: application/json;' \
     --data '{ "jsonrpc": "2.0"
             , "method": "get_expiry"
             , "params": { "account_token": "'"$ACCOUNT"'" }
             , "id": 1
             }' \
| jq -r '.result')"

printf '%s\n' "$expiry" > ~/.mullvad-expiry

echo; echo
if which dateutils.ddiff > /dev/null 2>&1; then
    dateutils.ddiff now "$expiry" -f 'Account expires in %ddays %Hhours.' >&2
else
    printf 'Account expires on %s\n' "$(date -d "$expiry")" >&2
fi

echo; echo
echo "Please wait up to 60 seconds for your public key to be added to the servers."
}

init() {
nsname=$1; shift
cfgname=$1; shift
ifname="wg-$nsname"

if [ -e /sys/class/net/"$ifname" ]; then
        ip link del dev "$ifname"
fi

if ip netns exec "$nsname" [ -e /sys/class/net/"$ifname" ]; then
        ip -netns "$nsname" link del dev "$ifname"
fi

ip link add "$ifname" type wireguard
if ! [ -e /var/run/netns/"$nsname" ]; then
        ip netns add "$nsname"
fi

ip link set "$ifname" netns "$nsname"
cat /etc/wireguard/"$cfgname" \
        | grep -vi '^Address\|^DNS' \
        | ip netns exec "$nsname"  wg setconf "$ifname" /dev/stdin

addrs="$(sed -rn 's/^Address *= *([0-9a-fA-F:/.,]+) *$/\1/ip' < /etc/wireguard/"$cfgname")"

ip -netns "$nsname" link set dev lo up
ip -netns "$nsname" link set dev "$ifname" up

(
    IFS=','
    for addr in $addrs; do
    	ip -netns "$nsname" addr add dev "$ifname" "$addr"
    done
)

ip -netns "$nsname" route add default dev "$ifname"
ip -netns "$nsname" -6 route add default dev "$ifname"
}


set -e

cmd="${1:-provision}"; shift
"$cmd" "$@" # run $cmd with rest of args
