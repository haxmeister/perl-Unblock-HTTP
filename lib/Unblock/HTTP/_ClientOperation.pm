package Unblock::HTTP::_ClientOperation;

use strict;
use warnings;
use Scalar::Util qw(weaken);

sub new {
    my ($class, $client, $request, $callbacks, $version, $origin) = @_;
    my $self = bless {
        client      => $client,
        request     => $request,
        callbacks   => $callbacks,
        version     => $version,
        origin      => $origin,
        state       => 'queued',
        error       => undef,
        transaction => undef,
    }, $class;
    weaken($self->{client});
    return $self;
}

sub state       { $_[0]{state} }
sub error       { $_[0]{error} }
sub transaction { $_[0]{transaction} }
sub is_terminal { $_[0]{state} =~ /\A(?:complete|error|cancelled)\z/ ? 1 : 0 }

sub cancel {
    my ($self) = @_;
    return 0 if $self->is_terminal;
    if (my $tx = $self->{transaction}) {
        $tx->cancel;
        return 1;
    }
    $self->{state} = 'cancelled';
    my $client = $self->{client};
    $client->_cancel_queued($self) if $client;
    return 1;
}

1;

__END__

=head1 NAME

Unblock::HTTP::_ClientOperation - A pending outgoing HTTP request

=head1 DESCRIPTION

A Client request returns this handle immediately, including before its
transport has connected. C<transaction()> becomes the actual engine
Transaction once the request is issued, without an HTTP transaction wrapper.

C<state()> is queued, connecting, active, complete, error, or cancelled.
C<error()> reports a connection or transaction error, if any.
C<is_terminal()> and C<cancel()> work before and after dispatch.

Cancellation before dispatch never creates an engine Transaction. In that
case C<on_finish> is called with the operation handle, not a made-up
Transaction. After dispatch all application transaction callbacks receive
the actual engine Transaction.

=cut
