my $rrdfile = -d 't' ? 't/02lazy_example_test.rrd' : '02lazy_example_test.rrd';
unlink $rrdfile if -f $rrdfile;

use strict;
use Test::More tests => 4;
use lib qw(./lib ../lib);
use RRD::Simple ();

my $created = time();
ok(RRD::Simple->create(
		bytesIn => 'GAUGE',
		bytesOut => 'GAUGE',
		faultsPerSec => 'COUNTER'
	),'create');

ok(RRD::Simple->update(
		bytesIn => 10039,
		bytesOut => 389,
		faultsPerSec => 0.4
	),'update');

ok(RRD::Simple->last() - $created < 5 && RRD::Simple->last(),
	'last');

ok(join(',',sort RRD::Simple->sources()) eq 'bytesIn,bytesOut,faultsPerSec',
	'sources');

unlink $rrdfile if -f $rrdfile;

