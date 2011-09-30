#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2011 -- leonerd@leonerd.org.uk

package Net::Async::HTTP;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.12';

our $DEFAULT_UA = "Perl + " . __PACKAGE__ . "/$VERSION";
our $DEFAULT_MAXREDIR = 3;

use Carp;

use Net::Async::HTTP::Protocol;

use HTTP::Request;
use HTTP::Request::Common qw();

use IO::Async::Stream;
use IO::Async::Loop 0.31; # for ->connect( extensions )

use Socket qw( SOCK_STREAM );

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
allows multiple outstanding requests in pipeline to any one connection.
Normally, only one such object will be needed per program to support any
number of requests.

This module optionally supports SSL connections, if L<IO::Async::SSL> is
installed. If so, SSL can be requested either by passing a URI with the
C<https> scheme, or by passing the a true value as the C<SSL> parameter.

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $loop = delete $args{loop};

   my $self = $class->SUPER::new( %args );

   $loop->add( $self ) if $loop;

   return $self;
}

sub _init
{
   my $self = shift;

   $self->{connections} = {}; # { "$host:$port" } -> $conn
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

=item proxy_host => STRING

=item proxy_port => INT

Optional. Default values to apply to each C<request> method.

=item cookie_jar => HTTP::Cookies

Optional. A reference to a L<HTTP::Cookies> object. Will be used to set
cookies in requests and store them from responses.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( user_agent max_redirects proxy_host proxy_port cookie_jar )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );

   defined $self->{user_agent}    or $self->{user_agent} = $DEFAULT_UA;
   defined $self->{max_redirects} or $self->{max_redirects} = $DEFAULT_MAXREDIR;
}

=head1 METHODS

=cut

sub get_connection
{
   my $self = shift;
   my %args = @_;

   my $on_ready = delete $args{on_ready} or croak "Expected 'on_ready' as a CODE ref";
   my $on_error = delete $args{on_error} or croak "Expected 'on_error' as a CODE ref";

   my $loop = $self->get_loop or croak "Cannot ->get_connection without a Loop";

   my $host = delete $args{host};
   my $port = delete $args{port};

   my $connections = $self->{connections};

   if( my $conn = $connections->{"$host:$port"} ) {
      $conn->run_when_ready( $on_ready );
      return;
   }

   my $conn = Net::Async::HTTP::Protocol->new(
      on_closed => sub {
         delete $connections->{"$host:$port"};
      },
   );
   $self->add_child( $conn );

   $connections->{"$host:$port"} = $conn;

   if( $args{SSL} ) {
      require IO::Async::SSL;
      IO::Async::SSL->VERSION( 0.04 );

      push @{ $args{extensions} }, "SSL";

      $args{on_ssl_error} = sub {
         $on_error->( "$host:$port SSL error [$_[0]]" );
      };
   }

   $conn->connect(
      host     => $host,
      service  => $port,

      on_resolve_error => sub {
         $on_error->( "$host:$port not resolvable [$_[0]]" );
      },

      on_connect_error => sub {
         $on_error->( "$host:$port not contactable" );
      },

      %args,
   );

   $conn->run_when_ready( $on_ready );
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

=item port => INT

Hostname and port number of the server to connect to

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

=item on_redirect => CODE

Optional. A callback that is invoked if a redirect response is received,
before the new location is fetched. It will be passed the response and the new
URL.

 $on_redirect->( $response, $location )

=item max_redirects => INT

Optional. How many levels of redirection to follow. If not supplied, will
default to the value given in the constructor.

=back

=cut

sub do_request
{
   my $self = shift;
   my %args = @_;

   my $on_response  = $args{on_response} or
      my $on_header = $args{on_header}   or croak "Expected 'on_response' or 'on_header' as CODE ref";
   my $on_error     = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";
   my $request_body = $args{request_body};

   my $max_redirects = defined $args{max_redirects} ? $args{max_redirects} : $self->{max_redirects};

   my $host;
   my $port;
   my $ssl;

   my $request;

   my $on_header_redir = sub {
      my ( $response ) = @_;

      if( !$response->is_redirect or $max_redirects == 0 ) {
         $response->request( $request );
         $self->process_response( $response );

         return $on_header->( $response ) if $on_header;
         return sub {
            return $on_response->( $response ) unless @_;

            $response->add_content( @_ );
         };
      }

      # Ignore body but handle redirect at the end of it
      return sub {
         return if @_;

         my $location = $response->header( "Location" );

         if( $location =~ m{^http://} ) {
            # skip
         }
         elsif( $location =~ m{^/} ) {
            my $hostport = ( $port != URI::http->default_port ) ? "$host:$port" : $host;
            $location = "http://$hostport" . $location;
         }
         else {
            $on_error->( "Unrecognised Location: $location" );
            return;
         }

         my $loc_uri = URI->new( $location );
         unless( $loc_uri ) {
            $on_error->( "Unable to parse '$location' as a URI" );
            return;
         }

         $args{on_redirect}->( $response, $location ) if $args{on_redirect};

         $self->do_request(
            %args,
            uri => $loc_uri,
            max_redirects => $max_redirects - 1,
         );
      }
   };

   if( $args{request} ) {
      $request = delete $args{request};
      ref $request and $request->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";
      $ssl = $args{SSL};
   }
   elsif( $args{uri} ) {
      my $uri = delete $args{uri};
      ref $uri and $uri->isa( "URI" ) or croak "Expected 'uri' as a URI reference";

      my $method = delete $args{method} || "GET";

      $host = $uri->host;
      $port = $uri->port;
      my $path = $uri->path_query;

      $ssl = ( $uri->scheme eq "https" );

      $path = "/" if $path eq "";

      if( $method eq "POST" ) {
         defined $args{content} or croak "Expected 'content' with POST method";

         # Lack of content_type didn't used to be a failure condition:
         ref $args{content} or defined $args{content_type} or
            carp "No 'content_type' was given with 'content'";

         # This will automatically encode a form for us
         $request = HTTP::Request::Common::POST( $path, Content => $args{content}, Content_Type => $args{content_type} );
      }
      else {
         $request = HTTP::Request->new( $method, $path );
      }

      $request->protocol( "HTTP/1.1" );
      $request->header( Host => $host );

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
   }

   $self->prepare_request( $request );

   if( my $handle = $args{handle} ) { # INTERNAL UNDOCUMENTED
      my $transport = IO::Async::Stream->new( handle => $handle );

      $self->get_connection(
         transport => $transport,

         # To make the connection cache logic happy
         host => "[[local_io_handle]]",
         port => $handle->fileno,

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            $conn->request(
               request => $request,
               request_body => $request_body,
               on_header => $on_header_redir,
               on_error  => $on_error,
            );
         },
      );
   }
   else {
      if( !defined $host ) {
         $host = delete $args{host} or croak "Expected 'host'";
      }

      if( !defined $port ) {
         $port = delete $args{port} or croak "Expected 'port'";
      }

      $self->get_connection(
         host => $args{proxy_host} || $self->{proxy_host} || $host,
         port => $args{proxy_port} || $self->{proxy_port} || $port,
         SSL  => $ssl,

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            $conn->request(
               request => $request,
               request_body => $request_body,
               on_header => $on_header_redir,
               on_error  => $on_error,
            );
         },
      );
   }
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

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ietf.org/html/rfc2616> - Hypertext Transfer Protocol -- HTTP/1.1

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
