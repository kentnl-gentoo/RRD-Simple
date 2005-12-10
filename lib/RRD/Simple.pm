package RRD::Simple;
# vim:ts=4:sw=4:tw=78

use strict;
use RRDs;
use Carp qw(croak cluck confess);
use File::Spec;
use File::Basename qw(fileparse dirname basename);

use vars qw($VERSION $DEBUG $DEFAULT_DSTYPE);
$VERSION = sprintf('%d.%02d', q$Revision: 1.13 $ =~ /(\d+)/g);

$DEBUG = $ENV{DEBUG} ? 1 : 0;
$DEFAULT_DSTYPE = exists $ENV{DEFAULT_DSTYPE}
					? $ENV{DEFAULT_DSTYPE} : 'GAUGE';



#
# Methods
#

# Create a new object
sub new {
	ref(my $class = shift) && croak 'Class name required';
	croak 'Odd number of elements passed when even was expected' if @_ % 2;
	my $self = { @_ };

	my $validkeys = join('|',qw(rrdtool));
	cluck('Unrecognised paramaters passed: '.
		join(', ',grep(!/^$validkeys$/,keys %{$self})))
		if grep(!/^$validkeys$/,keys %{$self});

	$self->{rrdtool} = _find_binary(exists $self->{rrdtool} ?
						$self->{rrdtool} : 'rrdtool');

	bless($self,$class);
	DUMP($class,$self);
	return $self;
}


# Create a new RRD file
sub create {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = (@_ % 2 && $_[0] !~ /^day|week|month|year|3years$/i)
				|| (!(@_ % 2) && $_[1] =~ /^day|week|month|year|3years$/i)
					? shift : _guess_filename();
	croak "RRD file '$rrdfile' already exists" if -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	# We've been given a scheme specifier
	my $scheme = 'year';
	if (@_ % 2 && $_[0] =~ /^(day|week|month|year|3years)$/i) {
		$scheme =~ lc($1);
		shift @_;
	}
	TRACE("Using scheme: $scheme");

	croak 'Odd number of elements passed when even was expected' if @_ % 2;
	my %ds = @_;
	DUMP('%ds',\%ds);

	my @def = ('-b', time()-(3600*24*1200));
	push @def, '-s', 300;

	# Add data sources
	for my $ds (sort keys %ds) {
		$ds =~ s/[^a-zA-Z0-9_]//g;
		push @def, sprintf('DS:%s:%s:%s:%s:%s',
						substr($ds,0,19),
						uc($ds{$ds}),
						600,
						'U','U'
					);
	}

	# Add RRA definitions
	my %cf;
	for my $cf (qw(AVERAGE MIN MAX LAST)) {
		my @rra = (
				{ step => 1, rows => 599 },
				{ step => 6, rows => 700 },
				{ step => 24, rows => 775 },
				{ step => 228, rows => 796 },
			);
		$cf{$cf} = \@rra;
	}
	for my $cf (sort keys %cf) {
		for my $rra (@{$cf{$cf}}) {
			push @def, sprintf('RRA:%s:%s:%s:%s',
					$cf, 0.5, $rra->{step}, $rra->{rows}
				);
		}
	}

	DUMP('@def',\@def);

	# Pass to RRDs for execution
	my @rtn = RRDs::create($rrdfile, @def);
	my $error = RRDs::error;
	croak($error) if $error;
	DUMP('RRDs::info',RRDs::info($rrdfile));
	return @rtn;
}


