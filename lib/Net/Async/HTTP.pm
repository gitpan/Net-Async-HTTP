#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2013 -- leonerd@leonerd.org.uk

package Net::Async::HTTP;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.27_001';

our $DEFAULT_UA = "Perl + " . __PACKAGE__ . "/$VERSION";
our $DEFAULT_MAXREDIR = 3;
our $DEFAULT_MAX_IN_FLIGHT = 4;

use Carp;

use Net::Async::HTTP::Connection;

use HTTP::Request;
use HTTP::Request::Common qw();

use IO::Async::Stream 0.59;
use IO::Async::Loop 0.59; # ->connect( handle ) ==> $stream

use Future::Utils 0.16 qw( repeat );

use Socket qw( SOCK_STREAM IPPROTO_IP IP_TOS );
BEGIN {
   if( $Socket::VERSION >= '2.010' ) {
      Socket->import(qw( IPTOS_LOWDELAY IPTOS_THROUGHPUT IPTOS_RELIABILITY IPTOS_MINCOST ));
   }
   else {
      # These are portable constants, set in RFC 1349
      require constant;
      constant->import({
         IPTOS_LOWDELAY    => 0x10,
         IPTOS_THROUGHPUT  => 0x08,
         IPTOS_RELIABILITY => 0x04,
         IPTOS_MINCOST     => 0x02,
      });
   }
}

use constant HTTP_PORT  => 80;
use constant HTTPS_PORT => 443;

use constant READ_LEN  => 64*1024; # 64 KiB
use constant WRITE_LEN => 64*1024; # 64 KiB

=head1 NAME

