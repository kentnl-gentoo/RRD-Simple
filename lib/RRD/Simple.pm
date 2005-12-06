package RRD::Simple;
# vim:ts=4:sw=4:tw=78

use strict;
use RRDs;
use Carp qw(croak cluck confess);
use File::Spec;
use File::Basename;

use constant DEBUG => $ENV{DEBUG} ? 1 : 0;
use constant DEFAULT_DSTYPE => exists $ENV{DEFAULT_DSTYPE}
						? $ENV{DEFAULT_DSTYPE} : 'GAUGE';

use vars qw($VERSION);
$VERSION = sprintf('%d.%02d', q$Revision: 1.7 $ =~ /(\d+)/g);


#
# Methods
#

# Create a new object
sub new {
	ref(my $class = shift) && croak 'Class name required';
	croak 'Odd number of elements passwd when even was expected' if @_ % 2;
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

	croak 'Odd number of elements passwd when even was expected' if @_ % 2;
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
				"using default DS type of ".DEFAULT_DSTYPE;
		my @args;
		for (my $i = 0; $i < @_; $i++) {
			push @args, ($_[$i],DEFAULT_DSTYPE) unless $i % 2;
		}
		$self->create($rrdfile,@args);
	}

	croak "RRD file '$rrdfile' does not exist" unless -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	# We've been given an update timestamp
	my $time = time();
	if (@_ % 2 && $_[0] =~ /^([1-9][0-9]{8,10})$/i) {
		$time =~ $1;
		shift @_;
	}
	TRACE("Using update time: $time");

	croak 'Odd number of elements passwd when even was expected' if @_ % 2;

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

	my @ds;
	foreach (keys %{RRDs::info($rrdfile)}) {
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
	my $rrds_path = File::Basename::dirname($INC{'RRDs.pm'});
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
	my ($basename, $dirname, $extension) = 
		File::Basename::fileparse($0, '\.[^\.]+');
	return "$dirname$basename.rrd";
}

sub TRACE {
	return unless DEBUG;
	warn(shift());
}

sub DUMP {
	return unless DEBUG;
	eval {
		require Data::Dumper;
		warn(shift().': '.Data::Dumper::Dumper(shift()));
	}
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
 # bytesIn, bytesOut and faultsPerSec. Data retention
 # of a year is specified. (The data retention parameter
 # is optional and not required).
 $rrd->create("myfile.rrd", "year",
             bytesIn => "GAUGE",
             bytesOut => "GAUGE",
             faultsPerSec => "COUNTER"
         ) || die "Failed to create RRD file: $!";
 
 # Put some arbitary data values in the RRD file for same
 # 3 data sources called bytesIn, bytesOut and faultsPerSec.
 $rrd->update("myfile.rrd",
             bytesIn => 10039,
             bytesOut => 389,
             faultsPerSec => 0.4
         ) || die "Failed to update RRD file: $!";
 
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
This module does not currently offer the C<graph>, C<fetch> or 
C<info> methods that are available in the RRDs module.

It does howeve create RRD files with a sensible set of default RRA
(Round Robin Archive) definitions, and can dynamically add new
data source names to an existing RRD file.

This module is ideal for quick and simple storage of data within an
RRD file if you do not need to, nor want to bother defining custom
RRA definitions.

=head1 METHODS

=head2 new

=head2 create

=head2 update

=head2 last

=head2 sources

=head2 add_source

=head1 TODO

Finish POD.

Write the retention duration scheme handling code. (Currently defaults
to one year retention only).

=head1 VERSION

$Revision: 1.7 $

=head1 AUTHOR

Nicola Worthington <nicolaw@cpan.org>

http://perlgirl.org.uk

$Author: nicolaw $

=cut


__END__