# Update an RRD file with some data values
sub update {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = (@_ % 2 && $_[0] !~ /^[1-9][0-9]{8,10}$/i)
				 || (!(@_ % 2) && $_[1] =~ /^[1-9][0-9]{8,10}$/i)
					? shift : _guess_filename();

	# Try to automatically create it
	unless (-f $rrdfile) {
		cluck "RRD file '$rrdfile' does not exist; attempting to create it",
				"using default DS type of $DEFAULT_DSTYPE";
		my @args;
		for (my $i = 0; $i < @_; $i++) {
			push @args, ($_[$i],$DEFAULT_DSTYPE) unless $i % 2;
		}
		$self->create($rrdfile,@args);
	}

	croak "RRD file '$rrdfile' does not exist" unless -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	# We've been given an update timestamp
	my $time = time();
	if (@_ % 2 && $_[0] =~ /^([1-9][0-9]{8,10})$/i) {
		$time = $1;
		shift @_;
	}
	TRACE("Using update time: $time");

	croak 'Odd number of elements passed when even was expected' if @_ % 2;

	my %ds;
	while (my $ds = shift(@_)) {
		$ds =~ s/[^a-zA-Z0-9_]//g;
		$ds = substr($ds,0,19);
		$ds{$ds} = shift(@_);
	}
	DUMP('%ds',\%ds);

	# Validate the data source names as we add them
	my @sources = $self->sources($rrdfile);
	for my $ds (sort keys %ds) {
		# Check the data source names
		if (!grep(/^$ds$/,@sources)) {
			# If someone got the case wrong, go boom so they can fix it
			if (grep(/^$ds$/i,@sources)) {
				croak("Data source '$ds' does not exist. Did you mean '",
					grep(/^$ds$/i,@sources),"' instead?");

			# Otherwise add any missing or new data sources on the fly
			} else {
				# Decide what DS type and heartbeat to use
				my $info = RRDs::info($rrdfile);
				my $error = RRDs::error;
				croak($error) if $error;

				my %dsTypes;
				for my $key (grep(/^ds\[.+?\]\.type$/,keys %{$info})) {
					$dsTypes{$info->{$key}}++;
				}
				DUMP('%dsTypes',\%dsTypes);
				my $dstype = (sort { $dsTypes{$b} <=> $dsTypes{$a} }
								keys %dsTypes)[0];
				TRACE("\$dstype = $dstype");

				$self->add_source($rrdfile,$ds,$dstype);
			}
		}
	}

	# Build the def
	my @def = ('--template');
	push @def, join(':',sort keys %ds);
	push @def, join(':',$time,map { $ds{$_} } sort keys %ds);
	DUMP('@def',\@def);

	# Pass to RRDs to execute the update
	my @rtn = RRDs::update($rrdfile, @def);
	my $error = RRDs::error;
	croak($error) if $error;
	return @rtn;
}


# Get the last time an RRD was updates
sub last {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	my $rrdfile = shift || _guess_filename();
	croak "RRD file '$rrdfile' does not exist" unless -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	my $last = RRDs::last($rrdfile);
	my $error = RRDs::error;
	croak($error) if $error;
	return $last;
}


# Get a list of data sources from an RRD file
sub sources {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	my $rrdfile = shift || _guess_filename();
	croak "RRD file '$rrdfile' does not exist" unless -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	my $info = RRDs::info($rrdfile);
	my $error = RRDs::error;
	croak($error) if $error;

	my @ds;
	foreach (keys %{$info}) {
		if (/^ds\[(.+)?\]\.type$/) {
			push @ds, $1;
		}
	}
	return @ds;
}

