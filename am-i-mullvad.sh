#!/bin/sh

echo -n 'Checking Mullvad...'
am_i="$(curl -s https://am.i.mullvad.net/json | jq '.mullvad_exit_ip')"

if [ "$am_i" != 'true' ]; then
        echo
        echo
        echo "!!! NOT ON MULLVAD !!!" >&2
        echo
        sleep 3
        exit 123
fi
echo 'OK'
