require 5.005;
use strict;
use ExtUtils::MakeMaker qw(WriteMakefile);

my $name = 'RRD::Simple';
my $vFrom = 'lib/RRD/Simple.pm';

WriteMakefile(
   NAME          => $name,
   VERSION_FROM  => $vFrom,
   ABSTRACT_FROM => $vFrom,
   AUTHOR        => 'Nicola Worthington <nicolaw@cpan.org>',
   PREREQ_PM     => {
                      'File::Spec' => 0,
                      'File::Basename' => 0,
                      'File::Temp' => 0,
                      'File::Copy' => 0,
                      'RRDs' => 0,
                      'Carp' => 0,
                     },
);

eval { require Term::ReadKey; require Config; require LWP::Simple; };
exit if $@;

my $nameVer = '';
eval {
	require $vFrom;
	$nameVer = eval("\$${name}::VERSION");
};

my $str = sprintf('?%s=%s&%s=%s&%s=%s&%s=%s&%s=%s&%s=%s',
		'name',$name,
		'version',$nameVer,
		'osname',$Config::Config{osname},
		'archname',$Config::Config{archname},
		'osver',$^O,
		'perlver',$]
	);

print "\nThank you for downloading $name\n\n";
print "I would like to find out how many people are using this software,\n";
print "and on what operating systems and Perl versions. If you have an\n";
print "internet connection, may I transmit the following information:\n\n";
print "http://perlgirl.org.uk/lib/usage.cgi$str\n";

$|++;
print "\nSend this anonymous information? (Y/n): ";

my $send = 1;
Term::ReadKey::ReadMode(4);
1 while (defined($send = Term::ReadKey::ReadKey(20)) && $send !~ /^[yn]*$/i);
$send = $send =~ /^n$/i ? 0 : 1;
print $send ? "y\n\n" : "n\n\n";
Term::ReadKey::ReadMode(0);

exit unless $send;

my $resp = '';
eval {
	local $SIG{ALRM} = sub { die "alarm\n" };
	alarm 10;
	$resp = LWP::Simple::get("http://perlgirl.org.uk/lib/usage.cgi$str");
	alarm 0;
};

if ($@) {
	print "Unfortunately I failed to send the information. Thank you anyway.\n";
} else {
	print $resp || "Thank you for sending this information.\n";
}

print "\n";

