use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'Net::Async::HTTP',
   requires => {
      'HTTP::Request' => 0,
      'HTTP::Request::Common' => 0,
      'HTTP::Response' => 0,
      'IO::Async::Loop' => '0.30',
      'IO::Async::Protocol::Stream' => 0,
      'IO::Async::Stream' => 0,
      'URI' => 0,
   },
   build_requires => {
      'IO::Async::Test' => 0,
      'Test::More' => 0,
   },
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
);
  
$build->create_build_script;
