#!/usr/bin/perl -w
############################################################
#
#   $Id: rrd-server.pl 693 2006-06-26 19:11:42Z nicolaw $
#   rrd-server.pl - Data gathering script for RRD::Simple
#
#   Copyright 2006 Nicola Worthington
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
# vim:ts=4:sw=4:tw=78

BEGIN {
	# User defined constants
	use constant BASEDIR => '/home/system/rrd';
}



BEGIN {
	# Ensure we can find RRDs.so for RRDs.pm
	eval "use RRDs";
	if ($@ && !defined $ENV{LD_LIBRARY_PATH}) {
		$ENV{LD_LIBRARY_PATH} = BASEDIR.'/lib';
		exec($0,@ARGV);
	}
}

use 5.004;
use strict;
use warnings;
use lib qw(../lib);
use RRD::Simple 1.39;
use RRDs;
use Memoize;
use Getopt::Std qw();
use File::Basename qw(basename);
use File::Path qw();
use Config::General qw();
use vars qw($VERSION);

$VERSION = '1.39' || sprintf('%d', q$Revision: 693 $ =~ /(\d+)/g);

# Get command line options
my %opt = ();
Getopt::Std::getopts('u:gthvf', \%opt);

# Display help or version
(display_version() && exit) if defined $opt{v};
(display_help() && exit) if defined $opt{h} ||
	!(defined $opt{u} || defined $opt{g} || defined $opt{t});

# cd to the righr location and define directories
chdir BASEDIR || die sprintf("Unable to chdir to '%s': %s", BASEDIR, $!);
my %dir = map { ( $_ => BASEDIR."/$_" ) } qw(bin spool data etc graphs cgi-bin thumbnails);

# Create an RRD::Simple object
my $rrd = RRD::Simple->new(rrdtool => "$dir{bin}/rrdtool");

# Cache results from read_create_data()
memoize('read_create_data');
memoize('read_graph_data');
memoize('basename');
memoize('graph_def');

# Go and do some work
my $hostname = defined $opt{u} ? update_rrd($rrd,\%dir,$opt{u}) : undef;
create_thumbnails($rrd,\%dir,$hostname) if defined $opt{t};
create_graphs($rrd,\%dir,$hostname) if defined $opt{g};

exit;




sub create_graphs {
	my ($rrd,$dir,$hostname,@options) = @_;

	my ($caller) = ((caller(1))[3] || '') =~ /.*::(.+)$/;
	my $destdir = defined $caller && $caller eq 'create_thumbnails'
			? $dir->{thumbnails} : $dir->{graphs};

	my @colour_theme = (color => [ (
			'BACK#F5F5FF','SHADEA#C8C8FF','SHADEB#9696BE',
			'ARROW#61B51B','GRID#404852','MGRID#67C6DE',
		) ] );

	my $gdefs = read_graph_data("$dir->{etc}/graph.defs");
	my @hosts = defined $hostname ? ($hostname) : list_dir("$dir->{data}");

	# For each hostname
	for my $hostname (sort @hosts) {
		# Create the graph directory for this hostname
		my $destination = "$destdir/$hostname";
		File::Path::mkpath($destination) unless -d $destination;

		# For each RRD
		for my $file (list_dir("$dir->{data}/$hostname")) {
			my $rrdfile = "$dir->{data}/$hostname/$file";
			my $graph = basename($file,'.rrd');
			my $gdef = graph_def($gdefs,$graph);
			eval {
				my @graph_opts = map { ($_ => $gdef->{$_}) }
						grep(!/^source(s|_)/,keys %{$gdef});
				push @graph_opts, map { ($_ => [ split(/\s+/,$gdef->{$_}) ]) }
						grep(/^source_/,keys %{$gdef});

				push @graph_opts, ('lazy','') unless exists $opt{f};

				# Only draw the sources we've been told to, and only
				# those that actually exist in the RRD file
				my @rrd_sources = $rrd->sources($rrdfile);
				if (defined $gdef->{sources}) {
					my @sources = ();
					for my $ds (split(/\s+/,$gdef->{sources})) {
						push @sources, $ds if grep(/^$ds$/,@rrd_sources);
					}
					push @graph_opts, ('sources',\@sources);
				} else {
					push @graph_opts, ('sources', [ sort @rrd_sources ]);
				}

				write_txt($rrd->graph($rrdfile,
						destination => $destination,
						@colour_theme,
						@options,
						@graph_opts,
					));
			};
			warn "$rrdfile => $@" if $@;
		}
	}
}

