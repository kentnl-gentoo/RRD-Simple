package RRD::Simple;
# vim:ts=4:sw=4:tw=78

use strict;
use Exporter;
use RRDs;
use Carp qw(croak cluck confess);
use File::Spec;
use File::Basename qw(fileparse dirname basename);

use vars qw($VERSION $DEBUG $DEFAULT_DSTYPE
			 @EXPORT @EXPORT_OK %EXPORT_TAGS @ISA);

$VERSION = sprintf('%d.%02d', q$Revision: 1.24 $ =~ /(\d+)/g);

@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw(create update last_update graph info add_source sources);
%EXPORT_TAGS = (all => \@EXPORT_OK);

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
	cluck('Unrecognised parameters passed: '.
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
	my $rrdfile = (@_ % 2 && !_valid_scheme($_[0]))
				|| (!(@_ % 2) && _valid_scheme($_[1]))
					? shift : _guess_filename();
	croak "RRD file '$rrdfile' already exists" if -f $rrdfile;
	TRACE("Using filename: $rrdfile");

	# We've been given a scheme specifier
	my $scheme = 'year';
	if (@_ % 2 && _valid_scheme($_[0])) {
		$scheme = _valid_scheme($_[0]);
		shift @_;
	}
	TRACE("Using scheme: $scheme");

	croak 'Odd number of elements passed when even was expected' if @_ % 2;
	my %ds = @_;
	DUMP('%ds',\%ds);

	my $rrdDef = _rrd_def($scheme);
	my @def = ('-b', time - _seconds_in($scheme));
	push @def, '-s', ($rrdDef->{step} || 300);

	# Add data sources
	for my $ds (sort keys %ds) {
		$ds =~ s/[^a-zA-Z0-9_]//g;
		push @def, sprintf('DS:%s:%s:%s:%s:%s',
						substr($ds,0,19),
						uc($ds{$ds}),
						($rrdDef->{heartbeat} || 600),
						'U','U'
					);
	}

	# Add RRA definitions
	my %cf;
	for my $cf (qw(AVERAGE MIN MAX LAST)) {
		$cf{$cf} = $rrdDef->{rra};
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

	# We've been given an update timestamp
	my $time = time();
	if (@_ % 2 && $_[0] =~ /^([1-9][0-9]{8,10})$/i) {
		$time = $1;
		shift @_;
	}
	TRACE("Using update time: $time");

	# Try to automatically create it
	unless (-f $rrdfile) {
		cluck "RRD file '$rrdfile' does not exist; attempting to create it ",
				"using default DS type of $DEFAULT_DSTYPE";
		my @args;
		for (my $i = 0; $i < @_; $i++) {
			push @args, ($_[$i],$DEFAULT_DSTYPE) unless $i % 2;
		}
		$self->create($rrdfile,@args);
	}

	croak "RRD file '$rrdfile' does not exist" unless -f $rrdfile;
	TRACE("Using filename: $rrdfile");

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
			# If someone got the case wrong, remind and correct them
			if (grep(/^$ds$/i,@sources)) {
				cluck("Data source '$ds' does not exist. Automatically ",
					"correcting it to '",(grep(/^$ds$/i,@sources))[0],
					"' instead");
				$ds{(grep(/^$ds$/i,@sources))[0]} = $ds{$ds};
				delete $ds{$ds};

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
sub last_update { __PACKAGE__->last(@_); }
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

	# Check that we will understand this RRD file version first
	my $info = $self->info($rrdfile);
	croak "Unable to add a new data source to $rrdfile; ",
		"RRD version $info->{rrd_version} is too new"
		if ($info->{rrd_version}+1-1) > 1;

	my ($ds,$dstype) = @_;
	TRACE("\$ds = $ds");
	TRACE("\$dstype = $dstype");

	my $rrdfileBackup = "$rrdfile.bak";
	confess "$rrdfileBackup already exists; please investigate"
		if -e $rrdfileBackup;

	# Decide what heartbeat to use
	my $heartbeat = (sort { $info->{ds}->{$b}->{minimal_heartbeat} <=>
							$info->{ds}->{$b}->{minimal_heartbeat} }
					keys %{$info->{ds}})[0];
	TRACE("\$heartbeat = $heartbeat");

	# Make a list of expected sources after the addition
	my $TgtSources = join(',',sort(($self->sources($rrdfile),$ds)));

	# Add the data source
	my $new_rrdfile = '';
	eval {
		$new_rrdfile = _add_source(
				$rrdfile,$ds,$dstype,$heartbeat,$self->{rrdtool}
			);
	};

	# Barf if the eval{} got upset
	if ($@) {
		croak "Failed to add new data source '$ds' to RRD file $rrdfile: $@";
	}

	# Barf of the new RRD file doesn't exist
	unless (-f $new_rrdfile) {
		croak "Failed to add new data source '$ds' to RRD file $rrdfile: ",
				"new RRD file $new_rrdfile does not exist";
	}

	# Barf is the new data source isn't in our new RRD file
	unless ($TgtSources eq join(',',sort($self->sources($new_rrdfile)))) {
		croak "Failed to add new data source '$ds' to RRD file $rrdfile: ",
				"new RRD file $new_rrdfile does not contain expected data ",
				"source names";
	}

	# Try and move the new RRD file in to place over the existing one
	# and then remove the backup RRD file if sucessfull
	if (File::Copy::move($rrdfile,$rrdfileBackup) &&
				File::Copy::move($new_rrdfile,$rrdfile)) {
		unlink($rrdfileBackup) ||
			cluck "Failed to remove back RRD file $rrdfileBackup: $!";
	} else {
		croak "Failed to move new RRD file in to place: $!";
	}
}


# Make a number of graphs for an RRD file
sub graph {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = @_ % 2 ? shift : _guess_filename();

	my @rtn;
	for my $type (qw(day week month year)) {
		push @rtn, [ ($self->_create_graph($rrdfile, $type, @_)) ];
	}
	#push @rtn, [ ($self->_create_graph($rrdfile, '3year', @_)) ];
	return @rtn;
}


# Fetch data point information from an RRD file
sub fetch {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = @_ % 2 ? shift : _guess_filename();

}


# Fetch the last values inserted in to an RRD file
sub last_values {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = @_ % 2 ? shift : _guess_filename();

	my $lastUpdated = $self->last($rrdfile);
	my @def = ('LAST',
				'-s', $lastUpdated,
				'-e', $lastUpdated
			);

	# Pass to RRDs to execute
	my ($time,$heartbeat,$ds,$data) = RRDs::fetch($rrdfile, @def);
	my $error = RRDs::error;
	croak($error) if $error;

	# Put it in to a nice easy format
	my %rtn = (
			map { $_ => shift(@{$data->[0]}) } @{$ds}
		);

	# Well, I'll be buggered if the LAST CF does what you'd think
	# it's meant to do. If anybody can give me some decent documentation
	# on what the LAST CF does, and/or how to get the last value put
	# in to an RRD, then I'll admit that this method exists and export
	# it too.

	return %rtn;
}


# Fetch information about an RRD file
sub info {
	my $self = shift;
	unless(ref $self eq __PACKAGE__ || UNIVERSAL::isa($self, __PACKAGE__)) {
		unshift @_, $self;
		$self = new __PACKAGE__;
	}

	# Grab or guess the filename
	my $rrdfile = @_ % 2 ? shift : _guess_filename();

	my $info = RRDs::info($rrdfile);
	my $error = RRDs::error;
	croak($error) if $error;
	DUMP('$info',$info);

	my $rtn;
	for my $key (sort(keys(%{$info}))) {
		if ($key =~ /^rra\[(\d+)\]\.([a-z_]+)/) {
			$rtn->{rra}->[$1]->{$2} = $info->{$key};
		} elsif (my (@dsKey) = $key =~ /^ds\[([[A-Za-z0-9\_]+)?\]\.([a-z_]+)/) {
			$rtn->{ds}->{$1}->{$2} = $info->{$key};
		} elsif ($key !~ /\[[\d_a-z]+\]/i) {
			$rtn->{$key} = $info->{$key};
		}
	}

	# Return the information
	DUMP('$rtn',$rtn);
	return $rtn;
}


# Make a single graph image
sub _create_graph {
	my $self = shift;
	my $rrdfile = shift;
	my $type = _valid_scheme(shift) || 'day';

	my %param;
	while (my $k = shift) {
		$k =~ s/_/-/g;
		$param{lc($k)} = shift;
	}

	# Specify some default values
	$param{'end'} ||= time();
	$param{'imgformat'} ||= 'PNG';
	$param{'alt-autoscale'} ||= '';
	$param{'alt-y-grid'} ||= '';

	# Define what to call the image
	my $basename = defined $param{'basename'} &&
						$param{'basename'} =~ /^\w+$/i ?
						$param{'basename'} :
						(fileparse($rrdfile,'\.[^\.]+'))[0];
	delete $param{'basename'};

	# Define where to write the image
	my $image = sprintf('%s-%s.%s',$basename,
				_alt_graph_name($type), lc($param{'imgformat'}));
	if ($param{'destination'}) {
		$image = File::Spec->catfile($param{'destination'},$image);
	}
	delete $param{'destination'};

	# Define how thick the graph lines should be
	my $line_thickness = defined $param{'line-thickness'} &&
						$param{'line-thickness'} =~ /^[123]$/ ?
						$param{'line-thickness'} : 1;
	delete $param{'line-thickness'};

	# Define which data sources we should plot
	my @ds = defined $param{'sources'} &&
						ref($param{'sources'}) eq 'ARRAY' ?
						@{$param{'sources'}} : $self->sources($rrdfile);
	delete $param{'sources'};

	# Specify a default start time
	$param{'start'} ||= time - _seconds_in($type);

	# Suffix the title with the period information
	$param{'title'} ||= basename($rrdfile);
	$param{'title'} .= ' - [Daily Graph: 5 min average]'    if $type eq 'day';
	$param{'title'} .= ' - [Weekly Graph: 30 min average]'  if $type eq 'week';
	$param{'title'} .= ' - [Monthly Graph: 2 hour average]' if $type eq 'month';
	$param{'title'} .= ' - [Annual Graph: 1 day average]'   if $type eq 'year';
	$param{'title'} .= ' - [3 Year Graph: 1 day average]'   if $type eq '3year';

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
	tie my $colour, 'RRD::Simple::_Colour', [ qw(
			FF0000 00FF00 0000FF FFFF00 00FFFF FF00FF 000000
			550000 005500 000055 555500 005555 550055 555555
			AA0000 00AA00 0000AA AAAA00 00AAAA AA00AA AAAAAA
		) ];

	# Add the data sources to the graph
	my @cmd = ($image,@def);
	for my $ds (@ds) {
		push @cmd, sprintf('DEF:%s=%s:%s:AVERAGE',$ds,$rrdfile,$ds);
		push @cmd, sprintf('%s:%s#%s:%-22s',
				"LINE$line_thickness", $ds, $colour, $ds
			);
	}

	# Add a comment stating when the graph was last updated
	push @cmd, ('COMMENT:\s','COMMENT:\s','COMMENT:\s');
	(my $time = localtime()) =~ s/:/\\:/g;
	push @cmd, 'COMMENT:Last updated\: '. $time .'\r';

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

sub _rrd_def {
	croak('Pardon?!') if ref $_[0];
	my $type = _valid_scheme(shift);

	my $rtn = {
			step => 300, heartbeat => 600,
			rra => [(
				{ step => 1, rows => 599 },
				{ step => 6, rows => 700 },
				{ step => 24, rows => 775 },
				{ step => 228, rows => 796 },
			)],
		};

	if ($type eq 'day') {
		@{$rtn->{qw(step heartbeat)}} = qw(60 120);
		$rtn->{rra} = [
				{ step => 1, rows => 599 },
				{ step => 5, rows => 599 },
			];

	} elsif ($type eq 'week') {
		@{$rtn->{qw(step heartbeat)}} = qw(60 120);
		$rtn->{rra} = [
				{ step => 1, rows => 599 },
				{ step => 5, rows => 599 },
				{ step => 30, rows => 599 },
			];

	} elsif ($type eq 'month') {
		@{$rtn->{qw(step heartbeat)}} = qw(60 120);
		$rtn->{rra} = [
				{ step => 1, rows => 599 },
				{ step => 5, rows => 500 },
				{ step => 30, rows => 599 },
				{ step => 60, rows => 1000 },
			];

	} elsif ($type eq '3year') {
		$rtn->{rra}->[3]->{rows} = 2400;
	}

	return $rtn;
}

sub _add_source {
	croak('Pardon?!') if ref $_[0];
	my ($rrdfile,$ds,$dstype,$heartbeat,$rrdtool) = @_;

	require File::Copy;
	require File::Temp;

	# Generate an XML dump of the RRD file
	my $tempXmlFile = File::Temp::tmpnam();
	_safe_exec(sprintf('%s dump %s > %s',$rrdtool,$rrdfile,$tempXmlFile));
	open(IN, "<$tempXmlFile") || croak "Unable to open '$tempXmlFile': $!";

	# Open XML output file
	my $tempImportXmlFile = File::Temp::tmpnam();
	open(OUT, ">$tempImportXmlFile")
		|| croak "Unable to open '$tempImportXmlFile': $!";

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
	close(IN) || croak "Unable to close '$tempXmlFile': $!";
	close(OUT) || croak "Unable to close '$tempImportXmlFile': $!";

	# Import the new output file in to the old RRD filename
	my $new_rrdfile = File::Temp::tmpnam();
	my $cmd = sprintf('%s restore %s %s',$rrdtool,$tempImportXmlFile,$new_rrdfile);
	my $rtn = _safe_exec($cmd);

	# At least check the file is created
	croak "Command '$cmd' failed to create the new RRD file $new_rrdfile: $rtn"
		unless -e $new_rrdfile;

	# Remove the temporary files
	unlink $tempXmlFile;
	unlink $tempImportXmlFile;

	# Return the new RRD filename
	return $new_rrdfile;
}


sub _alt_graph_name {
	croak('Pardon?!') if ref $_[0];
	my $type = _valid_scheme(shift);
	return 'daily'   if $type eq 'day';
	return 'weekly'  if $type eq 'week';
	return 'monthly' if $type eq 'month';
	return 'annual'  if $type eq 'year';
	return '3years'  if $type eq '3years';
	return $type;
}


sub _valid_scheme {
	croak('Pardon?!') if ref $_[0];
	TRACE(@_);
	if ($_[0] =~ /^(day|week|month|year|3years)$/i) {
		return lc($1);
	}
	return undef;
}


sub _seconds_in {
	croak('Pardon?!') if ref $_[0];
	my $str = lc(shift);

	my %time = (
			day   => 86400,    # 60 * 60 * 24
			week  => 604800,   # 60 * 60 * 24 * 7
			month => 2678400,  # 60 * 60 * 24 * 31
			year  => 31536000, # 60 * 60 * 24 * 365
		);

	if ($str eq 'day') {
		return $time{day} * 2;
	} elsif ($str eq 'week') {
		return $time{week} + $time{day};
	} elsif ($str eq 'month') {
		return $time{month} + $time{week};
	} elsif ($str eq '3year') {
		return ($time{year} * 3) + $time{month};
	}
	return $time{year} + $time{month};
}


sub _safe_exec {
	croak('Pardon?!') if ref $_[0];
	my $cmd = shift;
	if ($cmd =~ /^([\/\.\_\-a-zA-Z0-9 >]+)$/) {
		$cmd = $1;
		TRACE($cmd);
		system($cmd);
		if ($? == -1) {
			croak "Failed to execute command '$cmd': $!\n";
		} elsif ($? & 127) {
			croak(sprintf("While executing command '%s', child died ".
				"with signal %d, %s coredump\n", $cmd,
				($? & 127),  ($? & 128) ? 'with' : 'without'));
		}
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
	croak('Pardon?!') if ref $_[0];
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

package RRD::Simple::_Colour;

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
             vertical_label => "Bytes/Faults",
             interlaced => ""
         );

 # Return information about an RRD file
 my $info = $rrd->info("myfile.rrd");
 require Data::Dumper;
 print Data::Dumper::Dumper($info);

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
This module does not currently offer C<fetch> method that is
available in the RRDs module.

It does however create RRD files with a sensible set of default RRA
(Round Robin Archive) definitions, and can dynamically add new
data source names to an existing RRD file.

This module is ideal for quick and simple storage of data within an
RRD file if you do not need to, nor want to bother defining custom
RRA definitions.

=head1 METHODS

=head2 new

 my $rrd = RRD::Simple->new(
         rrdtool => "/usr/local/rrdtool-1.2.11/bin/rrdtool"
     );

The C<rrdtool> parameter is optional. It specifically defines where the
C<rrdtool> binary can be found. If not specified, the module will search for
the C<rrdtool> binary in your path, and an additional location relative 
where the C<RRDs> module was loaded from.

The C<rrdtool> binary is only used by the C<add_source> method, which could
also be automatically called by the C<update> method if data point values for
a previous undefined data source are provided for insertion.

=head2 create

 $rrd->create($rrdfile, $period,
         source_name => "TYPE",
         source_name => "TYPE",
         source_name => "TYPE"
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

C<$period> is optional and will default to C<year>. Valid options are C<day>,
C<week>, C<month>, C<year> and C<3years>. Specifying a retention period value
will change how long data will be retained for within the RRD file.

RRD::Simple will croak and die if you try to create an RRD file that already
exists.

=head2 update

 $rrd->update($rrdfile, $unixtime,
         source_name => "VALUE",
         source_name => "VALUE",
         source_name => "VALUE"
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

C<$unixtime> is optional and will default to C<time()> (the current unixtime).
Specifying this value will determine the date and time that your data point
values will be stored against in the RRD file.

If you try update a value for a data source that does not exist, it will
automatically be added for you. The data source type will be set to whatever
is contained in the C<$RRD::Simple::DEFAULT_DSTYPE> variable. (See the
VARIABLES section below).

If you explicitly do not want this to happen, then you should check that you
are only updating pre-existing data source names using the C<sources> method.
You can manually add new data sources to an RRD file by using the C<add_source>
method, which requires you to explicitly set the data source type.

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
         source_name => "TYPE"
     );

B<NOTE>: This method will not currently work with rrdtool v1.2.x (RRD file
version 003). It is known to work with v1.0.49 and others. This will be fixed
in future versions of RRD::Simple. 

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

You may add a new data source to an existing RRD file using this method. Only
one data source name can be added at a time. You must also specify the data
source type.

This method can be called internally by the C<update> method to automatically
add missing data sources.

=head2 graph

 $rrd->graph($rrdfile,
         destination => "/path/to/write/graph/images",
         basename => "graph_basename",
         sources => [ qw(source_name1 source_name2 source_name3) ],
         line_thickness => 2,
         rrd_graph_option => "value",
         rrd_graph_option => "value",
         rrd_graph_option => "value"
     );

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

Graph options specific to RRD::Simple are:

=over 4

=item "destination"

The C<destination> parameter is optional, and it will default to the same
path location as that of the RRD file specified by C<$rrdfile>. Specifying
this value will force the resulting graph images to be written to this path
location. (The specified path must be a valid directory with the sufficient
permissions to write the graph images).

=item "basename"

The C<basename> paramater is optional. This parameter specifies the basename
of the graph image files that will be created. If not specified, tt will
default to the name of the RRD file. For exmaple, if you specify a basename
name of C<mygraph>, the following graph image files will be created in the
C<destination> directory:

 mygraph-daily.png
 mygraph-weekly.png
 mygraph-monthly.png
 mygraph-annual.png

The default file format is C<png>, but this can be explicitly specified using
the standard RRDs options. (See below).

=item "sources"

The C<sources> paramater is optional. This parameter should be an array
of data source names that you want to be plotted. All data sources will be
plotted by default.

=item "line_thickness"

Specifies the thickness of the data lines drawn on the graphs. Valid values
are 1, 2 and 3 (pixels).

=back

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
complete list of parameters can be found at
L<http://people.ee.ethz.ch/~oetiker/webtools/rrdtool/doc/index.en.html>.

=head2 info

 my $info = $rrd->info($rrdfile);

C<$rrdfile> is optional and will default to C<$0.rrd>. (Script basename with
the file extension of .rrd).

This method will return a complex data structure containing details about
the RRD file, including RRA and data source information.

=head1 VARIABLES

=head2 $RRD::Simple::DEBUG

Debug and trace information will be printed to STDERR if this variable
if set to 1 (boolean true).

This variable will take it's value from C<$ENV{DEBUG}>, if it exists,
otherwise it will default to 0 (boolean false). This is a normal package
variable and may be safely modified at any time.

=head2 $RRD::Simple::DEFAULT_DSTYPE

This variable is used as the default data source type when creating or
adding new data sources, when no other data source type is explicitly
specified.

This variable will take it's value from C<$ENV{DEFAULT_DSTYPE}>, if it
exists, otherwise it will default to C<GAUGE>. This is a normal package
variable and may be safely modified at any time.

=head1 EXPORTS

You can export the following functions if you do not wish to go through
the extra effort of using the OO interface:

 create
 update
 last_update (synonym for the last() method)
 sources
 add_source
 graph
 info

The tag C<all> is available to easily export everything:

 use RRD::Simple qw(:all);

See the examples and unit tests in this distribution for more
details.

=head1 TODO

Finish POD.

Fix the add_source() method to work with the latest versions of RRD.

Write a fetch() method.

=head1 SEE ALSO

L<RRDTool::OO>, L<RRDs>,
L<http://www.rrdtool.org>, examples/*.pl

=head1 VERSION

$Id: Simple.pm,v 1.24 2005/12/26 19:04:22 nicolaw Exp $

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



