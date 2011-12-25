#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 12;
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

{
   my $redir_response;
   my $location;

   my $response;

   my $peersock;
   no warnings 'redefine';
   local *Net::Async::HTTP::Protocol::connect = sub {
      my $self = shift;
      my %args = @_;

      $args{host}    eq "host0" or die "Expected $args{host} eq host0";
      $args{service} eq "80"    or die "Expected $args{service} eq 80";

      ( my $selfsock, $peersock ) = $self->loop->socketpair() or die "Cannot create socket pair - $!";

      $self->IO::Async::Protocol::connect(
         transport => IO::Async::Stream->new( handle => $selfsock )
      );
   };

   $http->do_request(
      uri => URI->new( "http://host0/doc" ),

      timeout => 10,

      on_response => sub { $response = $_[0] },
      on_redirect => sub { ( $redir_response, $location ) = @_ },
      on_error    => sub { die "Test died early - $_[0]" },
   );

   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, "GET /doc HTTP/1.1", 'First line for request' );

   # Trim headers
   $request_stream =~ s/^(.*)$CRLF$CRLF//s;

   $peersock->syswrite( "HTTP/1.1 301 Moved Permanently$CRLF" .
                        "Content-Length: 0$CRLF" .
                        "Location: http://host0/get_doc?name=doc$CRLF" .
                        "$CRLF" );

   wait_for { defined $location };

   is( $location, "http://host0/get_doc?name=doc", 'Redirect happens' );

   $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   $req_firstline = $1;

   is( $req_firstline, "GET /get_doc?name=doc HTTP/1.1", 'First line for redirected request' );

   # Trim headers
   $request_stream =~ s/^(.*)$CRLF$CRLF//s;

   $peersock->syswrite( "HTTP/1.1 200 OK$CRLF" .
                        "Content-Length: 8$CRLF".
                        "Content-Type: text/plain$CRLF" .
                        "$CRLF" .
                        "Document" );

   wait_for { defined $response };

   is( $response->content_type, "text/plain", 'Content type of final response' );
   is( $response->content, "Document", 'Content of final response' );

   isa_ok( $response->previous, "HTTP::Response", '$response->previous' );

   my $previous = $response->previous;
   is( $previous->request->uri, "/doc", 'Previous request URI' );
}

{
   my $redir_response;
   my $location;

   my $response;

   my $peersock;
   no warnings 'redefine';
   local *Net::Async::HTTP::Protocol::connect = sub {
      my $self = shift;
      my %args = @_;

      $args{host}    eq "host1" or die "Expected $args{host} eq host1";
      $args{service} eq "80"    or die "Expected $args{service} eq 80";

      ( my $selfsock, $peersock ) = $self->loop->socketpair() or die "Cannot create socket pair - $!";

      $self->IO::Async::Protocol::connect(
         transport => IO::Async::Stream->new( handle => $selfsock )
      );
   };

   $http->do_request(
      uri => URI->new( "http://host1/somedir" ),

      timeout => 10,

      on_response => sub { $response = $_[0] },
      on_redirect => sub { ( $redir_response, $location ) = @_ },
      on_error    => sub { die "Test died early - $_[0]" },
   );

   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, "GET /somedir HTTP/1.1", 'First line for request for local redirect' );

   # Trim headers
   $request_stream =~ s/^(.*)$CRLF$CRLF//s;

   $peersock->syswrite( "HTTP/1.1 301 Moved Permanently$CRLF" .
                        "Content-Length: 0$CRLF" .
                        "Location: /somedir/$CRLF" .
                        "$CRLF" );

   undef $location;
   wait_for { defined $location };

   is( $location, "http://host1/somedir/", 'Local redirect happens' );

   $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $request_stream =~ s/^(.*)$CRLF//;
   $req_firstline = $1;

   is( $req_firstline, "GET /somedir/ HTTP/1.1", 'First line for locally redirected request' );

   # Trim headers
   $request_stream =~ s/^(.*)$CRLF$CRLF//s;

   $peersock->syswrite( "HTTP/1.1 200 OK$CRLF" .
                        "Content-Length: 9$CRLF".
                        "Content-Type: text/plain$CRLF" .
                        "$CRLF" .
                        "Directory" );

   undef $response;
   wait_for { defined $response };

   is( $response->content_type, "text/plain", 'Content type of final response to local redirect' );
   is( $response->content, "Directory", 'Content of final response to local redirect' );
}
