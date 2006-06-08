#!/usr/bin/perl -w
############################################################
#
#   $Id$
#   iostat_foo.pl - Example script bundled as part of RRD::Simple
#
#   Copyright 2005,2006 Nicola Worthington
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
############################################################

use strict;
use RRD::Simple;

our $cmd = '/usr/bin/iostat -x 1';
our $ok = -1;

open(PH,'-|',$cmd) || die "Unable to open file handle PH for command '$cmd': $!";
while (local $_ = <PH>) {
	$ok++ if $ok < 1 && /^avg-cpu:/;
	next unless $ok > 0;
	next unless /^[hsm]d[a-z0-9]\s+/;
	my @x = split(/\s+/,$_);
	printf("%-10s %10s %10s\n",$x[0],$x[7],$x[8]);
}
close(PH) || die "Unable to close file handle PH for command '$cmd': $!";

