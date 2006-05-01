# $Id: 20compile.t 426 2006-05-01 17:13:15Z nicolaw $

chdir('t') if -d 't';
use lib qw(./lib ../lib);
use Test::More tests => 2;

use_ok('RRD::Simple');
require_ok('RRD::Simple');

1;

