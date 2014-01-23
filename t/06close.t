#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

$SIG{PIPE} = "IGNORE";

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new;
$loop->add( $http );

my $host = "host.example";

my $peersock;
no warnings 'redefine';
local *IO::Async::Handle::connect = sub {
   my $self = shift;
   my %args = @_;

   $args{host}    eq $host or die "Expected $args{host} eq $host";
   $args{service} eq "80"  or die "Expected $args{service} eq 80";

   ( my $selfsock, $peersock ) = IO::Async::OS->socketpair() or die "Cannot create socket pair - $!";
   $self->set_handle( $selfsock );

   return Future->new->done( $self );
};

{
   my @f = map { $http->do_request(
      request => HTTP::Request->new( GET => "/$_", [ Host => $host ] ),
      host    => $host,
   ) } 1 .. 3;

   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream = "";

   $peersock->print( "HTTP/1.1 200 OK$CRLF" .
                     "Content-Length: 0$CRLF" .
                     $CRLF );

   wait_for { $f[0]->is_ready };
   ok( !$f[0]->failure, 'First request succeeds before EOF' );

   $peersock->close;

   wait_for { $f[1]->is_ready };
   ok( $f[1]->failure, 'Second request fails after EOF' );

   # Not sure which error will happen
   like( scalar $f[1]->failure, qr/^Connection closed($| while awaiting header)/,
      'Queued request gets connection closed error' );

   wait_for { $f[2]->is_ready };
   ok( $f[2]->failure );
}

done_testing;
