# $Id: 20compile.t 945 2007-02-11 14:43:10Z nicolaw $

chdir('t') if -d 't';

BEGIN {
	use Test::More;
	eval "use RRDs";
	plan skip_all => "RRDs.pm *MUST* be installed!" if $@;
	plan tests => 2 if !$@;
}

use lib qw(./lib ../lib);
use_ok('RRD::Simple');
require_ok('RRD::Simple');

1;

