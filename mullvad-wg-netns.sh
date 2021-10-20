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

key="$(cat /etc/wireguard/mullvad-*.conf \
    | sed -rn 's/^PrivateKey *= *([a-zA-Z0-9+/]{43}=) *$/\1/ip;T;q')"

if [ -n "$key" ]; then
        echo "[+] Using existing private key."
else
        echo "[+] Generating new private key."
        key="$(wg genkey)"
fi

mypubkey="$(printf '%s\n' "$key" | wg pubkey)"

echo "[+] Submitting wg public key to Mullvad API."
res="$(curl -sSL https://api.mullvad.net/wg/ \
        -d account="$ACCOUNT" \
        --data-urlencode pubkey="$mypubkey")"
if ! printf '%s\n' "$res" | grep -E '^[0-9a-f:/.,]+$' >/dev/null
then
        die "$res"
fi
myipaddr=$res

echo "[+] Removing old /etc/wireguard/mullvad-*.conf files."
rm /etc/wireguard/mullvad-*.conf || true

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

    if [ -f "$conf" ]; then
            oldpubkey="$(sed -rn 's/^PublicKey *= *([a-zA-Z0-9+/]{43}=) *$/\1/ip' <"$conf")"
            if [ -n "$oldpubkey" ] && [ "$pubkey" != "$oldpubkey" ]; then
                    echo "WARNING: $hostname changed pubkey from '$oldpubkey' to '$pubkey'"
                    continue
            fi
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
if command -v dateutils.ddiff > /dev/null 2>&1; then
    dateutils.ddiff now "$expiry" -f 'Account expires in %ddays %Hhours.' >&2
else
    printf 'Account expires on %s\n' "$(date -d "$expiry")" >&2
fi

echo; echo
echo "Please wait up to 60 seconds for your public key to be added to the servers."
}

init () {
nsname=$1; shift
cfgname=$1; shift
parentns=${parentns:-}
wgifname="wg-$nsname"

# [Note POSIX array trick]
# Ok, this is a nasty POSIX shell trick, we use the _one_ array we have
# access to, the args, aka "$@" to store the -netns option I optionally
# want to pass to `ip` below. Since we're done with cmdline parsing at this
# point that's totally fine, just a bit opaque. Hence this comment.
#
# You're welcome.
if [ -z "$parentns" ]; then
        set --
else
        set -- -netns "$parentns"
fi

# Check for old wg interfaces in (1) current namespace,
if [ -z "$parentns" ] && [ -e /sys/class/net/"$wgifname" ]; then
        ip link del dev "$wgifname"
fi

# (2) parent namespace and
if ip netns exec "$parentns" [ -e /sys/class/net/"$wgifname" ]; then
        ip -netns "$parentns" link del dev "$wgifname"
fi

# (3) target namespace.
if ip netns exec "$nsname" [ -e /sys/class/net/"$wgifname" ]; then
        ip -netns "$nsname" link del dev "$wgifname"
fi

# See [Note POSIX array trick] above.
ip "$@" link add "$wgifname" type wireguard

if ! [ -e /var/run/netns/"$nsname" ]; then
        ip netns add "$nsname"
fi

# Move the wireguard interface to the target namespace. See [Note POSIX
# array trick] above.
ip "$@" link set "$wgifname" netns "$nsname"

# shellcheck disable=SC2002 # come on, < makes the pipeline read like shit
cat /etc/wireguard/"$cfgname" \
        | grep -vi '^Address\|^DNS' \
        | ip netns exec "$nsname"  wg setconf "$wgifname" /dev/stdin

addrs="$(sed -rn 's/^Address *= *([0-9a-fA-F:/.,]+) *$/\1/ip' < /etc/wireguard/"$cfgname")"

ip -netns "$nsname" link set dev lo up
ip -netns "$nsname" link set dev "$wgifname" up

(
    IFS=','
    for addr in $addrs; do
    	ip -netns "$nsname" addr add dev "$wgifname" "$addr"
    done
)

ip -netns "$nsname" route add default dev "$wgifname"
ip -netns "$nsname" -6 route add default dev "$wgifname"

} # end init()


set -e

cmd="${1:-provision}"; shift
"$cmd" "$@" # run $cmd with rest of args
