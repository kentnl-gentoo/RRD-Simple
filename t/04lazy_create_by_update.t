my $rrdfile = -d 't' ? 't/04lazy_create_by_update.rrd' : '04lazy_create_by_update.rrd';
unlink $rrdfile if -f $rrdfile;

use strict;
use Test::More tests => 3;
use lib qw(./lib ../lib);
use RRD::Simple ();

my $created = time();
ok(RRD::Simple->update(
		ds0 => 1024,
		ds1 => 4096,
		ds2 => 512
	),'update (lazy create)');

ok(RRD::Simple->last() - $created < 5 && RRD::Simple->last(),
	'last');

ok(join(',',sort RRD::Simple->sources()) eq 'ds0,ds1,ds2',
	'sources');

unlink $rrdfile if -f $rrdfile;

