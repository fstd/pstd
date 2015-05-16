#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use IO::Select;
use IO::Socket::INET;
use Getopt::Std;
use POSIX 'strftime';
use Data::Dumper;

my $prgnam = $0 =~ s/^.*\///r;
my $version = '0.0.1';

# These are defaults that can be overridden with command-line switches
my $bindaddr = "127.0.0.1"; # -l
my $bindport = 8080; # -l, On Linux, authbind(1) can be used to listen on low ports without having to run as root
my $pastedir = 'pastes'; # -d
my $manpath = 'pstd.1'; # -m
my $cltscript = 'pstd.sh'; # -c, we need to know this because we distribute this as (synthetical) paste "0"
my $verbose = 0; # -v
my $myhost = ''; # If not overridden by -H, we figure it out by running hostname(1)

# The largest single paste we'll accept, in bytes
my $max_buflen = 256*1024;

# Paste-ID alphabet and the shortest length of IDs we'll hand out
my @idalpha = ("A".."Z", "a".."z", "0".."9");
my $minidlen = 2;

# Client read buffers and -state
my %readbuf;
my %datalen;

# getopts
my %opts;

my $year = '2015';
my $author = 'Timo Buhrmester';

sub now { return strftime('%Y-%m-%d %H:%M:%S', localtime); }
sub W { say STDERR "$prgnam: ".now.": ".($_[0] =~ s/[\r\n]/\$/grm); }
sub E { W "ERROR: $_[0]"; exit 1; }
sub D { W $_[0] if $verbose; }

sub Usage
{
	say STDERR "Usage: $prgnam [-hv] [-l [addr:]port] [-H <myhost>] [-d <path>] [-m <path>]";
	say STDERR "  -h: Show this usage statement";
	say STDERR "  -V: Print version on stdout";
	say STDERR "  -v: Be more verbose";
	say STDERR "  -l [addr:]port: Listen on port and optionally bind to address";
	say STDERR "  -m path: Path to manual (pstd.1)";
	say STDERR "  -d path: Path to paste directory";
	say STDERR "  -c path: Path to pstd.sh client-script (becomes a paste referred to by the manpage)";
	say STDERR "  -H FQDN: Our hostname";
	say STDERR "v$version, written by $author, $year";
	exit 1;
}


# Generate an unused paste ID
sub gen_id
{
	# We're trying 10 times to obtain an unused 2-letter ID,
	# then 10 times to obtain an unused 3-letter ID, and so forth
	# We also remember when we start needing to use something longer,
	# and avoid searching the apparently full-ish shorter ID-space then.
	foreach my $idlen ($minidlen..32) {
		foreach my $attempt (1..10) {
			my $id = '';
			$id .= $idalpha[rand @idalpha] for 1..$idlen;

			if (! -e "$pastedir/$id") {
				D "Generated ID $id";
				if ($idlen > $minidlen) {
					$minidlen = $idlen;
				}
				return $id;
			}
		}
	}

	return '';
}


# Read and return the man page
sub manpage
{
	my $fhnd;
	if (!open $fhnd, '<', $manpath) {
		W "Failed to open $manpath: $!";
		return "ERROR: Manpage not found\n";
	}

	my @lines = <$fhnd>;
	my $man = join '', @lines;
	close $fhnd;

	return $man =~ s/MYHOST/$myhost/rg;
}


# Deal with a client (most likely a web browser) requesting a paste
# Takes socket and ID as parmeters, returns what we're going to
# pass back to the client (i.e. ideally, the actual paste)
sub process_GET
{
	my ($clt, $who, $id) = @_;

	if (! -e "$pastedir/$id") {
		W "$who: Requested nonexistant paste $id";
		return 'No such paste.';
	}

	my $fhnd;
	if (!open $fhnd, '<', "$pastedir/$id") {
		W "$who: Failed to open $pastedir/$id: $!";
		return 'GET Error 1';
	}

	my @lines = <$fhnd>;
	my $paste = join '', @lines;
	close $fhnd;

	D "$who: Got $id";

	return $paste;
}


