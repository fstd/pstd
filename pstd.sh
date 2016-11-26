#!/bin/sh
# Wrapper around wget(1) for convenient pasting to pstd pastebins

# If -x is given as the *first* argument, enable shell tracing
if [ "x$1" = "x-x" ]; then shift; set -x; fi

prgnam="$(basename "$0")"
version='0.0.2'


Usage() # Print usage statement and exit
{
	printf 'Usage %s [-h] [-s <pastesite>] [<file>]\n' "$prgnam" >&2
	printf 'or    %s [-h] [-s <pastesite>] -d <paste_id>\n' "$prgnam" >&2
	printf '  If <file> is absent or `-`, we paste stdin.\n' >&2
	printf '  If -d <paste_id> is given, *down*load the respective\n' >&2
	printf '    paste instead and output it on stdout\n' >&2
	printf '  The default paste site is `%s`.\n\n' "$site" >&2
	printf 'v%s, 2015, Timo Buhrmester\n' "$version" >&2
	exit 1
}

Bomb() # Complain loudly and exit
{
	printf '%s: ERROR: %s\n' "$prgnam" "$1" >&2
	exit 1
}

MkKey()
{
	tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16
}
# Check if wget is present, abort if not
which wget >/dev/null || Bomb "We need wget"

# The default paste site to use.  When pstd_server.pl arranges for this script
# to be available as paste "0", this variable is automatically rewritten to
# whatever argument to -H was supplied, or else to what hostname(1) said.
site='127.0.0.1:8080'


# We'll need these two tempfiles later and arrange for them to be rm'ed on exit
tmpin="$(mktemp /tmp/paste.XXXXXXXX)"
tmpout="$(mktemp /tmp/paste.XXXXXXXX)"
trap "rm -f '$tmpin' '$tmpout'" EXIT


dl=false
key=
# Parse command line arguments
while getopts "s:cdh" i; do
	case "$i" in
	s) site="$OPTARG" ;;
	d) dl=true ;;
	c) key="$(MkKey)" ;;
	*) Usage ;;
	esac
done
shift $((OPTIND-1))

if $dl; then
	[ $# -gt 0 ] || Bomb "No paste identifier given"
	wget -q -O - "http://$site/$1" >"$tmpout" || Bomb "wget failed :O"

else
	# Warn about superfluous argumnents
	[ $# -gt 1 ] && printf '%s: Ignoring all but the first argument\n' "$prgnam" >&2

	# If a file is given on the command line, paste that. Else, paste standard input.
	if [ $# -gt 0 -a "$1" != '-' ]; then
		[ -r "$1" ] || Bomb "Cannot read '$1'"

		in="$1"
	else
		cat >"$tmpin"
		in="$tmpin"
	fi

	# Paste what $in refers to
	wget -q -O - --post-file "$in" "http://$site/$key" >"$tmpout" || Bomb "wget failed :O"
fi

# And output the returned link (or error)
cat "$tmpout"

exit 0

#2015, Timo Buhrmester
