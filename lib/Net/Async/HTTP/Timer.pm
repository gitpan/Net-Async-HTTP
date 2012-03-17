#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package Net::Async::HTTP::Timer;

use strict;
use warnings;
use base qw( IO::Async::Timer::Countdown );

our $VERSION = '0.17';

# TODO: Make these (or something like them) methods on a real
# IO::Async::Timer::Countdown

sub on_expire
{
   my $self = shift;

   $self->{expired} = 1;
   $self->{on_expire_cb}->() if $self->{on_expire_cb};

   # It may be that the callback already removed us from parent
   $self->parent->remove_child( $self ) if $self->parent;
}

sub expired
{
   my $self = shift;
   return $self->{expired};
}

sub set_on_expire
{
   my $self = shift;
   ( $self->{on_expire_cb} ) = @_;
}

0x55AA;
