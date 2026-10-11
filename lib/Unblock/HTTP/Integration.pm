package Unblock::HTTP::Integration;

use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Unblock::HTTP::Integration - Adapt one event framework to the HTTP family

=head1 TCP AND TLS

For each accepted or connected framework stream, construct one
Unblock::HTTP::Server or Client. Pass the negotiated ALPN protocol to
C<alpn>. If TLS did not negotiate ALPN, leave it undefined and the
connection will use HTTP/1.1. For cleartext HTTP/2 prior knowledge,
select C<protocol =E<gt> 'h2'> explicitly.

    $self->{http} = Unblock::HTTP::Server->new(
        transport  => $self,
        alpn       => $alpn,
        on_request => $on_request,
    );

The stream implements these three methods:

    unblock_send($wire_bytes)
    unblock_finish()
    unblock_abort($reason)

C<unblock_send> must accept the entire buffer or throw an error. True or
undefined means it may accept more output. A defined false return means
it accepted the buffer but is now congested. Call C<resume_output()> on
the HTTP object once the host output queue has room again.

Forward framework input and shutdown events:

    $self->{http}->input($bytes);
    $self->{http}->input_eof;
    $self->{http}->transport_error($error);

The attached engine delivers output automatically, including output from
callbacks invoked long after a read. The framework owns the socket,
TLS, and output queue. The HTTP engine holds the host weakly.

=head1 HTTP/3 AND QUIC

HTTP/3 uses Net::QUIC::Driver instead of the TCP transport contract.
The framework must connect its UDP socket and timer to that Driver; see
L<Unblock::HTTP3::Integration> for this contract.

Once a QUIC connection is ready, create a unified Server or Client:

    my $http = Unblock::HTTP::Server->new(
        quic       => $quic,
        on_request => $on_request,
    );
    $http->start;

Retain C<$http> while the QUIC connection is active. Do not feed UDP
packets to C<input()>; Net::QUIC owns their delivery. HTTP/3 support in
this first layer does not yet replace the Driver integration code.

=head1 LIMITS OF THE FIRST VERSION

There is no TLS/ALPN negotiation, HTTP/1 Upgrade to HTTP/2, automatic
HTTP/2 preface sniffing, DNS, TCP connection establishment, UDP listener,
client connection pool, redirect policy, or automatic protocol fallback.

The selector uses the host's explicit transport negotiation result;
it does not guess based on network bytes. An unknown ALPN value is
rejected rather than silently selecting the wrong protocol.

=head1 LICENSE

MIT License.

=cut
