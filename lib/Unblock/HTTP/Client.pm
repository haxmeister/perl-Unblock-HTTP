package Unblock::HTTP::Client;

use strict;
use warnings;
use parent 'Unblock::HTTP::_Session';

our $VERSION = '0.01';

sub new {
    my ($class, %option) = @_;
    return $class->_new('Client', %option);
}

sub request {
    my ($self, @arg) = @_;
    return $self->{backend}->request(@arg);
}

1;

__END__

=head1 NAME

Unblock::HTTP::Client - One HTTP client connection using the selected protocol

=head1 SYNOPSIS

    use Unblock::HTTP::Client;

    my $client = Unblock::HTTP::Client->new(
        transport => $stream,
        alpn      => $negotiated_alpn,
    );

    $client->request(
        method    => 'GET',
        target    => '/',
        authority => 'example.test',
        on_response => sub {
            my ($tx, $response) = @_;
            print $response->status, "\n";
        },
    );

=head1 DESCRIPTION

Each Client represents one HTTP connection. It forwards requests to the
chosen engine and returns that engine's Transaction. Transactions use the
same request(), respond(), write(), and end() vocabulary across protocols.

=head1 CONSTRUCTOR

=head2 new

Accepts C<protocol> (C<http/1.1>, C<h2>, or C<h3>) or
C<alpn> (the value negotiated by the host TLS layer), plus the selected
engine's constructor options. Do not specify both C<protocol> and C<alpn>.

With a byte transport, omitted or empty ALPN selects HTTP/1.1. With C<quic>,
omitting protocol selects HTTP/3. HTTP/3 requires C<quic>, and HTTP/1/2
must not be given a QUIC connection.

A byte transport implements C<unblock_send()>, C<unblock_finish()>, and
C<unblock_abort()> as described in L<Unblock::HTTP::Integration>.

=head1 METHODS

=head2 request

Accepts named fields or a Uniform::HTTP::Request object, plus standard
request callbacks. Returns the underlying engine's Transaction without
adding a wrapper to each request.

=head2 input, input_eof, transport_error, resume_output

Forward TCP/TLS input and transport events to the selected HTTP/1 or
HTTP/2 engine. These are not HTTP/3 methods.

=head2 output, want_read, want_write, close

Portable low-level TCP engine operations. Use an attached transport for
normal integrations rather than manually draining output.

=head2 start, started

For HTTP/3, call C<start()> only when the QUIC connection is ready.
For HTTP/1 and HTTP/2, C<start()> is a no-op and C<started()> is true.

=head2 protocol, backend

C<protocol()> returns the selected protocol. C<backend()> returns the exact
underlying engine for advanced protocol-specific operations.

=head1 LICENSE

MIT License.

=cut
