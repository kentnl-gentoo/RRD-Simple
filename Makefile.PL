require 5.005;
use strict;
use ExtUtils::MakeMaker qw(WriteMakefile);

WriteMakefile(
   NAME          => 'RRD::Simple',
   VERSION_FROM  => 'lib/RRD/Simple.pm',
   ABSTRACT_FROM => 'lib/RRD/Simple.pm',
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