# Add a new data source to an RRD file
sub add_source {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = @_ % 2 ? shift : _guess_filename();
	unless (-f $rrdfile) {
		cluck "RRD file '$rrdfile' does not exist; attempting to create it";
		return $self->create($rrdfile,@_);
	}
	croak "RRD file '$rrdfile' does not exist" unless -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	my ($ds,$dstype) = @_;
	TRACE("\$ds = $ds");
	TRACE("\$dstype = $dstype");

	require File::Copy;
	require File::Temp;

	my $rrdfileBackup = "$rrdfile.bak";
	confess "$rrdfileBackup already exists; please investigate"
		if -e $rrdfileBackup;

	# Decide what heartbeat to use
	my $info = RRDs::info($rrdfile);
	my $error = RRDs::error;
	croak($error) if $error;

	my %dsHeartbeats;
	for my $key (grep(/^ds\[.+?\]\.minimal_heartbeat$/,keys %{$info})) {
		$dsHeartbeats{$info->{$key}}++;
	}
	DUMP('%dsHeartbeats',\%dsHeartbeats);
	my $heartbeat = (sort { $dsHeartbeats{$b} <=> $dsHeartbeats{$a} }
					keys %dsHeartbeats)[0];
	TRACE("\$heartbeat = $heartbeat");

	# Generate an XML dump of the RRD file
	my $tempXmlFile = File::Temp::tmpnam();
	_safe_exec(sprintf('%s dump %s > %s',$self->{rrdtool},$rrdfile,$tempXmlFile));

	# Move the original RRD file out of the way
	if (-f $tempXmlFile) {
		File::Copy::move($rrdfile, $rrdfileBackup);
		unless (-f $rrdfileBackup) {
			unlink $tempXmlFile;
			croak "Failed to move $rrdfile to $rrdfileBackup";
		}
	} else {
		croak "Failed to dump $rrdfile out to $tempXmlFile";
	}

	# Open XML input file
	unless (open(IN, "<$tempXmlFile")) { 
		File::Copy::move($rrdfileBackup, $rrdfile);
		unlink $tempXmlFile;
		croak "Unable to open '$tempXmlFile'";
	}

	# Open XML output file
	my $tempImportXmlFile = File::Temp::tmpnam();
	unless (open(OUT, ">$tempImportXmlFile")) {
		File::Copy::move($rrdfileBackup, $rrdfile);
		unlink $tempXmlFile;
		croak "Unable to open '$tempImportXmlFile'";
	}

	# Create a marker hash ref to store temporary state
	my $marker = {
				insertDS => 0,
				insertCDP_PREP => 0,
				parse => 0,
			};

	# Parse the input XML file
	while (local $_ = <IN>) {
		chomp;

		# Add the DS definition
		if ($marker->{insertDS} == 1) {
			print OUT <<EndDS;

	<ds>
		<name> $ds </name>
		<type> $dstype </type>
		<minimal_heartbeat> $heartbeat </minimal_heartbeat>
		<min> 0.0000000000e+00 </min>
		<max> NaN </max>

		<!-- PDP Status -->
		<last_ds> UNKN </last_ds>
		<value> 1.8530980000e+01 </value>
		<unknown_sec> 0 </unknown_sec>
	</ds>
EndDS
			$marker->{insertDS} = 0;
		}

		# Insert DS under CDP_PREP entity
		if ($marker->{insertCDP_PREP} == 1) {
			print OUT "			<ds><value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
			$marker->{insertCDP_PREP} = 0;
		}

		# Look for end of the <lastupdate> entity
		if (/<\/lastupdate>/) {
			$marker->{insertDS} = 1;
	
		# Look for start of the <cdp_prep> entity
		} elsif (/<cdp_prep>/) {
			$marker->{insertCDP_PREP} = 1;

		# Look for the end of an RRA
		} elsif (/<\/database>/) {
			$marker->{parse} = 0;
		}

		# Add the extra "<v> NaN </v>" under the RRAs. Just print normal lines
		if ($marker->{parse} == 1) {
			if ($_ =~ /^(.+ <row>)(.+)/) {
				print OUT $1;
				print OUT "<v> NaN </v>";
				print OUT $2;
				print OUT "\n";
			}
		} else {
			print OUT "$_\n";
		}

		# Look for the start of an RRA
		if (/<database>/) {
			$marker->{parse} = 1;
		}
	}

	# Close the files
	close(IN);
	close(OUT);

	# Import the new output file in to the old RRD filename
	_safe_exec(sprintf('%s restore %s %s',$self->{rrdtool},$tempImportXmlFile,$rrdfile));
	unless (-f $rrdfile) {
		File::Copy::move($rrdfileBackup, $rrdfile);
		unlink $tempXmlFile;
		unlink $tempImportXmlFile;
		unlink $rrdfileBackup;
		croak "Failed to import $tempImportXmlFile in to $rrdfile";
	}

	# Remove the temporary files
	unlink $tempXmlFile;
	unlink $tempImportXmlFile;
	unlink $rrdfileBackup;
}

