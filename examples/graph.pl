#!/usr/bin/perl -w
############################################################
#
#   $Id: graph.pl 613 2006-06-13 21:22:48Z nicolaw $
#   graph.pl - Example script bundled as part of RRD::Simple
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
use Data::Dumper;

my $rrdfile = '/home/system/colloquy/botbot/logs/botbot.rrd';
my $destdir = '/home/nicolaw/webroot/www/www.neechi.co.uk';

my @rtn = RRD::Simple->graph($rrdfile,
		destination => $destdir,
		'vertical-label' => 'Messages',
		'title' => 'Talker Activity',
	);

print Dumper(\@rtn);