C<Net::Async::HTTP> - use HTTP with C<IO::Async>

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::HTTP;
 use URI;

 my $loop = IO::Async::Loop->new();

 my $http = Net::Async::HTTP->new();

 $loop->add( $http );

 $http->do_request(
    uri => URI->new( "http://www.cpan.org/" ),

    on_response => sub {
       my ( $response ) = @_;
       print "Front page of http://www.cpan.org/ is:\n";
       print $response->as_string;
       $loop->loop_stop;
    },

    on_error => sub {
       my ( $message ) = @_;
       print "Cannot fetch http://www.cpan.org/ - $message\n";
       $loop->loop_stop;
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class implements an asynchronous HTTP user agent. It sends
requests to servers, and invokes continuation callbacks when responses are
received. The object supports multiple concurrent connections to servers, and
allows multiple requests in the pipeline to any one connection. Normally, only
one such object will be needed per program to support any number of requests.

This module optionally supports SSL connections, if L<IO::Async::SSL> is
installed. If so, SSL can be requested either by passing a URI with the
C<https> scheme, or by passing a true value as the C<SSL> parameter.

=head2 Connection Pooling

There are three ways in which connections to HTTP server hosts are managed by
this object, controlled by the value of C<max_connections_per_host>. This
controls when new connections are established to servers, as compared to
waiting for existing connections to be free, as new requests are made to them.

They are:

=over 2

=item max_connections_per_host = 1

This is the default setting. In this mode, there will be one connection per
host on which there are active or pending requests. If new requests are made
while an existing one is outstanding, they will be queued to wait for it.

If pipelining is active on the connection (because both the C<pipeline> option
is true and the connection is known to be an HTTP/1.1 server), then requests
will be pipelined into the connection awaiting their response. If not, they
will be queued awaiting a response to the previous before sending the next.

=item max_connections_per_host > 1

In this mode, there can be more than one connection per host. If a new request
is made, it will try to re-use idle connections if there are any, or if they
are all busy it will create a new connection to the host, up to the configured
limit.

=item max_connections_per_host = 0

In this mode, there is no upper limit to the number of connections per host.
Every new request will try to reuse an idle connection, or else create a new
one if all the existing ones are busy.

=back

These modes all apply per hostname / server port pair; they do not affect the
behaviour of connections made to differing hostnames, or differing ports on
the same hostname.

=cut

sub _init
{
   my $self = shift;

   $self->{connections} = {}; # { "$host:$port" } -> [ @connections ]

   $self->{read_len}  = READ_LEN;
   $self->{write_len} = WRITE_LEN;

   $self->{max_connections_per_host} = 1;
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item user_agent => STRING

A string to set in the C<User-Agent> HTTP header. If not supplied, one will
be constructed that declares C<Net::Async::HTTP> and the version number.

=item max_redirects => INT

Optional. How many levels of redirection to follow. If not supplied, will
default to 3. Give 0 to disable redirection entirely.

=item max_in_flight => INT

Optional. The maximum number of in-flight requests to allow per host when
pipelining is enabled and supported on that host. If more requests are made
over this limit they will be queued internally by the object and not sent to
the server until responses are received. If not supplied, will default to 4.
Give 0 to disable the limit entirely.

=item max_connections_per_host => INT

Optional. Controls the maximum number of connections per hostname/server port
pair, before requests will be queued awaiting one to be free. If not supplied,
will default to 1. Give 0 to disable the limit entirely. See also the
L</Connection Pooling> section documented above.

=item timeout => NUM

Optional. How long in seconds to wait before giving up on a request. If not
supplied then no default will be applied, and no timeout will take place.

=item stall_timeout => NUM

Optional. How long in seconds to wait after each successful chunk of data is
read from a socket, before giving up on a request. This may be more useful
than C<timeout> on large-file operations, as it will not time out provided
that regular progress is still being made.

=item proxy_host => STRING

=item proxy_port => INT

Optional. Default values to apply to each C<request> method.

=item cookie_jar => HTTP::Cookies

Optional. A reference to a L<HTTP::Cookies> object. Will be used to set
cookies in requests and store them from responses.

=item pipeline => BOOL

Optional. If false, disables HTTP/1.1-style request pipelining.

=item local_host => STRING

=item local_port => INT

=item local_addrs => ARRAY

=item local_addr => HASH or ARRAY

Optional. Parameters to pass on to the C<connect> method used to connect
sockets to HTTP servers. Sets the local socket address to C<bind()> to. For
more detail, see the documentation in L<IO::Async::Connector>.

=item fail_on_error => BOOL

Optional. Affects the behaviour of response handling when a C<4xx> or C<5xx>
response code is received. When false, these responses will be processed as
other responses and passed to the C<on_response> callback, or used to set the
successful result of the Future. When true, such an error response causes the
C<on_error> handling or a failed Future instead. The HTTP response and request
objects will be passed as well as the code and message.

 $on_error->( "$code $message", $response, $request )

 ( $code_message, $response, $request ) = $f->failure

=item read_len => INT

=item write_len => INT

Optional. Used to set the reading and writing buffer lengths on the underlying
C<IO::Async::Stream> objects that represent connections to the server. If not
define, a default of 64 KiB will be used.

=item ip_tos => INT or STRING

Optional. Used to set the C<IP_TOS> socket option on client sockets. If given,
should either be a C<IPTOS_*> constant, or one of the string names
C<lowdelay>, C<throughput>, C<reliability> or C<mincost>. If undefined or left
absent, no option will be set.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( user_agent max_redirects max_in_flight max_connections_per_host
      timeout stall_timeout proxy_host proxy_port cookie_jar pipeline
      local_host local_port local_addrs local_addr fail_on_error
      read_len write_len ))
   {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   if( exists $params{ip_tos} ) {
      # TODO: This conversion should live in IO::Async somewhere
      my $ip_tos = delete $params{ip_tos};
      $ip_tos = IPTOS_LOWDELAY    if defined $ip_tos and $ip_tos eq "lowdelay";
      $ip_tos = IPTOS_THROUGHPUT  if defined $ip_tos and $ip_tos eq "throughput";
      $ip_tos = IPTOS_RELIABILITY if defined $ip_tos and $ip_tos eq "reliability";
      $ip_tos = IPTOS_MINCOST     if defined $ip_tos and $ip_tos eq "mincost";
      $self->{ip_tos} = $ip_tos;
   }

   $self->SUPER::configure( %params );

   defined $self->{user_agent}    or $self->{user_agent}    = $DEFAULT_UA;
   defined $self->{max_redirects} or $self->{max_redirects} = $DEFAULT_MAXREDIR;
   defined $self->{max_in_flight} or $self->{max_in_flight} = $DEFAULT_MAX_IN_FLIGHT;
   defined $self->{pipeline}      or $self->{pipeline}      = 1;
}

=head1 METHODS

=cut

sub connect_connection
{
   my $self = shift;
   my %args = @_;

   my $conn = delete $args{conn};

   my $host = delete $args{host};
   my $port = delete $args{port};

   my $on_error  = $args{on_error};

   if( $args{SSL} ) {
      require IO::Async::SSL;
      IO::Async::SSL->VERSION( '0.12' ); # 0.12 has ->connect(handle) bugfix

      push @{ $args{extensions} }, "SSL";
   }

   $conn->connect(
      host     => $host,
      service  => $port,
      ( map { defined $self->{$_} ? ( $_ => $self->{$_} ) : () } qw( local_host local_port local_addrs local_addr ) ),

      %args,
   )->on_done( sub {
      my ( $stream ) = @_;
      # Defend against ->setsockopt doing silly things like detecting SvPOK()
      $stream->read_handle->setsockopt( IPPROTO_IP, IP_TOS, $self->{ip_tos}+0 ) if defined $self->{ip_tos};
   })->on_fail( sub {
      $on_error->( $conn, "$host:$port - $_[0] failed [$_[-1]]" );
   });
}

sub get_connection
{
   my $self = shift;
   my %args = @_;

   my $loop = $self->get_loop or croak "Cannot ->get_connection without a Loop";

   my $host = $args{host};
   my $port = $args{port};

   my $key = "$host:$port";
   my $conns = $self->{connections}{$key} ||= [];
   my $ready_queue = $self->{ready_queue}{$key} ||= [];

   my $f = $args{future} || $self->loop->new_future;

   # Have a look to see if there are any idle connected ones first
   foreach my $conn ( @$conns ) {
      $conn->is_idle and $conn->read_handle and return $f->done( $conn );
   }

   push @$ready_queue, $f unless $args{future};

   if( !$self->{max_connections_per_host} or @$conns < $self->{max_connections_per_host} ) {
      my $conn = Net::Async::HTTP::Connection->new(
         notifier_name => "$host:$port",
         max_in_flight => $self->{max_in_flight},
         pipeline      => $self->{pipeline},
         ready_queue   => $ready_queue,
         read_len      => $self->{read_len},
         write_len     => $self->{write_len},

         on_closed => sub {
            my $conn = shift;

            $conn->remove_from_parent;
            @$conns = grep { $_ != $conn } @$conns;
         },
      );

      $self->add_child( $conn );
      push @$conns, $conn;

      $self->connect_connection( %args,
         conn => $conn,
         on_error => sub {
            my $conn = shift;

            $f->fail( @_ );

            @$conns = grep { $_ != $conn } @$conns;
            @$ready_queue = grep { $_ != $f } @$ready_queue;

            if( @$ready_queue ) {
               # Requeue another connection attempt as there's still more to do
               $self->get_connection( %args, future => $ready_queue->[0] );
            }
         },
      );
   }

   return $f;
}

=head2 $http->do_request( %args )

Send an HTTP request to a server, and set up the callbacks to receive a reply.
The request may be represented by an L<HTTP::Request> object, or a L<URI>
object, depending on the arguments passed.

The following named arguments are used for C<HTTP::Request>s:

=over 8

=item request => HTTP::Request

A reference to an C<HTTP::Request> object

=item host => STRING

Hostname of the server to connect to

=item port => INT or STRING

Optional. Port number or service of the server to connect to. If not defined,
will default to C<http> or C<https> depending on whether SSL is being used.

=item SSL => BOOL

Optional. If true, an SSL connection will be used.

=back

The following named arguments are used for C<URI> requests:

=over 8

=item uri => URI

A reference to a C<URI> object. If the scheme is C<https> then an SSL
connection will be used.

=item method => STRING

Optional. The HTTP method. If missing, C<GET> is used.

=item content => STRING or ARRAY ref

Optional. The body content to use for C<POST> requests. If this is a plain
scalar instead of an ARRAY ref, it will not be form encoded. In this case, a
C<content_type> field must also be supplied to describe it.

=item request_body => CODE or STRING

Optional. Allows request body content to be generated by a callback, rather
than being provided as part of the C<request> object. This can either be a
C<CODE> reference to a generator function, or a plain string.

As this is passed to the underlying L<IO::Async::Stream> C<write> method, the
usual semantics apply here. If passed a C<CODE> reference, it will be called
repeatedly whenever it's safe to write. The code should should return C<undef>
to indicate completion.

As with the C<content> parameter, the C<content_type> field should be
specified explicitly in the request header, as should the content length
(typically via the L<HTTP::Request> C<content_length> method). See also
F<examples/PUT.pl>.

=item content_type => STRING

The type of non-form data C<content>.

=item expect_continue => BOOL

Optional. If true, sets the C<Expect> request header to the value
C<100-continue> and does not send the C<request_body> parameter until a
C<100 Continue> response is received from the server. If an error response is
received then the C<request_body> code, if present, will not be invoked.

=item user => STRING

=item pass => STRING

Optional. If both are given, the HTTP Basic Authorization header will be sent
with these details.

=item proxy_host => STRING

=item proxy_port => INT

Optional. Override the hostname or port number implied by the URI.

=back

For either request type, it takes the following continuation callbacks:

=over 8

=item on_response => CODE

A callback that is invoked when a response to this request has been received.
It will be passed an L<HTTP::Response> object containing the response the
server sent.

 $on_response->( $response )

=item on_header => CODE

Alternative to C<on_response>. A callback that is invoked when the header of a
response has been received. It is expected to return a C<CODE> reference for
handling chunks of body content. This C<CODE> reference will be invoked with
no arguments once the end of the request has been reached.

 $on_body_chunk = $on_header->( $header )

    $on_body_chunk->( $data )
    $on_body_chunk->()

=item on_error => CODE

A callback that is invoked if an error occurs while trying to send the request
or obtain the response. It will be passed an error message.

 $on_error->( $message )

If this is invoked because of a received C<4xx> or C<5xx> error code in an
HTTP response, it will be invoked with the response and request objects as
well.

 $on_error->( $message, $response, $request )

=item on_redirect => CODE

Optional. A callback that is invoked if a redirect response is received,
before the new location is fetched. It will be passed the response and the new
URL.

 $on_redirect->( $response, $location )

=item max_redirects => INT

Optional. How many levels of redirection to follow. If not supplied, will
default to the value given in the constructor.

=item timeout => NUM

=item stall_timeout => NUM

Optional. Overrides the object's configured timeout values for this one
request. If not specified, will use the configured defaults.

=back

=head2 $future = $http->do_request( %args )

This method also returns a L<Future>, which will eventually yield the (final
non-redirect) C<HTTP::Response>. If returning a future, then the
C<on_response>, C<on_header> and C<on_error> callbacks are optional.

=cut

sub _do_one_request
{
   my $self = shift;
   my %args = @_;

   my $host    = delete $args{host};
   my $port    = delete $args{port};
   my $request = delete $args{request};

   my $stall_timeout = $args{stall_timeout} // $self->{stall_timeout};

   $self->prepare_request( $request );

   return $self->get_connection(
      host => $args{proxy_host} || $self->{proxy_host} || $host,
      port => $args{proxy_port} || $self->{proxy_port} || $port,
      SSL  => $args{SSL},
      ( map { m/^SSL_/ ? ( $_ => $args{$_} ) : () } keys %args ),
   )->then( sub {
      my ( $conn ) = @_;

      return $conn->request(
         request => $request,
         stall_timeout => $stall_timeout,
         %args,
      );
   } );
}

sub _do_request
{
   my $self = shift;
   my %args = @_;

   my $host = $args{host};
   my $port = $args{port};
   my $ssl  = $args{SSL};

   my $on_header = delete $args{on_header};

   my $redirects = defined $args{max_redirects} ? $args{max_redirects} : $self->{max_redirects};

   my $request = $args{request};
   my $response;
   my $reqf;
   # Defeat prototype
   my $future = &repeat( $self->_capture_weakself( sub {
      my $self = shift;
      my ( $previous_f ) = @_;

      if( $previous_f ) {
         my $previous_response = $previous_f->get;
         $args{previous_response} = $previous_response;

         my $location = $previous_response->header( "Location" );

         if( $location =~ m{^http(?:s?)://} ) {
            # skip
         }
         elsif( $location =~ m{^/} ) {
            my $hostport = ( $port != HTTP_PORT ) ? "$host:$port" : $host;
            $location = "http://$hostport" . $location;
         }
         else {
            return $self->loop->new_future->fail( "Unrecognised Location: $location" );
         }

         my $loc_uri = URI->new( $location );
         unless( $loc_uri ) {
            return $self->loop->new_future->fail( "Unable to parse '$location' as a URI" );
         }

         $args{on_redirect}->( $previous_response, $location ) if $args{on_redirect};

         %args = $self->_make_request_for_uri( $loc_uri, %args );
      }

      my $uri = $request->uri;
      if( defined $uri->scheme and $uri->scheme =~ m/^http(s?)$/ ) {
         $host = $uri->host if !defined $host;
         $port = $uri->port if !defined $port;
         $ssl = ( $uri->scheme eq "https" );
      }

      defined $host or croak "Expected 'host'";
      defined $port or $port = ( $ssl ? HTTPS_PORT : HTTP_PORT );

      return $reqf = $self->_do_one_request(
         host => $host,
         port => $port,
         SSL  => $ssl,
         %args,
         on_header => $self->_capture_weakself( sub {
            my $self = shift;
            ( $response ) = @_;

            return $on_header->( $response ) unless $response->is_redirect;

            # Consume and discard the entire body of a redirect
            return sub {
               return if @_;
               return $response;
            };
         } ),
      );
   } ),
   while => sub {
      my $f = shift;
      return 0 if $f->failure or $f->is_cancelled;
      return $response->is_redirect && $redirects--;
   } );

   if( $self->{fail_on_error} ) {
      $future = $future->and_then( sub {
         my $f = shift;
         my $resp = $f->get;
         my $code = $resp->code;

         if( $code =~ m/^[45]/ ) {
            my $message = $resp->message;
            $message =~ s/\r$//; # HTTP::Message bug

            return Future->new->fail( "$code $message", $resp, $request );
         }

         return $resp;
      });
   }

   return $future;
}

sub do_request
{
   my $self = shift;
   my %args = @_;

   if( my $uri = delete $args{uri} ) {
      %args = $self->_make_request_for_uri( $uri, %args );
   }

   if( $args{on_header} ) {
      # ok
   }
   elsif( my $on_response = delete $args{on_response} or defined wantarray ) {
      $args{on_header} = sub {
         my ( $response ) = @_;
         return sub {
            if( @_ ) {
               $response->add_content( @_ );
            }
            else {
               $on_response->( $response ) if $on_response;
               return $response;
            }
         };
      }
   }
   else {
      croak "Expected 'on_response' or 'on_header' as CODE ref or to return a Future";
   }

   my $timeout = defined $args{timeout} ? $args{timeout} : $self->{timeout};

   my $future = $self->_do_request( %args );

   if( defined $timeout ) {
      $future = Future->wait_any(
         $future,
         $self->loop->timeout_future( after => $timeout )
                    ->transform( fail => sub { "Timed out" } ),
      );
   }

   $future->on_done( $self->_capture_weakself( sub {
      my $self = shift;
      my $response = shift;
      $self->process_response( $response );
   } ) );

   $future->on_fail( $args{on_error} ) if $args{on_error};

   # DODGY HACK:
   # In void context we'll lose reference on the ->wait_any Future, so the
   # timeout logic will never happen. So lets purposely create a cycle by
   # capturing the $future in on_done/on_fail closures within itself. This
   # conveniently clears them out to drop the ref when done.
   if( !defined wantarray and $args{on_header} || $args{on_response} || $args{on_error} ) {
      $future->on_done( sub { undef $future } );
      $future->on_fail( sub { undef $future } );
   }

   return $future;
}

sub _make_request_for_uri
{
   my $self = shift;
   my ( $uri, %args ) = @_;

   ref $uri and $uri->isa( "URI" ) or croak "Expected 'uri' as a URI reference";

   my $method = delete $args{method} || "GET";

   $args{host} = $uri->host;
   $args{port} = $uri->port;

   my $request;

   if( $method eq "POST" ) {
      defined $args{content} or croak "Expected 'content' with POST method";

      # Lack of content_type didn't used to be a failure condition:
      ref $args{content} or defined $args{content_type} or
      carp "No 'content_type' was given with 'content'";

      # This will automatically encode a form for us
      $request = HTTP::Request::Common::POST( $uri, Content => $args{content}, Content_Type => $args{content_type} );
   }
   else {
      $request = HTTP::Request->new( $method, $uri );
   }

   $request->protocol( "HTTP/1.1" );
   $request->header( Host => $uri->host );

   my ( $user, $pass );

   if( defined $uri->userinfo ) {
      ( $user, $pass ) = split( m/:/, $uri->userinfo, 2 );
   }
   elsif( defined $args{user} and defined $args{pass} ) {
      $user = $args{user};
      $pass = $args{pass};
   }

   if( defined $user and defined $pass ) {
      $request->authorization_basic( $user, $pass );
   }

   $args{request} = $request;

   return %args;
}

=head2 $future = $http->GET( $uri, %args )

=head2 $future = $http->HEAD( $uri, %args )

Convenient wrappers for using the C<GET> or C<HEAD> methods with a C<URI>
object and few if any other arguments, returning a C<Future>.

=cut

sub GET
{
   my $self = shift;
   return $self->do_request( method => "GET", uri => @_ );
}

sub HEAD
{
   my $self = shift;
   return $self->do_request( method => "HEAD", uri => @_ );
}

=head1 SUBCLASS METHODS

The following methods are intended as points for subclasses to override, to
add extra functionallity.

=cut

=head2 $http->prepare_request( $request )

Called just before the C<HTTP::Request> object is sent to the server.

=cut

sub prepare_request
{
   my $self = shift;
   my ( $request ) = @_;

   $request->init_header( 'User-Agent' => $self->{user_agent} ) if length $self->{user_agent};
   $request->init_header( "Connection" => "keep-alive" );

   $self->{cookie_jar}->add_cookie_header( $request ) if $self->{cookie_jar};
}

=head2 $http->process_response( $response )

Called after a non-redirect C<HTTP::Response> has been received from a server.
The originating request will be set in the object.

=cut

sub process_response
{
   my $self = shift;
   my ( $response ) = @_;

   $self->{cookie_jar}->extract_cookies( $response ) if $self->{cookie_jar};
}

=head1 EXAMPLES

=head2 Concurrent GET

The C<Future>-returning C<GET> method makes it easy to await multiple URLs at
once, by using the L<Future::Utils> C<fmap_void> utility 

 my @URLs = ( ... );

 my $http = Net::Async::HTTP->new( ... );
 $loop->add( $http );

 my $future = fmap_void {
    my ( $url ) = @_;
    $http->GET( $url )
         ->on_done( sub {
            my $response = shift;
            say "$url succeeded: ", $response->code;
            say "  Content-Type":", $response->content_type;
         } )
         ->on_fail( sub {
            my $failure = shift;
            say "$url failed: $failure";
         } );
 } foreach => \@URLs;

 $loop->await( $future );

=cut

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ietf.org/html/rfc2616> - Hypertext Transfer Protocol -- HTTP/1.1

=back

=head1 SPONSORS

Parts of this code were paid for by

=over 2

=item *

Socialflow L<http://www.socialflow.com>

=item *

Shadowcat Systems L<http://www.shadow.cat>

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
