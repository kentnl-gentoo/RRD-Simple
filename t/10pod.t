# $Id: 10pod.t 945 2007-02-11 14:43:10Z nicolaw $

use Test::More;
eval "use Test::Pod 1.00";
plan skip_all => "Test::Pod 1.00 required for testing POD" if $@;
all_pod_files_ok();

1;

