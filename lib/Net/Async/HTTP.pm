#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2010 -- leonerd@leonerd.org.uk

package Net::Async::HTTP;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.06';

our $DEFAULT_UA = "Perl + " . __PACKAGE__ . "/$VERSION";
our $DEFAULT_MAXREDIR = 3;

use Carp;

use Net::Async::HTTP::Client;

use HTTP::Request;
use HTTP::Request::Common qw();

use Socket qw( SOCK_STREAM );

=head1 NAME

C<Net::Async::HTTP> - Asynchronous HTTP user agent

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

   $self->{connections} = {}; # { "$host:$port" } -> [ $conn, @pending_onread ]
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

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( user_agent max_redirects )) {
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

   my $on_ready = $args{on_ready} or croak "Expected 'on_ready' as a CODE ref";
   my $on_error = $args{on_error} or croak "Expected 'on_error' as a CODE ref";

   my $loop = $self->get_loop or croak "Cannot ->get_connection without a Loop";

   my $host = $args{host};
   my $port = $args{port};

   if( my $cr = $self->{connections}->{"$host:$port"} ) {
      my ( $conn ) = @$cr;

      my $on_read = $on_ready->( $conn );
      push @$cr, $on_read;

      return;
   }

   if( $args{handle} ) {
      my $on_read;

      my $cr;

      my $conn = Net::Async::HTTP::Client->new(
         handle => $args{handle},

         on_closed => sub {
            delete $self->{connections}->{"$host:$port"};
         },
      );

      $cr = $self->{connections}->{"$host:$port"} = [ $conn ];

      $self->add_child( $conn );

      $on_read = $on_ready->( $conn );

      return;
   }

   $loop->connect(
      host     => $host,
      service  => $port,
      socktype => SOCK_STREAM,

      on_resolve_error => sub {
         $on_error->( "$host:$port not resolvable [$_[0]]" );
      },

      on_connect_error => sub {
         $on_error->( "$host:$port not contactable" );
      },

      on_connected => sub {
         my ( $sock ) = @_;
         $self->get_connection( %args, handle => $sock );
      },
   );
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

=back

The following named arguments are used for C<URI> requests:

=over 8

=item uri => URI

A reference to a C<URI> object

=item method => STRING

Optional. The HTTP method. If missing, C<GET> is used.

=item content => STRING or ARRAY ref

Optional. The body content to use for C<POST> requests. If this is a plain
scalar instead of an ARRAY ref, it will not be form encoded. In this case, a
C<content_type> field must also be supplied to describe it.

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

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";

   my $max_redirects = defined $args{max_redirects} ? $args{max_redirects} : $self->{max_redirects};

   my $host;
   my $port;

   # Now build a new on_response continuation that has all the redirect logic
   my $on_resp_redir = sub {
      my ( $response ) = @_;

      if( $response->is_redirect and $max_redirects > 0 ) {
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
      else {
         $on_response->( $response );
      }
   };

   my $request;

   if( $args{request} ) {
      $request = delete $args{request};
      ref $request and $request->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";
   }
   elsif( $args{uri} ) {
      my $uri = delete $args{uri};
      ref $uri and $uri->isa( "URI" ) or croak "Expected 'uri' as a URI reference";

      my $method = delete $args{method} || "GET";

      $host = $uri->host;
      $port = $uri->port;
      my $path = $uri->path_query;

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

   $request->init_header( 'User-Agent' => $self->{user_agent} ) if length $self->{user_agent};

   if( my $handle = $args{handle} ) { # INTERNAL UNDOCUMENTED
      $self->get_connection(
         handle => $handle,

         # To make the connection cache logic happy
         host => "[[local_io_handle]]",
         port => $handle->fileno,

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            $conn->request(
               request => $request,
               on_response => $on_resp_redir,
               on_error    => $on_error,
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
         host => $args{proxy_host} || $host,
         port => $args{proxy_port} || $port,

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            $conn->request(
               request => $request,
               on_response => $on_resp_redir,
               on_error    => $on_error,
            );
         },
      );
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ietf.org/html/rfc2616> - Hypertext Transfer Protocol -- HTTP/1.1

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
