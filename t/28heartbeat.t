# $Id$

my $rrdfile = -d 't' ? 't/28test.rrd' : '28test.rrd';
unlink $rrdfile if -f $rrdfile;

use strict;

BEGIN {
	use Test::More;
	eval "use RRDs";
	plan skip_all => "RRDs.pm *MUST* be installed!" if $@;
	plan tests => 4 if !$@;
}

use lib qw(./lib ../lib);
use RRD::Simple 1.40 ();

ok(my $rrd = RRD::Simple->new(),'new');

ok($rrd->create($rrdfile, "year",
		bytesIn => 'GAUGE',
		bytesOut => 'GAUGE',
		faultsPerSec => 'COUNTER',
		bytesDropped => 'GAUGE'
	),'create');

ok($rrd->rename_source($rrdfile,'bytesOut','knickers'),'rename_source()');
ok(grep($_ eq 'knickers',$rrd->sources($rrdfile)),'renamed source okay');

unlink $rrdfile if -f $rrdfile;

1;

