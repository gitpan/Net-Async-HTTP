#!/usr/bin/perl -w

use strict;

use Test::More tests => 10;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new(
   user_agent => "", # Don't put one in request headers
);

$loop->add( $http );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my $redir_response;
my $location;

my $response;

$http->do_request(
   uri => URI->new( "http://my.server/doc" ),
   handle => $S1,

   on_response => sub { $response = $_[0] },
   on_redirect => sub { ( $redir_response, $location ) = @_ },
   on_error    => sub { die "Test died early - $_[0]" },
);

my $request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

$request_stream =~ s/^(.*)$CRLF//;
my $req_firstline = $1;

is( $req_firstline, "GET /doc HTTP/1.1", 'First line for request' );

# Trim headers
$request_stream =~ s/^(.*)$CRLF$CRLF//s;

$S2->syswrite( "HTTP/1.1 301 Moved Permanently$CRLF" .
               "Content-Length: 0$CRLF" .
               "Location: http://my.server/get_doc?name=doc$CRLF" .
               "$CRLF" );

wait_for { defined $location };

is( $location, "http://my.server/get_doc?name=doc", 'Redirect happens' );

$request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

$request_stream =~ s/^(.*)$CRLF//;
$req_firstline = $1;

is( $req_firstline, "GET /get_doc?name=doc HTTP/1.1", 'First line for redirected request' );

# Trim headers
$request_stream =~ s/^(.*)$CRLF$CRLF//s;

$S2->syswrite( "HTTP/1.1 200 OK$CRLF" .
               "Content-Length: 8$CRLF".
               "Content-Type: text/plain$CRLF" .
               "$CRLF" .
               "Document" );

wait_for { defined $response };

is( $response->content_type, "text/plain", 'Content type of final response' );
is( $response->content, "Document", 'Content of final response' );

$http->do_request(
   uri => URI->new( "http://my.server/somedir" ),
   handle => $S1,

   on_response => sub { $response = $_[0] },
   on_redirect => sub { ( $redir_response, $location ) = @_ },
   on_error    => sub { die "Test died early - $_[0]" },
);

$request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

$request_stream =~ s/^(.*)$CRLF//;
$req_firstline = $1;

is( $req_firstline, "GET /somedir HTTP/1.1", 'First line for request for local redirect' );

# Trim headers
$request_stream =~ s/^(.*)$CRLF$CRLF//s;

$S2->syswrite( "HTTP/1.1 301 Moved Permanently$CRLF" .
               "Content-Length: 0$CRLF" .
               "Location: /somedir/$CRLF" .
               "$CRLF" );

undef $location;
wait_for { defined $location };

is( $location, "http://my.server/somedir/", 'Local redirect happens' );

$request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

$request_stream =~ s/^(.*)$CRLF//;
$req_firstline = $1;

is( $req_firstline, "GET /somedir/ HTTP/1.1", 'First line for locally redirected request' );

# Trim headers
$request_stream =~ s/^(.*)$CRLF$CRLF//s;

$S2->syswrite( "HTTP/1.1 200 OK$CRLF" .
               "Content-Length: 9$CRLF".
               "Content-Type: text/plain$CRLF" .
               "$CRLF" .
               "Directory" );

undef $response;
wait_for { defined $response };

is( $response->content_type, "text/plain", 'Content type of final response to local redirect' );
is( $response->content, "Directory", 'Content of final response to local redirect' );