sub graph_def {
	my ($gdefs,$graph) = @_;

	my $rtn = {};
	for (keys %{$gdefs->{graph}}) {
		my $graph_key = qr(^$_$);
		if ($graph =~ /$graph_key/) {
			$rtn = { %{$gdefs->{graph}->{$_}} };
			my ($var) = $graph =~ /_([^_]+)$/;
			for my $key (keys %{$rtn}) {
				$rtn->{$key} =~ s/\$1/$var/g;
			}
			last;
		}
	}

	return $rtn;
}

sub list_dir {
	my $dir = shift;
	my @items = ();
	opendir(DH,$dir) || die "Unable to open file handle for directory '$dir': $!";
	@items = grep(!/^\./,readdir(DH));
	closedir(DH) || die "Unable to close file handle for directory '$dir': $!";
	return @items;
}

sub create_thumbnails {
	my ($rrd,$dir,$hostname) = @_;
	my @thumbnail_options = (only_graph => "", width => 125, height => 32);
	create_graphs($rrd,$dir,$hostname,@thumbnail_options);
}

sub update_rrd {
	my ($rrd,$dir,$hostname) = @_;
	my $filename = shift @ARGV || undef;

	# Check out the input data
	die "Input data file '$filename' does not exist.\n"
		if defined $filename && !-f $filename;
	die "No data recieved while expecting STDIN data from rrd-client.pl.\n"
		if !$filename && !key_ready();

	# Check the hostname is sane
	die "Hostname '$hostname' contains disallowed characters.\n"
		if $hostname =~ /[^\w\-\.\d]/ || $hostname =~ /^\.|\.$/;

	# Create the data directory for the RRD file if it doesn't exist
	File::Path::mkpath("$dir->{data}/$hostname") unless -d "$dir->{data}/$hostname";

	# Open the input file if specified
	if (defined $filename) {
		open(FH,'<',$filename) || die "Unable to open file handle for file '$filename': $!";
		select FH;
	};

	# Parse the data
	my %data = ();
	while (local $_ = <>) {
		my ($path,$value) = split(/\s+/,$_);
		my ($time,@path) = split(/\./,$path);
		my $key = pop @path;

		# Check that none of the data is bogus or bollocks
		my $bogus = 0;
		$bogus++ unless $time =~ /^\d+$/;
		$bogus++ unless $value =~ /^[\d\.]+$/;
		for (@path) {
			$bogus++ unless /^[\w\-\_\.\d]+$/;
		}
		next if $bogus;

		my $rrdfile = "$dir->{data}/$hostname/".join('_',@path).".rrd";
		$data{$rrdfile}->{$time}->{$key} = $value;
	}

	# Process the data
	for my $rrdfile (sort keys %data) {
		for my $time (sort keys %{$data{$rrdfile}}) {
			eval {
				create_rrd($rrd,$dir,$rrdfile,$data{$rrdfile}->{$time})
					unless -f $rrdfile;
				$rrd->update($rrdfile, $time, %{$data{$rrdfile}->{$time}});
			};
			warn $@ if $@;
		}
	}

	# Close the input file if specified
	if (defined $filename) {
		select STDOUT;
		close(FH) || warn "Unable to close file handle for file '$filename': $!";
	}

	return $hostname;
}

sub create_rrd {
	my ($rrd,$dir,$rrdfile,$data) = @_;
	my $defs = read_create_data("$dir->{etc}/create.defs");

	# Figure out what DS types to use
	my %create = map { ($_ => 'GAUGE') } sort keys %{$data};
	while (my ($match,$def) = each %{$defs}) {
		next unless basename($rrdfile,qw(.rrd)) =~ /$match/;
		for my $ds (keys %create) {
			$create{$ds} = $def->{'*'}->{type} if defined $def->{'*'}->{type};
			$create{$ds} = $def->{lc($ds)}->{type} if defined $def->{lc($ds)}->{type};
		}
	}

	# Create the RRD file
	$rrd->create($rrdfile, %create);

	# Tune to use min and max values if specified
	while (my ($match,$def) = each %{$defs}) {
		next unless basename($rrdfile,qw(.rrd)) =~ /$match/;
		for my $ds ($rrd->sources($rrdfile)) {
			my $min = defined $def->{lc($ds)}->{min} ? $def->{lc($ds)}->{min} :
				defined $def->{'*'}->{min} ? $def->{'*'}->{min} : undef;
			RRDs::tune($rrdfile,'-i',"$ds:$min") if defined $min;

			my $max = defined $def->{lc($ds)}->{max} ? $def->{lc($ds)}->{max} :
				defined $def->{'*'}->{max} ? $def->{'*'}->{max} : undef;
			RRDs::tune($rrdfile,'-a',"$ds:$max") if defined $max;
		}
	}
}

