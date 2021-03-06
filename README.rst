zre
===

ZRE protocol implementation https://rfc.zeromq.org/spec:36/ZRE/

Peer-to-peer local area networking with reliable group messaging
and automatic peer discovery.

Usage
-----

Dependencies::

        zeromq4

Clone and test::

        git clone https://git.48.io/zre/
        cd zre
        stack build
        stack exec zre
        # in another terminal or networked computer
        stack exec zre
        # optionally install zre binaries
        stack install

Two zre peers should find each other and be able to send message between each other.
Firewall needs to allow traffic on UDP port 5670 and TCP port range 41000-41100.
Application picks random port from this range and advertises it to network.

Applications
------------

Few applications are provided to get you started:

 - zre - interact and dump events
 - zrecat <group> - cat messages for group

These can be installed locally with `stack install` command.

Try running multiple copies of `zre` and `zrecat` on
the same computer or computers on the local network::

        zre
        # another terminal
        zrecat test
        # now in original terminal you can join testgroup with
        > /join test
        # or send messages to it
        > /shout test msg

Send uptime periodically to uptime group::

        ( while true; do uptime; sleep 1; done ) | zrecat uptime


Cat file to group::

        cat /etc/os-release | zrecat test

Interact manually::

        zre
        # in zre shell following commands are supported:
        > /join time
        > /shout time test!
        > /leave time
        > /join uptime
        > /whisper <uuid> message

ZGossip
-------

Implementation of gossip protocol is included in form of key value TTL server.
This allows connecting peers from different networks (or subnets) not reachable via multicast
beacon. This service requires TCP port 31337 and can be started with `zgossip_server` binary.

Run server::

  zgossip_server

Pass gossip endpoint to apps with::

  zre -g <gossip_ip>:31337

Configuration
-------------

ZRE applications using `runZre` will automatically try to load configuration
file if `ZRECFG` environment variable points to it. See `zre.conf` for configuration
example::

  ZRECFG=./zre.conf zrecat test

To be able to use one config for multiple apps and still be able to distinguish between
them you can also set `ZRENAME` environment variable which overrides name
from config or default config if `ZRECFG` is not used::

  ZRENAME=zrenode1 zrecat test

Demos
-----

* https://asciinema.org/a/106340
