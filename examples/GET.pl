#!/usr/bin/perl

use strict;
use warnings;

use URI;

use IO::Async::Loop;
use Net::Async::HTTP;

my $loop = IO::Async::Loop->new;

my $ua = Net::Async::HTTP->new;
$loop->add( $ua );

$ua->do_request(
   method => "GET",
   uri    => URI->new( $ARGV[0] ),

   on_response => sub {
      my ( $response ) = @_;

      print $response->as_string;
      $loop->loop_stop;
   },

   on_error => sub {
      my ( $message ) = @_;

      print STDERR "Failed - $message\n";
      $loop->loop_stop;
   }
);

$loop->loop_forever;