sub display_help {
	print qq{Syntax: $0 <-u hostname,-g,-t|-h|-v> [inputfile]
     -u <hostname>   Update RRD data for <hostname>
     -g              Create graphs from RRD data
     -t              Create thumbnails from RRD data
     -v              Display version information
     -h              Display this help\n};
}

# Display version
sub display_version {
	print "$0 version $VERSION ".'($Id: rrd-server.pl 693 2006-06-26 19:11:42Z nicolaw $)'."\n";
}

sub key_ready {
	my ($rin, $nfd) = ('','');
	vec($rin, fileno(STDIN), 1) = 1;
	return $nfd = select($rin,undef,undef,3);
}

sub read_graph_data {
	my $filename = shift || undef;

	my %config = ();
	eval {
		my $conf = new Config::General(
			-ConfigFile		=> $filename,
			-LowerCaseNames		=> 1,
			-UseApacheInclude	=> 1,
			-IncludeRelative	=> 1,
#			-DefaultConfig		=> \%default,
			-MergeDuplicateBlocks	=> 1,
			-AllowMultiOptions	=> 1,
			-MergeDuplicateOptions	=> 1,
			-AutoTrue		=> 1,
		);
		%config = $conf->getall;
	};
	warn $@ if $@;

	return \%config;
}

sub read_create_data {
	my $filename = shift || undef;
	my %defs = ();
	
	# Open the input file if specified
	if (defined $filename && -f $filename) {
		open(FH,'<',$filename) || die "Unable to open file handle for file '$filename': $!";
		select FH;
	} else {
		select DATA;
	}

	# Parse the file
	while (local $_ = <DATA>) {
		last if /^__END__\s*$/;
		next if /^\s*$/ || /^\s*#/;

		my %def = ();
		@def{qw(rrdfile ds type min max)} = split(/\s+/,$_);
		next unless defined $def{ds};
		$def{ds} = lc($def{ds});
		$def{rrdfile} = qr($def{rrdfile});
		for (keys %def) {
			if (!defined $def{$_} || $def{$_} eq '-') {	
				delete $def{$_};
			} elsif ($_ =~ /^(min|max)$/ && $def{$_} !~ /^[\d\.]+$/) {
				delete $def{$_};
			} elsif ($_ eq 'type' && $def{$_} !~ /^(GAUGE|COUNTER|DERIVE|ABSOLUTE|COMPUTE)$/i) {
				delete $def{$_};
			}
		}

		$defs{$def{rrdfile}}->{$def{ds}} = {
				map { ($_ => $def{$_}) } grep(!/^(rrdfile|ds)$/,keys %def)
			};
	}

	# Close the input file if specified
	select STDOUT;
	if (defined $filename && -f $filename) {
		close(FH) || warn "Unable to close file handle for file '$filename': $!";
	}

	return \%defs;
}

sub write_txt {
	my %rtn = @_;
	while (my ($period,$data) = each %rtn) {
		my $filename = shift @{$data};
		last if $filename =~ m,/thumbnails/,;
		my %values = ();
		my $max_len = 0;
		for (@{$data->[0]}) {
			my ($ds,$k,$v) = split(/\s+/,$_);
			$values{$ds}->{$k} = $v;
			$max_len = length($ds) if length($ds) > $max_len;
		}
		if (open(FH,'>',"$filename.txt")) {
			printf FH "%s (%dx%d) %dK\n\n", basename($filename),
			$data->[1], $data->[2], (stat($filename))[7]/1024;
			for (sort keys %values) {
				printf FH "%-${max_len}s     min: %s, max: %s, last: %s\n", $_,
				$values{$_}->{min}, $values{$_}->{max}, $values{$_}->{last};
			}
			close(FH);
		}
	}
}


1;


__DATA__

#	* means all
#	- means undef/na

# rrdfile	ds	type	min	max

^net_traffic_.+	Transmit	DERIVE	0	-
^net_traffic_.+	Receive	DERIVE	0	-

^hdd_io_.+	*	DERIVE	0	-

^apache_status$	ReqPerSec	DERIVE	0	-
^apache_status$	BytesPerSec	DERIVE	0	-
^apache_logs$	*	DERIVE	0	-

__END__