# Deal with something (most likely paste.sh or wget) submitting
# a paste.  We don't support much HTTP, so this may not work
# with arbitrary clients. (We require a Content-Length header,
# and no transfer-encoding.  wget --post-file http://.. is okay.
sub process_POST
{
	my ($clt, $who) = @_;

	my $id = gen_id;

	my $paste = $readbuf{$who} =~ s/^(.*?)\r\n\r\n//rs;

	if ($paste eq '') {
		W "$who: Empty paste";
		return "POST Error 0\n";
	}

	my $fhnd;
	if (!open $fhnd, '>', "$pastedir/$id") {
		W "$who: Failed to open $pastedir/$id for writing: $!";
		return "POST Error 1\n";
	}

	print $fhnd $paste;
	close $fhnd;

	D "$who: Pasted $id";

	return "http://$myhost/$id\n";
}


# This is called once we have a complete header (for a GET)
# or a complete request (for a POST), it dispatches to
# process_GET and process_POST
sub process_dispatch
{
	my ($clt, $who) = @_;

	my $resp;

	D "$who: Processing '$readbuf{$who}'";

	if ($readbuf{$who} =~ /^POST \//) {
		$resp=process_POST($clt, $who);
	} elsif ($readbuf{$who} =~ /^GET \/([a-zA-Z0-9]+)\b/) {
		$resp=process_GET($clt, $who, $1);
	} elsif ($readbuf{$who} =~ /^GET \/ /) {
		$resp=manpage;
	} else {
		W "$who: Request not understood";
		$resp = "ERROR: Request not understood\n";
	}

	return $resp;
}


# Read some more data for the given client and call process_dispatch
# on it once we have enough. Bail out if we get too much
# Return 0 to drop the client, 1 to keep going
sub handle_clt
{
	my ($clt, $who) = @_;

	D "$who: Handling";

	my $data = '';
	$clt->recv($data, 1024); # XXX can this fail?!

	# I suppose empty data means EOF, but not quite sure. XXX
	if ($data eq '') {
		W "$who: Empty read";
		respond($clt, $who, "ERROR: You what?\n");
		return 0;
	}

	# some early sanity check, this assumes the first couple bytes come in in one chunk, though.
	if (!length $readbuf{$who}) {
		if ($data =~ /^POST \//) {
			$datalen{$who} = -1; #don't know yet
		} elsif ($data =~ /^GET \/(?:[a-zA-Z0-9]+)? HTTP/) {
			$datalen{$who} = 0; #don't care
		} else {
			W "$who: Bad first data chunk '$data'";
			respond($clt, $who, "ERROR: Request not understood\n");
			return 0;
		}
	}

	$readbuf{$who} .= $data;

	my $buflen = length $readbuf{$who};
	if ($buflen > $max_buflen) {
		W "$who: Too much data ($buflen/$max_buflen)";
		respond($clt, $who, "ERROR: Too much data\n");
		return 0;
	}

	# $datalen{$who} contains how many bytes we're expecting to receive
	# from $who.  If it is zero, then we read until we have a complete
	# HTTP-header (i.e. till the first \r\n\r\n).  If it is -1, then
	# this is a POST, and we haven't seen the Content-Length header yet.

	if ($datalen{$who} == -1) {
		# POST, see if we have a header yet...
		my $hdr = $readbuf{$who} =~ s/\r\n\r\n.*$//r;
		if ($hdr) {
			#... and extract the Content-Length; bail if none
			my $match = $hdr =~ /Content-Length: ([0-9]+)/;
			if ($match and !$1) {
				W "$who: No Content-Length in header";
				respond($clt, $who, "ERROR: Need Content-Length Header\n");
				return 0;
			}
			$datalen{$who} = $1 + 4 + length $hdr;
			D "$who: Expecting $datalen{$who} bytes in total";

			# Also complain if we happen to see an unsupported TE
			$match = $hdr =~ /Transfer-Encoding: ([a-zA-Z0-9_-]+)/;
			if ($match and $1) {
				if ($1 ne 'Identity' and $1 ne 'None') {
					W "$who: Bad TE '$1'";
					respond($clt, $who, "ERROR: Bad Transfer-Encoding (use Identity)\n");
					return 0;
				}
			}
		}
	} elsif ($datalen{$who} == 0) {
		# a GET, process_dispatch once we have a complete request
		if ($readbuf{$who} =~ /\r\n\r\n/) {
			respond($clt, $who, process_dispatch($clt, $who));
			return 0;
		}
	}

	# datalen may have changed at this point (in the above conditional)

	if ($datalen{$who} > 0) {
		if (length $readbuf{$who} == $datalen{$who}) {
			# a POST, we got everything.
			respond($clt, $who, process_dispatch($clt, $who));
			return 0;
		} elsif (length $readbuf{$who} > $datalen{$who}) {
			# a POST, we got more than advertised.
			W "$who: More data than advertised";
			respond($clt, $who, "ERROR: More data than advertised. Nice try?\n");
			return 0;
		}
	}

	return 1;
}


