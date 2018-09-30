dxld's mullvad config
=====================

Overview
--------

I use libpam-net to segregate a dedicated system user into a network namespace
which can only talk to the outside world through a wireguard interface.

[`mullvad-wg-netns.sh`](mullvad-wg-netns.sh) implements the provisioning of the
wireguard configs (generating privkey, uploading pubkey to mullvad API etc.). It
also supports bringing up the wireguard interface at boot since `wg-quick` does
not support netns or operating on a pre-existing wg interface.

Setup
-----

First we set up libpam-net:

    $ apt-get install libpam-net
    $ pam-auth-update --enable libpam-net-usernet
    $ addgroup --system usernet
    $ adduser <myuser> usernet

Note: this currently depends on an
[unmerged patch to libpam-net](https://github.com/rd235/libpam-net/pull/1) as
well as the
[unreleased Debian package](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=909908))
for libpam-net, both of these things are currently being worked on.
    
Now whenever `<myuser>` logs in, or a service is started as them, it will be
placed in a netns (cf. ip-netns(8)) corresponding to their username.

Next we provision the wireguard configs:

    $ path/to/mullvad-wg-net.sh provision

This will ask you for your mullvad account number, so keep that ready.

Finally to start the mullvad wireguard interface you should use the following
command:

    $ path/to/mullvad-wg-net.sh init <myuser> mullvad-<regioncode>.conf

Replace `<regioncode>` by whatever mullvad region you want to use, for example
`mullvad-at1.conf`, you can find the full list in `/etc/wireguard/` after
provisioning.

To make this permanent you can simply put it in `/etc/rc.local` or create a
systemd unit or something if you insist.


Security
--------

In order to make sure this whole setup works and to prevent leaks if something
fails I like to check if connectivity is going through mullvad on login. The
mullvad guys provide a convinient servive for this: https://am.i.mullvad.net and
I wrote a convinient shell wrapper for it: [am-i-mullvad.sh](am-i-mullvad.sh).

To use it put it in your `.bash_profile` or simmilar shell startup script:

    $ cat >> .bash_profile << EOF
    sh path/to/am-i-mullvad.sh || exit 1
    EOF

If we're not connected through mullvad it will print an error message and kill
the shell after a short timeout so you can still get access if needed.
