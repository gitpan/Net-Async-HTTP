#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Refcount;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new();

$loop->add( $http );

my $peersock;

no warnings 'redefine';
local *Net::Async::HTTP::Protocol::connect = sub {
   my $self = shift;
   my %args = @_;

   ( my $selfsock, $peersock ) = $self->loop->socketpair() or die "Cannot create socket pair - $!";

   $self->IO::Async::Protocol::connect(
      transport => IO::Async::Stream->new( handle => $selfsock )
   );
};

{
   my $errcount;
   my $error;

   my $future = $http->do_request(
      uri => URI->new( "http://my.server/doc" ),

      timeout => 1, # Really quick for testing

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount++; $error = $_[0] },
   );

   is_refcount( $http, 2, '$http refcount 2 after ->do_request with timeout' );

   wait_for { defined $error };

   is( $error, "Timed out", 'Received timeout error' );
   is( $errcount, 1, 'on_error invoked once' );

   ok( $future->is_ready, '$future is ready after timeout' );
   is( scalar $future->failure, "Timed out", '$future->failure after timeout' );

   is_refcount( $http, 2, '$http refcount 2 after ->do_request with timeout fails' );
}

{
   my $errcount;
   my $error;

   my $future = $http->do_request(
      uri => URI->new( "http://my.server/redir" ),

      timeout => 1, # Really quick for testing

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount++; $error = $_[0] },
   );

   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;

   $peersock->syswrite( "HTTP/1.1 301 Moved Permanently$CRLF" .
                        "Content-Length: 0$CRLF" .
                        "Location: http://my.server/get_doc?name=doc$CRLF" .
                        "Connection: Keep-Alive$CRLF" .
                        "$CRLF" );

   wait_for { defined $error };

   is( $error, "Timed out", 'Received timeout error from redirect' );
   is( $errcount, 1, 'on_error invoked once from redirect' );

   ok( $future->is_ready, '$future is ready after timeout' );
   is( scalar $future->failure, "Timed out", '$future->failure after timeout' );
}

{
   my $error;
   my $errcount;

   $http->do_request(
      uri => URI->new( "http://my.server/first" ),

      timeout => 1, # Really quick for testing

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount++; $error = $_[0] },
   );

   my $error2;
   my $errcount2;

   $http->do_request(
      uri => URI->new( "http://my.server/second" ),

      timeout => 3,

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount2++; $error2 = $_[0] },
   );

   wait_for { defined $error };
   is( $error, "Timed out", 'Received timeout error from pipeline' );
   is( $errcount, 1, 'on_error invoked once from pipeline' );

   wait_for { defined $error2 };
   is( $error2, "Timed out", 'Received timeout error from pipeline(2)' );
   is( $errcount2, 1, 'on_error invoked once from pipeline(2)' );
}

$loop->remove( $http );

is_oneref( $http, '$http has refcount 1 before EOF' );

done_testing;
