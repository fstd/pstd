#!/bin/sh

set -e

if [ "$1" = "-x" ]; then shift; set -x; fi
prgnam="$(basename "$0")"

Usage() # Print usage statement and exit
{
	printf 'Usage %s [-h] [-s <pastesite>]\n' "$prgnam"
	exit 1
}


Bomb() # Complain loudly and exit
{
	printf '%s: ERROR: %s\n' "$prgnam" "$1" >&2
	exit 1
}

which wget >/dev/null || Bomb "We need wget"

site='127.0.0.1:8080'

while getopts "s:h" i; do
	case "$i" in
	s) site="$OPTARG" ;;
	*) Usage ;;
	esac
done

tmp=$(mktemp /tmp/paste.XXXXXXXX)
tmpout=$(mktemp /tmp/paste.XXXXXXXX)
trap "rm -f '$tmp' '$tmpout'" EXIT

cat >$tmp

if ! wget -q -O - --post-file $tmp "http://$site" >$tmpout; then
	Bomb "wget failed :O"
fi

cat $tmpout

exit 0
