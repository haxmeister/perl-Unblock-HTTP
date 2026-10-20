package Unblock::HTTP::Adapter::LinuxEvent;

use v5.36;
use strict;
use warnings;
use parent 'Linux::Event::IO::Sock::Stream';
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub http { $_[0]{unblock_http} }
sub websocket { $_[0]{unblock_websocket} }

# Override this in a subclass for a cleartext HTTP/2 prior-knowledge port.
# For TLS, the adapter uses the ALPN chosen by Linux::Event instead.
sub http_protocol { undef }

sub http_server ($self) {
    die "http_server() must return a shared Unblock::HTTP::Server definition\n";
}

sub on_ready ($self) {
    my $server = $self->http_server;
    die "http_server() must return a shared Unblock::HTTP::Server definition\n"
        unless blessed($server) && $server->isa('Unblock::HTTP::Server');
    my $protocol = $self->http_protocol;
    my %select = defined($protocol)
        ? (protocol => $protocol)
        : (alpn => $self->selected_alpn);
    $self->{unblock_http} = $server->attach_stream(
        transport => $self, %select,
    );
    return;
}

sub unblock_upgrade ($self, $websocket) {
    die "unblock_upgrade(): WebSocket input consumer is required\n"
        unless blessed($websocket) && $websocket->can('input')
            && $websocket->can('input_eof') && $websocket->can('transport_error')
            && $websocket->can('resume_output');
    die "unblock_upgrade(): transport already upgraded\n"
        if $self->{unblock_websocket};
    $self->{unblock_websocket} = $websocket;
    return;
}

sub _consumer ($self) {
    return $self->{unblock_websocket} || $self->{unblock_http};
}

sub on_data ($self, $bytes) {
    $self->_consumer->input($bytes);
}

sub on_eof ($self) {
    my $consumer = $self->_consumer;
    $consumer->input_eof if $consumer && $consumer->want_read;
}

sub on_error ($self, $error) {
    my $consumer = $self->_consumer;
    $consumer->transport_error("$error") if $consumer;
}

sub on_drain ($self) {
    my $consumer = $self->_consumer;
    $consumer->resume_output if $consumer;
}

sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die "Linux::Event stream closed during HTTP output\n" if $self->is_closed;
    return $ready;
}

sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

1;

__END__

=head1 NAME

Unblock::HTTP::Adapter::LinuxEvent - Attach Linux::Event streams to a shared Server

=head1 DESCRIPTION

This optional Stream subclass forwards input directly to the real HTTP engine.
Override C<http_server()> to return one shared L<Unblock::HTTP::Server> definition.
See examples/linux-event-server.pl for a complete program separating application
behavior from adapter code.

C<http()> returns the original attached HTTP engine. C<websocket()> returns
an established WebSocket engine after a successful HTTP1 upgrade (or undef
beforehand). C<on_data>, C<on_eof>, C<on_error>, and C<on_drain> deliver
transport events to the current protocol consumer.
C<unblock_send>, C<unblock_finish>, and C<unblock_abort> map engine output to
the Stream's existing queue and shutdown operations.

When the Server enables C<http1 =E<gt> { websocket =E<gt> 1 }>, this
adapter supplies the required C<unblock_upgrade($websocket)> hook.
It switches the receive consumer after the HTTP1 engine accepts the 101
response into the existing write queue. No new stream or socket is created.
The HTTP1 engine's buffered C<take_remainder()> bytes are delivered by the
Server transition callback; future data, EOF, errors, and output resumes go
to the WebSocket engine. This adapter uses ordinary Perl C<input()>; a
separate NativeABI consumer must still transfer its unconsumed borrowed tail
at C<INPUT_SWITCH> using the reported consumed-byte count.

TLS uses C<selected_alpn> after readiness. Configure the listener's TLS ALPN
choices from the Server's C<alpn_protocols> list. Plaintext defaults to HTTP/1.1
when enabled. Override C<http_protocol()> to return C<h2> for a cleartext
prior-knowledge listener.

This is still the server adapter. A shared client/server transport factory
is planned separately. It needs Perl 5.36 and Linux::Event 0.117 or newer;
normal framework-neutral use does not load this module.

=head1 LICENSE

MIT License.

=cut
