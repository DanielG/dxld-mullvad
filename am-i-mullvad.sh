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

warning() {
        echo>&2
        echo "$1">&2
}


MULLVAD_ACCOUNT=
if [ -r "$HOME"/.mullvad-account ]; then
        MULLVAD_ACCOUNT="$(cat "$HOME"/.mullvad-account)"
fi

echo -n 'Checking Mullvad...'>&2

# IP Leak check

mullvad_ip4="$( timeout 3 curl -4 -s https://am.i.mullvad.net/json | jq '.mullvad_exit_ip' )"
mullvad_ip6="$( timeout 3 curl -6 -s https://am.i.mullvad.net/json | jq '.mullvad_exit_ip' )"

ip_check () {
        local var msg
        var="$1"; shift
        msg="$1"; shift

        local mullvad_ip
        eval "mullvad_ip=\$$var"
        if [ "$mullvad_ip" = 'false' ]; then
                not_on_mullvad "- $msg Leaking"
                exit 123 #not reached
        elif [ "$mullvad_ip" = '' ]; then
                warning "- $msg check errored"
                return 1
        fi

        return 0
}

ip_check mullvad_ip4 "IPv4"; rv_ip4=$?
ip_check mullvad_ip6 "IPv6"; rv_ip6=$?
if [ $rv_ip4 -ne 0 ] && [ $rv_ip6 -ne 0 ]; then
        not_on_mullvad "- All IP checks errored"
fi

# DNS Leak check

dnsids=

for i in $(seq 0 3); do
    id=$(xxd -p -l16 < /dev/urandom)
    dnsids="$dnsids $id"
    (curl -s "https://$id.dnsleak.am.i.mullvad.net/" > /dev/null 2>&1 || true)&
done

wait

for i in $dnsids; do
    mullvad_dns="$(curl -s --max-time 10 https://am.i.mullvad.net/dnsleak/$id \
        | jq '[ .[] | .mullvad_dns ] | all')"

    if [ "$mullvad_dns" = 'false' ]; then
            not_on_mullvad "- DNS Leaking"
    fi
done

echo 'OK'>&2


if [ -r ~/.mullvad-expiry ]; then
    expiry="$(cat ~/.mullvad-expiry)"

    if which dateutils.ddiff > /dev/null 2>&1; then
        dateutils.ddiff now "$expiry" -f 'Expires in %ddays %Hhours.' >&2
    else
        printf 'Expires on %s\n' "$(date -d "$expiry")" >&2
    fi
fi