sub graph {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = @_ % 2 ? shift : _guess_filename();

	my @rtn;
	push @rtn, [ ($self->_create_graph($rrdfile, 'daily', @_)) ];
	push @rtn, [ ($self->_create_graph($rrdfile, 'weekly', @_)) ];
	push @rtn, [ ($self->_create_graph($rrdfile, 'monthly', @_)) ];
	push @rtn, [ ($self->_create_graph($rrdfile, 'annual', @_)) ];
	return @rtn;
}

sub _create_graph {
	my $self = shift;
	croak "Pardon?!" unless ((caller(0))[3]) eq 'RRD::Simple::_create_graph';
	my ($rrdfile,$type) = (shift,shift);

	my %param;
	while (my $k = shift) {
		$param{lc($k)} = shift;
	}

	# Specify some default values
	$param{'end'} ||= time();
	$param{'imgformat'} ||= 'PNG';
	$param{'alt-autoscale'} ||= '';
	$param{'alt-y-grid'} ||= '';

	# Define where to write the image
	my $image = basename($rrdfile).".$type.".lc($param{'imgformat'});
	if ($param{'destination'}) {
		$image = File::Spec->catfile($param{'destination'},$image);
	}
	delete $param{'destination'};

	# Define how thick the graph lines should be
	my $line_thickness = defined $param{'line-thickness'} &&
						$param{'line-thickness'} =~ /^[123]$/ ?
						$param{'line-thickness'} : 1;
	delete $param{'line-thickness'};

	# Specify a default start time
	unless ($param{'start'}) {
		$param{'start'} = time-(60*60*48);
		$param{'start'} = time-(60*60*24*8) if $type =~ /week/i;
		$param{'start'} = time-(60*60*24*62) if $type =~ /month/i;
		$param{'start'} = time-(60*60*24*370) if $type =~ /annual|year/i;
	}

	# Suffix the title with the period information
	$param{'title'} ||= basename($rrdfile);
	$param{'title'} .= ' - [Daily Graph: 5 min average]' if $type =~ /daily|day/i;
	$param{'title'} .= ' - [Weekly Graph: 30 min average]' if $type =~ /week/i;
	$param{'title'} .= ' - [Monthly Graph: 2 hour average]' if $type =~ /month/i;
	$param{'title'} .= ' - [Annual Graph: 1 day average]' if $type =~ /annual|year/i;

	# Convert our parameters in to an RRDs friendly defenition
	my @def;
	while (my ($k,$v) = each %param) {
		if (length($k) == 1) { $k = '-'.uc($k); }
		else { $k = "--$k"; }
		if (!defined $v || !length($v)) {
			push @def, $k;
		} else {
			push @def, "$k=$v";
		}
	}

	# Populate a cycling tied scalar for line colours
	tie my $colour, 'Colour', [ qw(
			FFFF00 FF0000 FF00FF 00FFFF 0000FF 000000
			555500 550000 550055 005555 000055 
			AAAA00 AA0000 AA00AA 00AAAA 0000AA
			AAAAAA 555555
		) ];

	# Add the data sources to the graph
	my @cmd = ($image,@def);
	for my $ds ($self->sources($rrdfile)) {
		push @cmd, sprintf('DEF:%s=%s:%s:AVERAGE',$ds,$rrdfile,$ds);
		push @cmd, sprintf('%s:%s#%s:%-22s',
				"LINE$line_thickness", $ds, $colour, $ds
			);
	}

	# Add a comment stating when the graph was last updated
	push @cmd, ('COMMENT:\s','COMMENT:\s','COMMENT:\s');
	push @cmd, 'COMMENT:Last updated: '.localtime().'\r';

	DUMP('@cmd',\@cmd);

	# Generate the graph
	my @rtn = RRDs::graph(@cmd);
	my $error = RRDs::error;
	croak($error) if $error;
	return @rtn;
}




#
# Private subroutines
#

sub _safe_exec {
	croak('Pardon?!') if ref $_[0];
	my $cmd = shift;
	if ($cmd =~ /^([\/\.\_\-a-zA-Z0-9 >]+)$/) {
		$cmd = $1;
		system($cmd);
		my $exit_value = $? >> 8;
		croak "Error caught from '$cmd'" if $exit_value != 0;
		return $exit_value;
	} else {
		croak "Unexpected potentially unsafe command will not be executed: $cmd";
	}
}

