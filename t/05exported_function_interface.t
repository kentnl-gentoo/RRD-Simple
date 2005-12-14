my $rrdfile = -d 't' ? 't/05test.rrd' : '05test.rrd';
unlink $rrdfile if -f $rrdfile;

use strict;
use Test::More tests => 9;
use lib qw(./lib ../lib);
use RRD::Simple qw(:all);

ok(create($rrdfile,
		bytesIn => 'GAUGE',
		bytesOut => 'GAUGE',
		faultsPerSec => 'COUNTER'
	),'create');

my $updated = time();
ok(update($rrdfile,
		bytesIn => 10039,
		bytesOut => 389,
		faultsPerSec => 0.4
	),'update');

ok(last_update($rrdfile) - $updated < 5 && last_update($rrdfile),
	'last_update');

ok(join(',',sort(sources($rrdfile))) eq 'bytesIn,bytesOut,faultsPerSec',
	'sources');

(my $imgbasename = $rrdfile) =~ s/\.rrd$//;

ok(graph($rrdfile,destination => 't/'),'graph');
for (qw(daily weekly monthly annual)) {
	my $img = "$imgbasename-$_.png";
	ok(-f $img,"$img");
	unlink $img if -f $img;
}

unlink $rrdfile if -f $rrdfile;

