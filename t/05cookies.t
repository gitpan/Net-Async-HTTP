#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use IO::Async::Test;
use IO::Async::Loop;

use HTTP::Cookies;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $cookie_jar = HTTP::Cookies->new;

my $http = Net::Async::HTTP->new(
   user_agent => "", # Don't put one in request headers
   cookie_jar => $cookie_jar,
);

$loop->add( $http );

sub do_test_req
{
   my $name = shift;
   my %args = @_;

   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

   my $response;
   my $error;

   my $request = $args{req};

   $http->do_request(
      request => $request,
      handle  => $S1,

      on_response => sub { $response = $_[0] },
      on_error    => sub { $error    = $_[0] },
   );

   # Wait for the client to send its request
   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

   # Ignore first line
   $request_stream =~ s/^(.*)$CRLF//;

   $request_stream =~ s/^(.*)$CRLF$CRLF//s;
   my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $1 );

   my $req_content;
   if( defined( my $len = $req_headers{'Content-Length'} ) ) {
      wait_for { length( $request_stream ) >= $len };

      $req_content = substr( $request_stream, 0, $len );
      substr( $request_stream, 0, $len ) = "";
   }

   is_deeply( \%req_headers, $args{expect_req_headers}, "Request headers for $name" );

   $S2->syswrite( $args{response} );

   # Wait for the server to finish its response
   wait_for { defined $response or defined $error };

   my %h = map { $_ => $response->header( $_ ) } $response->header_field_names;

   is_deeply( \%h, $args{expect_res_headers}, "Result headers for $name" );
}

my $req;

$req = HTTP::Request->new( GET => "http://myhost/", [ Host => "myhost" ] );
$req->protocol( "HTTP/1.1" );

do_test_req( "set cookie",
   req => $req,

   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" .
               "Set-Cookie: X_TEST=MyCookie; path=/$CRLF" .
               "Content-Length: 0$CRLF" .
               $CRLF,

   expect_res_headers => {
      'Content-Length' => 0,
      'Set-Cookie'     => "X_TEST=MyCookie; path=/",
   },
);

$req = HTTP::Request->new( POST => "http://myhost/", [ Host => "myhost" ] );
$req->protocol( "HTTP/1.1" );

do_test_req( "get cookie",
   req => $req,

   expect_req_headers => {
      Host   => "myhost",
      Cookie  => "X_TEST=MyCookie",
      Cookie2 => '$Version="1"',
      'Content-Length' => 0,
   },

   response => "HTTP/1.1 200 OK$CRLF" .
               "Content-Length: 0$CRLF" .
               $CRLF,

   expect_res_headers => {
      'Content-Length' => 0,
   },
);
