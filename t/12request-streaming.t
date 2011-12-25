#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 7;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new(
   user_agent => "", # Don't put one in request headers
);

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

my $req = HTTP::Request->new( PUT => "/handler", [ Host => "somewhere" ]);
$req->protocol( "HTTP/1.1" );
$req->content_length( 21 ); # set this manually based on what we plan to send

my $response;

my $done = 0;
$http->do_request(
   request => $req,
   host    => "myhost",

   request_body => sub {
      if( !$done ) {
         pass( "Callback after headers sent" );
         $done++;
         return "Content from callback";
      }
      elsif( $done == 1 ) {
         pass( "Second request seen, returning undef" );
         $done++;
         return undef;
      }
      else {
         fail( "called request_body too many times" );
      }
   },

   on_response => sub { $response = $_[0] },
   on_error    => sub { die "Test died early - $_[0]" },
);


# Wait for the client to send its request
my $request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

$request_stream =~ s/^(.*)$CRLF//;
my $req_firstline = $1;

is( $req_firstline, "PUT /handler HTTP/1.1", 'First line for streaming PUT' );

$request_stream =~ s/^(.*)$CRLF$CRLF//s;
my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $1 );

is_deeply( \%req_headers,
   {
      Host => "somewhere",
      'Content-Length' => 21,
   },
   'Request headers for streaming PUT'
);

my $req_content;
if( defined( my $len = $req_headers{'Content-Length'} ) ) {
   wait_for_stream { length( $request_stream ) >= $len } $peersock => $request_stream;

   $req_content = substr( $request_stream, 0, $len );
   substr( $request_stream, 0, $len ) = "";
}

is( $req_content, "Content from callback", 'Request content for streaming PUT' );

$peersock->syswrite( "HTTP/1.1 201 Created$CRLF" . 
                     "Content-Length: 0$CRLF" .
                     $CRLF );

wait_for { defined $response };

is( $response->code, 201, 'Result code for streaming PUT' );

my %res_headers = map { $_ => $response->header( $_ ) } $response->header_field_names;
is_deeply( \%res_headers,
   {
      'Content-Length' => 0,
   },
   'Result headers for streaming PUT'
);
