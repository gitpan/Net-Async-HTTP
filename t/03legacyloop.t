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
   loop => $loop,
);

is( $http->get_loop, $loop, '$http->get_loop returns $loop' );

sub do_test_req
{
   my $name = shift;
   my %args = @_;

   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

   my $response;
   my $error;

   $http->do_request(
      request => $args{req},
      handle  => $S1,

      on_response => sub { $response = $_[0] },
      on_error    => sub { $error    = $_[0] },
   );

   # Wait for the client to send its request
   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, $args{expect_req_firstline}, "First line for $name" );

   $request_stream =~ s/^(.*)$CRLF$CRLF//s;
   my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $1 );

   my $req_content;
   if( defined( my $len = $req_headers{'Content-Length'} ) ) {
      wait_for { length( $request_stream ) >= $len };

      $req_content = substr( $request_stream, 0, $len );
      substr( $request_stream, 0, $len ) = "";
   }

   is_deeply( \%req_headers, $args{expect_req_headers}, "Request headers for $name" );

   if( defined $args{expect_req_content} ) {
      is( $req_content, $args{expect_req_content}, "Request content for $name" );
   }

   $S2->syswrite( $args{response} );
   $S2->close if $args{close_after_response};

   # Wait for the server to finish its response
   wait_for { defined $response or defined $error };

   if( $args{expect_error} ) {
      ok( defined $error, "Expected error for $name" );
      return;
   }
   else {
      ok( !defined $error, "Failed to error for $name" );
      if( defined $error ) {
         diag( "Got error $error" );
      }
   }

   if( exists $args{expect_res_code} ) {
      is( $response->code, $args{expect_res_code}, "Result code for $name" );
   }

   if( exists $args{expect_res_content} ) {
      is( $response->content, $args{expect_res_content}, "Result content for $name" );
   }

   if( exists $args{expect_res_headers} ) {
      my %h = map { $_ => $response->header( $_ ) } $response->header_field_names;

      is_deeply( \%h, $args{expect_res_headers}, "Result headers for $name" );
   }
}

my $req;

$req = HTTP::Request->new( HEAD => "/some/path", [ Host => "myhost" ] );
$req->protocol( "HTTP/1.1");

do_test_req( "simple HEAD",
   req => $req,

   expect_req_firstline => "HEAD /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF,

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "",
);
