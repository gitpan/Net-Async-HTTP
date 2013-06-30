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
local *Net::Async::HTTP::Protocol::connect = sub {
   my $self = shift;
   my %args = @_;

   $args{host}    eq $host or die "Expected $args{host} eq $host";
   $args{service} eq "80"  or die "Expected $args{service} eq 80";

   ( my $selfsock, $peersock ) = IO::Async::OS->socketpair() or die "Cannot create socket pair - $!";

   $self->IO::Async::Protocol::connect(
      transport => IO::Async::Stream->new( handle => $selfsock )
   );
};

my @resp;
my @err;
$http->do_request(
   request => HTTP::Request->new( GET => "/$_", [ Host => $host ] ),
   host    => $host,
   on_response => sub { push @resp, shift },
   on_error    => sub { push @err, shift },
) for 1 .. 2;

my $request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

$request_stream = "";

$peersock->print( "HTTP/1.1 200 OK$CRLF" .
                  "Content-Length: 0$CRLF" .
                  $CRLF );
$peersock->close;

wait_for { $resp[0] };

wait_for { $err[0] };

# Not sure which error will happen
like( $err[0], qr/^Connection closed($| while awaiting header)/,
   'Queued request gets connection closed error' );

done_testing;
