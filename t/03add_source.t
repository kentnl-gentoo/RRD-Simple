my $rrdfile = -d 't' ? 't/03add_source.rrd' : '03add_source.rrd';
unlink $rrdfile if -f $rrdfile;

use strict;
use Test::More tests => 5;
use lib qw(./lib ../lib);
use RRD::Simple ();

ok(my $rrd = RRD::Simple->new(),'new');

ok($rrd->create($rrdfile, "year",
		bytesIn => 'GAUGE',
		bytesOut => 'GAUGE',
		faultsPerSec => 'COUNTER',
		bytesDropped => 'GAUGE'
	),'create');

ok(join(',',sort $rrd->sources($rrdfile)) eq 'bytesDropped,bytesIn,bytesOut,faultsPerSec',
	'sources');

ok($rrd->update($rrdfile,
		bytesIn => 10039,
		bytesOut => 389,
		totalFaults => 992
	),'update (add_source)');

ok(join(',',sort $rrd->sources($rrdfile)) eq 'bytesDropped,bytesIn,bytesOut,faultsPerSec,totalFaults',
	'sources');

unlink $rrdfile if -f $rrdfile;

