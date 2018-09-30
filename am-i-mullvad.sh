#!/bin/sh

not_on_mullvad() {
    echo>&2
    echo>&2
    echo "!!! NOT ON MULLVAD !!!" >&2
    echo "$1">&2
    echo>&2
    sleep 3
    exit 123
}

MULLVAD_ACCOUNT=
if [ -r "$HOME"/.mullvad-account ]; then
        MULLVAD_ACCOUNT="$(cat "$HOME"/.mullvad-account)"
fi

echo -n 'Checking Mullvad...'

# IP Leak check
mullvad_ip4="$(curl -4 -s https://am.i.mullvad.net/json | jq '.mullvad_exit_ip')"
mullvad_ip6="$(curl -6 -s https://am.i.mullvad.net/json | jq '.mullvad_exit_ip')"

[ "$mullvad_ip4" = 'true' ] || not_on_mullvad "- IPv4 Leaking"
[ "$mullvad_ip6" = 'true' ] || not_on_mullvad "- IPv6 Leaking"

# DNS Leak check

dnsids=

for i in $(seq 0 5); do
    id=$(xxd -p -l16 < /dev/urandom)
    dnsids="$dnsids $id"
    curl -s "https://$id.dnsleak.am.i.mullvad.net/" > /dev/null 2>&1 || true
    sleep 0.1
done

for i in $dnsids; do
    mullvad_dns="$(curl -s --max-time 10 https://am.i.mullvad.net/dnsleak/$id \
        | jq '[ .[] | .mullvad_dns ] | all')"

    if [ "$mullvad_dns" = 'false' ]; then
            not_on_mullvad "- DNS Leaking"
    fi
done

echo 'OK'


if [ -n "$MULLVAD_ACCOUNT" ]; then
    expiry="$(curl -s -X POST https://api.mullvad.net/rpc/ \
         -H 'content-type: application/json;' \
         --data '{ "jsonrpc": "2.0"
                 , "method": "get_expiry"
                 , "params": { "account_token": "'"$MULLVAD_ACCOUNT"'" }
                 , "id": 1
                 }' \
    | jq -r '.result')"


    if which dateutils.ddiff > /dev/null 2>&1; then
        dateutils.ddiff now "$expiry" -f 'Expires in %ddays %Hhours.' >&2
    else
        printf 'Expires on %s\n' "$(date -d "$expiry")" >&2
    fi
fi