# respond to client with a fake 200 OK and the actual response
sub respond
{
	my ($clt, $who, $data) = @_;

	my $len = length $data;
	my $resp = "HTTP/1.1 200 OK\r\n".
	           "Content-Type: text/plain; charset=UTF-8\r\n".
	           "Content-Length: $len\r\n".
	           "Connection: close\r\n\r\n$data";

	if (!$clt->send($resp)) {
		W "$who: send: $!";
	}
}


# -----------------------------------------------------------------------------


# Parse command-line, overriding defaults
Usage if !getopts("hvVl:d:m:H:c:", \%opts);

if (defined $opts{V}) {
	say "$version";
	exit 0;
}

Usage                 if defined $opts{h};
$verbose = 1          if defined $opts{v};
$manpath = $opts{m}   if defined $opts{m};
$pastedir = $opts{d}  if defined $opts{d};
$cltscript = $opts{c} if defined $opts{c};
$myhost = $opts{H}    if defined $opts{H};

if (defined $opts{l}) {
	my $tmp = $opts{l};
	if (!($tmp =~ /(?:(^.+):)?([0-9]+)$/)) {
		E 'Bad argument to -l (should be "PORT" or "ADDR:PORT")';
	}
	$bindaddr = $1 ? $1 : "0.0.0.0";
	$bindport = $2;
}

E "Could not read man page '$manpath' (Bad -m? Try -h)" if ! -r $manpath;
E "Could not read client script '$cltscript' (Bad -c? Try -h)" if ! -r $cltscript;
E "Could not access paste directory '$pastedir' (Bad -d? Try -h)" if ! -d $pastedir;

if (!$myhost) {
	my @out = `hostname`;
	$myhost = $out[0];
	chop $myhost;

	E "Failed to figure out hostname, use -H <FQDN>" if !$myhost;
	W "Determined our hostname to be '$myhost' (override with -H)";
}

D "Will listen on $bindaddr:$bindport; accessible as http://$myhost/";

# Generate paste '0' because it contains the client script we advertise in the man page
`sed "s/^site=.*\$/site='$myhost'/" $cltscript >$pastedir/0`;
E "Failed to generate paste 0 (the client script)" if (${^CHILD_ERROR_NATIVE} != 0);


$| = 1;

my $sck = new IO::Socket::INET (
	Type => SOCK_STREAM,
	Proto => 'tcp',
	Listen => 64,
	Reuse => 1,
	Blocking => 1,
	LocalAddr => $bindaddr,
	LocalPort => $bindport
) or E "Could not create socket $!\n";


my $sel = IO::Select->new();
$sel->add($sck);

while(1)
{
	D "Selecting...";
	my @rdbl = $sel->can_read;

	if (!@rdbl) {
		D "Nothing selected";
		next;
	}

	foreach my $s (@rdbl) {
		if ($s == $sck) {
			D "Listener is readable...";
			my $clt = $sck->accept();
			if (!$clt) {
				W "Failed to accept: $!";
				next;
			}
			my $who = $clt->peerhost().":".$clt->peerport();
			D "$who: Connected";

			$sel->add($clt);
			$readbuf{$who} = '';
			delete $datalen{$who};

			next;
		}

		my $who = $s->peerhost().":".$s->peerport();
		D "$who: Readable";

		if (!handle_clt($s, $who)) {
			D "$who: Dropping";
			$sel->remove($s);
			$s->close();
		}
	}
}

$sck->close();

#2015, Timo Buhrmester
