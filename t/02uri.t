#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 44;
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

# Most of this function copypasted from t/01http-req.t

my $hostnum = 0;

sub do_test_uri
{
   my $name = shift;
   my %args = @_;

   my $response;
   my $error;

   my $peersock;
   no warnings 'redefine';
   local *Net::Async::HTTP::Protocol::connect = sub {
      my $self = shift;
      my %args = @_;

      $args{service} eq "80" or die "Expected $args{service} eq 80";

      ( my $selfsock, $peersock ) = $self->loop->socketpair() or die "Cannot create socket pair - $!";

      $self->IO::Async::Protocol::connect(
         transport => IO::Async::Stream->new( handle => $selfsock )
      );
   };

   $http->do_request(
      uri     => $args{uri},
      method  => $args{method},
      user    => $args{user},
      pass    => $args{pass},
      content => $args{content},
      content_type => $args{content_type},

      on_response => sub { $response = $_[0] },
      on_error    => sub { $error    = $_[0] },
   );

   wait_for { $peersock };

   # Wait for the client to send its request
   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

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

   $peersock->syswrite( $args{response} );

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

do_test_uri( "simple HEAD",
   method => "HEAD",
   uri    => URI->new( "http://host0/some/path" ),

   expect_req_firstline => "HEAD /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "host0",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF,

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "",
);

do_test_uri( "simple GET",
   method => "GET",
   uri    => URI->new( "http://host1/some/path" ),

   expect_req_firstline => "GET /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "host1",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF . 
               "Hello, world!",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "Hello, world!",
);

do_test_uri( "GET with params",
   method => "GET",
   uri    => URI->new( "http://host2/cgi?param=value" ),

   expect_req_firstline => "GET /cgi?param=value HTTP/1.1",
   expect_req_headers => {
      Host => "host2",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 11$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF . 
               "CGI content",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 11,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "CGI content",
);

do_test_uri( "authenticated GET",
   method => "GET",
   uri    => URI->new( "http://host3/secret" ),
   user   => "user",
   pass   => "pass",

   expect_req_firstline => "GET /secret HTTP/1.1",
   expect_req_headers => {
      Host => "host3",
      Authorization => "Basic dXNlcjpwYXNz", # determined using 'wget'
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 18$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF . 
               "For your eyes only",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 18,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "For your eyes only",
);

do_test_uri( "authenticated GET (URL embedded)",
   method => "GET",
   uri    => URI->new( "http://user:pass\@host4/private" ),

   expect_req_firstline => "GET /private HTTP/1.1",
   expect_req_headers => {
      Host => "host4",
      Authorization => "Basic dXNlcjpwYXNz", # determined using 'wget'
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 6$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF . 
               "Shhhh!",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 6,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "Shhhh!",
);

do_test_uri( "simple POST",
   method  => "POST",
   uri     => URI->new( "http://host5/handler" ),
   content => "New content",
   content_type => "text/plain",

   expect_req_firstline => "POST /handler HTTP/1.1",
   expect_req_headers => {
      Host => "host5",
      'Content-Length' => 11,
      'Content-Type' => "text/plain",
   },
   expect_req_content => "New content",

   response => "HTTP/1.1 201 Created$CRLF" . 
               "Content-Length: 11$CRLF" .
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF .
               "New content",

   expect_res_code    => 201,
   expect_res_headers => {
      'Content-Length' => 11,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "New content",
);

do_test_uri( "form POST",
   method  => "POST",
   uri     => URI->new( "http://host6/handler" ),
   content => [ param => "value", another => "value with things" ],

   expect_req_firstline => "POST /handler HTTP/1.1",
   expect_req_headers => {
      Host => "host6",
      'Content-Length' => 37,
      'Content-Type' => "application/x-www-form-urlencoded",
   },
   expect_req_content => "param=value&another=value+with+things",

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 4$CRLF" .
               "Content-Type: text/plain$CRLF" .
               "Connection: Keep-Alive$CRLF" .
               $CRLF .
               "Done",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 4,
      'Content-Type'   => "text/plain",
      'Connection'     => "Keep-Alive",
   },
   expect_res_content => "Done",
);
