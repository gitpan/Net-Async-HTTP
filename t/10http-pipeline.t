#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;
use IO::Async::Test;
use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

use IO::Socket::UNIX;
use Socket qw( AF_UNIX SOCK_STREAM PF_UNSPEC );

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new(
   loop => $loop,
);

# Most of this function copypasted from t/01http-req.t

sub do_uris
{
   ( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
      die "Cannot create socket pair - $!";

   my %wait;
   my $wait_id = 0;

   while( my ( $uri, $on_resp ) = splice @_, 0, 2 ) {
      $wait{$wait_id} = 1;

      my $id = $wait_id;

      $http->do_request(
         uri     => $uri,
         method  => 'GET',
         handle  => $S1,

         on_response => sub { $on_resp->( @_ ); delete $wait{$id} },
         on_error    => sub { die "Test failed early - $!" },
      );

      $wait_id++;
   }

   my $request_stream = "";
   my $otherend = IO::Async::Stream->new(
      handle => $S2,

      on_read => sub {
         $request_stream .= ${$_[1]};
         ${$_[1]} = "";
         return 0;
      }
   );

   $loop->add( $otherend );

   while( keys %wait ) {
      # Wait for the client to send its request
      wait_for { $request_stream =~ m/$CRLF$CRLF/ };

      $request_stream =~ s/^(.*)$CRLF//;
      my $req_firstline = $1;

      $request_stream =~ s/^(.*?)$CRLF$CRLF//s;
      my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $1 );

      my $req_content;
      if( defined( my $len = $req_headers{'Content-Length'} ) ) {
         wait_for { length( $request_stream ) >= $len };

         $req_content = substr( $request_stream, 0, $len );
         substr( $request_stream, 0, $len ) = "";
      }

      my $waitcount = keys %wait;

      my $body = "$req_firstline";

      $otherend->write( "HTTP/1.1 200 OK$CRLF" . 
                        "Content-Length: " . length( $body ) . $CRLF .
                        $CRLF .
                        $body );

      # Wait for the server to finish its response
      wait_for { keys %wait < $waitcount };
   }
}

do_uris(
   URI->new( "http://server/path/single" ) => sub {
      my ( $req ) = @_;
      is( $req->content, "GET /path/single HTTP/1.1", 'Single request' );
   },
);

do_uris(
   URI->new( "http://server/path/1" ) => sub {
      my ( $req ) = @_;
      is( $req->content, "GET /path/1 HTTP/1.1", 'First of three pipeline' );
   },
   URI->new( "http://server/path/2" ) => sub {
      my ( $req ) = @_;
      is( $req->content, "GET /path/2 HTTP/1.1", 'Second of three pipeline' );
   },
   URI->new( "http://server/path/3" ) => sub {
      my ( $req ) = @_;
      is( $req->content, "GET /path/3 HTTP/1.1", 'Third of three pipeline' );
   },
);