sub _find_binary {
	croak('Pardon?!') if ref $_[0];
	my $binary = shift || 'rrdtool';
	return $binary if -f $binary && -x $binary;

	my @paths = File::Spec->path();
	my $rrds_path = dirname($INC{'RRDs.pm'});
	push @paths, $rrds_path;
	push @paths, File::Spec->catdir($rrds_path,
				File::Spec->updir(),File::Spec->updir(),'bin');

	for my $path (@paths) {
		my $filename = File::Spec->catfile($path,$binary);
		return $filename if -f $filename && -x $filename;
	}
}

sub _guess_filename {
	croak('Pardon?!') if ref shift;
	my ($basename, $dirname, $extension) = fileparse($0, '\.[^\.]+');
	return "$dirname$basename.rrd";
}

sub TRACE {
	return unless $DEBUG;
	warn(shift());
}

sub DUMP {
	return unless $DEBUG;
	eval {
		require Data::Dumper;
		warn(shift().': '.Data::Dumper::Dumper(shift()));
	}
}

1;


###############################################################
# This tie code is from Tie::Cycle
# written by brian d foy, <bdfoy@cpan.org>

package Colour;

sub TIESCALAR {
	my ($class,$list_ref) = @_;
	my @shallow_copy = map { $_ } @$list_ref;
	return unless UNIVERSAL::isa( $list_ref, 'ARRAY' );
	my $self = [ 0, scalar @shallow_copy, \@shallow_copy ];
	bless $self, $class;
}

sub FETCH {
	my $self = shift;
	my $index = $$self[0]++;
	$$self[0] %= $self->[1];
	return $self->[2]->[ $index ];
}

sub STORE {
	my ($self,$list_ref) = @_;
	return unless ref $list_ref eq ref [];
	return unless @$list_ref > 1;
	$self = [ 0, scalar @$list_ref, $list_ref ];
}

1;




=pod

=head1 NAME

RRD::Simple - Simple interface to create and store data in RRD files

=head1 SYNOPSIS

 use strict;
 use RRD::Simple ();
 
 # Create an interface object
 my $rrd = RRD::Simple->new();
 
 # Create a new RRD file with 3 data sources called
 # bytesIn, bytesOut and faultsPerSec.
 $rrd->create("myfile.rrd",
             bytesIn => "GAUGE",
             bytesOut => "GAUGE",
             faultsPerSec => "COUNTER"
         );
 
 # Put some arbitary data values in the RRD file for same
 # 3 data sources called bytesIn, bytesOut and faultsPerSec.
 $rrd->update("myfile.rrd",
             bytesIn => 10039,
             bytesOut => 389,
             faultsPerSec => 0.4
         );
 
 # Generate graphs
 my @rtn = $rrd->graph("myfile.rrd",
             destination => "/var/tmp",
             title => "Network Interface eth0",
             "vertical-label" => "Bytes/Faults",
             "interlaced" => ""
         );

 # Get unixtime of when RRD file was last updated
 my $lastUpdated = $rrd->last("myfile.rrd");
 print "myfile.rrd was last updated at " .
       scalar(localtime($lastUpdated)) . "\n";
 
 # Get list of data source names from an RRD file
 my @dsnames = $rrd->sources("myfile.rrd");
 print "Available data sources: " . join(", ", @dsnames) . "\n";
 
 # And for the ultimately lazy, you could create and update
 # an RRD in one go using a one-liner like this:
 perl -MRRD::Simple -e'RRD::Simple->update(@ARGV)' myfile.rrd bytesIn 99999 

=head1 DESCRIPTION

RRD::Simple provides a simple interface to RRDTool's RRDs module.
This module does not currently offer C<fetch> or C<info> methods
that are available in the RRDs module.

It does however create RRD files with a sensible set of default RRA
(Round Robin Archive) definitions, and can dynamically add new
data source names to an existing RRD file.

This module is ideal for quick and simple storage of data within an
RRD file if you do not need to, nor want to bother defining custom
RRA definitions.

=head1 METHODS

