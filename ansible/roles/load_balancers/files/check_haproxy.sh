#!/bin/sh

# Allows keepalived to determine if HAProxy is up and listening on 6443.
# Intent: Exit 0 = healthy. Exit w/ non-zero = keepalived releases the VIP.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

pgrep -x haproxy > /dev/null || exit 1
test "$(ss -Hlnt 'sport = :6443')"
