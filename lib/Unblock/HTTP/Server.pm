package Unblock::HTTP::Server;

use strict;
use warnings;
use parent 'Unblock::HTTP::_Session';

our $VERSION = '0.01';

sub new {
    my ($class, %option) = @_;
    return $class->_new('Server', %option);
}

1;

__END__

=head1 NAME

Unblock::HTTP::Server - One HTTP server connection using the selected protocol

=head1 SYNOPSIS

    use Unblock::HTTP::Server;

    my $server = Unblock::HTTP::Server->new(
        transport  => $stream,
        alpn       => $negotiated_alpn,
        on_request => sub {
            my ($tx, $request) = @_;
            $tx->respond(status => 200, body => "hello\n");
        },
    );

=head1 DESCRIPTION

Construct one Server per incoming TCP connection or QUIC connection.
Unblock::HTTP selects the protocol engine but does not own a listener,
socket, TLS state, or QUIC Driver. The application callbacks use the same
Transaction and Uniform::HTTP message contracts for every protocol.

=head1 CONSTRUCTOR

=head2 new

Accepts C<alpn> or C<protocol> to select the engine and passes other
constructor options, including C<on_request>, to that engine. C<quic>
selects HTTP/3 when neither selector is supplied. Otherwise the default
is HTTP/1.1. See L<Unblock::HTTP::Client> for selector rules.

=head1 METHODS

=head2 input, input_eof, transport_error, resume_output

Forward TCP/TLS transport events to the engine. Not valid for HTTP/3.

=head2 start, started

Start HTTP/3 after QUIC becomes ready. For HTTP/1 and HTTP/2, start is a
no-op and started is true.

=head2 protocol, backend

The selected protocol name and the underlying engine object. The backend
exposes protocol-specific controls and returns its own Transaction objects.

=head1 LICENSE

MIT License.

=cut