=head2 new

 my $rrd = RRD::Simple->new(
         rrdtool => '/usr/local/rrdtool-1.2.11/bin/rrdtool'
     );

The C<rrdtool> paramater is optional. It specifically defines where the
C<rrdtool> binary can be found. If not specified, the module will search for
the C<rrdtool> binary in your path, and an additional location relative 
where the C<RRDs> module was loaded from.

The C<rrdtool> binary is only used by the C<add_source> method, which could
also be automatically called by the C<update> method if data point values for
a previous undefined data source are provided for insertion.

=head2 create

 $rrd->create($rrdfile, $period,
         source_name => 'TYPE',
         source_name => 'TYPE',
         source_name => 'TYPE'
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

C<$period> is optional and will default to C<year>. Valid options are C<day>,
C<week>, C<month>, C<year> and C<3years>. Specifying a retention period value
will change how long data will be retained for within the RRD file.

=head2 update

 $rrd->update($rrdfile, $unixtime,
         source_name => 'VALUE',
         source_name => 'VALUE',
         source_name => 'VALUE'
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

C<$unixtime> is optional and will default to C<time()> (the current unixtime).
Specifying this value will determine the date and time that your data point
values will be stored against in the RRD file.

=head2 last

 my $unixtime = $rrd->last($rrdfile);

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

=head2 sources

 my @sources = $rrd->sources($rrdfile);

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

=head2 add_source

 $rrd->add_source($rrdfile,
         source_name => 'TYPE'
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

=head2 graph

 $rrd->graph($rrdfile,
         destination => '/path/to/write/graph/images',
         rrd_graph_option => 'value',
         rrd_graph_option => 'value',
         rrd_graph_option => 'value'
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

The C<destination> paramater is optional, and it will default to the same
path location as that of the RRD file specified by C<$rrdfile>. Specifying
this value will force the resulting graph images to be written to this path
location. (The specified path must be a valid directory with the sufficient
permissions to write the graph images).

Common RRD graph options are:

=over 4

=item "title"

A horizontal string at the top of the graph.

=item "vertical-label"

A vertically placed string at the left hand side of the graph.

=item "width"

The width of the canvas (the part of the graph with the actual data
and such). This defaults to 400 pixels.

=item "height"

The height of the canvas (the part of the graph with the actual data
and such). This defaults to 100 pixels.

=back

For examples on how to best use the C<graph> method, refer to the example
scripts that are bundled with this module in the examples/ directory. A
complete list of paramaters can be found at
L<http://people.ee.ethz.ch/~oetiker/webtools/rrdtool/doc/index.en.html>.

=head1 VARIABLES

=head2 $RRD::Simple::DEBUG

Debug and trace information will be printed to STDERR if this variable
if set to boolean true.

This variable will take it's value from C<$ENV{DEBUG}>, if it exists,
otherwise it will default to C<0> (boolean off). This is a normal package
variable and may be safely modified at any time.

=head2 $RRD::Simple::DEFAULT_DSTYPE

This variable is used as the default data source type when creating or
adding new data sources, when no other data source type is explicitly
specified.

This variable will take it's value from C<$ENV{DEFAULT_DSTYPE}>, if it
exists, otherwise it will default to C<GAUGE>. This is a normal package
variable and may be safely modified at any time.

=head1 TODO

Finish POD.

Write the retention duration scheme handling code. (Currently defaults
to one year retention only).

Write info() and fetch() methods.

=head1 SEE ALSO

L<RRDTool::Managed>, L<RRDTool::OO>, L<RRD::Query>, L<RRDs>,
L<http://www.rrdtool.org>, examples/*.pl

=head1 VERSION

$Id: Simple.pm,v 1.13 2005/12/10 15:56:22 nicolaw Exp $

=head1 AUTHOR

Nicola Worthington <nicolaw@cpan.org>

L<http://perlgirl.org.uk>

=head1 COPYRIGHT

(c) Nicola Worthington 2005. This program is free software; you can
redistribute it and/or modify it under the GNU GPL.

See the file COPYING in this distribution, or
L<http://www.gnu.org/licenses/gpl.txt>

=cut


__END__



