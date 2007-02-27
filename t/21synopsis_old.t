# $Id: 21synopsis.t 945 2007-02-11 14:43:10Z nicolaw $

chdir('t') if -d 't';
my $rrdfile = -d 't' ? 't/21test.rrd' : '21test.rrd';
unlink $rrdfile if -f $rrdfile;

use strict;

BEGIN {
	use Test::More;
	eval "use RRDs";
	plan skip_all => "RRDs.pm *MUST* be installed!" if $@;
	plan tests => 7 if !$@;
}

use lib qw(./lib ../lib);
use RRD::Simple 1.35 ();

# Create an interface object
ok(my $rrd = RRD::Simple->new(),'new');

# Create a new RRD file with 3 data sources called
# bytesIn, bytesOut and faultsPerSec. Data retention
# of a year is specified. (The data retention parameter
# is optional and not required).
ok($rrd->create($rrdfile, "year",
		bytesIn => 'GAUGE',
		bytesOut => 'GAUGE',
		faultsPerSec => 'COUNTER'
	),'create');

# Put some arbitary data values in the RRD file for same
# 3 data sources called bytesIn, bytesOut and faultsPerSec.
my $updated = time();
ok($rrd->update($rrdfile,
		bytesIn => 10039,
		bytesOut => 389,
		faultsPerSec => 0.4
	),'update');

# Get unixtime of when RRD file was last updated
ok($rrd->last($rrdfile) - $updated < 5 && $rrd->last($rrdfile),
	'last');

ok(join(',',sort $rrd->sources($rrdfile)) eq 'bytesIn,bytesOut,faultsPerSec',
	'sources');

my %rtn = ();
ok(%rtn = $rrd->graph($rrdfile,
		title => "Network Interface eth0",
		vertical_label => "Bytes/Faults",
		interlaced => ""
	),'graph');

my $str = sprintf("Created %s",join(", ",map { $rtn{$_}->[0] } sort keys %rtn));
my $expected = "Created 21test-annual.png, 21test-daily.png, 21test-monthly.png, 21test-weekly.png";
ok("$str" eq "$expected",'created graphs');

for (map { $rtn{$_}->[0] } keys %rtn) {
	unlink $_ if -f $_;
}

unlink $rrdfile if -f $rrdfile;

1;

