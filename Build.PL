use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'Net::Async::HTTP',
   requires => {
                 'IO::Async'      => '0.17',
                 'HTTP::Request'  => 0,
                 'HTTP::Response' => 0,
   },
   build_requires => {
                        'IO::Async::Sequencer' => 0,
                        'IO::Async::Test' => 0,
                        'Test::More' => 0,
                     },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );
  
$build->create_build_script;
