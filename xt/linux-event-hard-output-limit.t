use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

# Fatal max_pending_bytes is different from cooperative write() == false.
# The output-limit error means a write was NOT fully accepted. Once the
# socket fails, the native HTTP engine must report a terminal error,
# never retry the rejected output or invoke its producer's on_drain.
my $cap = 4096;
my $response = '0123456789ABCDEF' x 131072;  # Bounded 2 MiB
our ($LOOP, $SERVER, $PROTOCOL, $SERVER_SOCKET, $CLIENT_SOCKET, $WATCHDOG);
our ($SOCKET_ERROR, $SERVER_ERROR, $SERVER_TERMINALS, $SERVER_COMPLETE,
     $CLIENT_TERMINALS, $CLIENT_COMPLETE, $DRAINS, $REQUESTS,
     $REJECTED_SENDS, $TIMED_OUT, $SEND_EXCEPTION);

package HardLimitServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }
sub socket_options ($class) { (send_buffer => 8192) }
sub stream_tuning ($class) {
    return (
        high_watermark => 1024,
        low_watermark => 256,
        max_pending_bytes => 4096,
    );
}
sub on_ready ($self) {
    $main::SERVER_SOCKET = $self;
    $self->SUPER::on_ready;
}
sub unblock_send ($self, $bytes) {
    my $result = eval { $self->SUPER::unblock_send($bytes) };
    if ($@) {
        $main::SEND_EXCEPTION = "$@";
        $main::REJECTED_SENDS++;
        die $@;
    }
    return $result;
}
sub on_drain ($self) {
    $main::DRAINS++;
    $self->SUPER::on_drain;
}
sub on_error ($self, $error) {
    $main::SOCKET_ERROR //= $error;
    $self->SUPER::on_error($error);
    $main::LOOP->defer(sub { $main::LOOP->stop });
}

package HardLimitClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{http_ready}
        or die 'missing HTTP Client connection callback';
    $self->{http} = $ready->(transport => $self, alpn => $main::PROTOCOL);
    $self->pause_read;
}
sub on_data ($self, $bytes) { $self->{http}->input($bytes) }
sub on_eof ($self) {
    $self->{http}->input_eof
        if $self->{http} && $self->{http}->want_read;
}
sub on_error ($self, $error) {
    $self->{http}->transport_error("$error") if $self->{http};
}
sub on_drain ($self) { $self->{http}->resume_output if $self->{http} }
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'client transport closed during output' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
is(length($response), 2 * 1024 * 1024, 'hard-limit fixture is only two MiB');

for my $protocol ('http/1.1', 'h2') {
    ($LOOP, $PROTOCOL, $SERVER_SOCKET, $CLIENT_SOCKET, $WATCHDOG,
     $SOCKET_ERROR, $SERVER_ERROR, $SERVER_TERMINALS,
     $SERVER_COMPLETE, $CLIENT_TERMINALS, $CLIENT_COMPLETE,
     $DRAINS, $REQUESTS, $REJECTED_SENDS, $TIMED_OUT,
     $SEND_EXCEPTION) =
        (Linux::Event::Loop->new, $protocol, (undef) x 14);
    $SERVER_TERMINALS = $SERVER_COMPLETE = $CLIENT_TERMINALS = 0;
    $CLIENT_COMPLETE = $DRAINS = $REQUESTS = $REJECTED_SENDS = $TIMED_OUT = 0;

    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_headers => sub ($tx, $req) {
            $tx->on_finish(sub ($finished) {
                $SERVER_TERMINALS++;
                $SERVER_COMPLETE++ if $finished->is_complete;
            });
        },
        on_request => sub ($tx, $req) {
            $REQUESTS++;
            my $ok = eval {
                $tx->respond(status => 200, body => $response);
                1;
            };
            $SERVER_ERROR = "$@" unless $ok;
        },
        on_error => sub ($tx, $reason) {
            $SERVER_ERROR //= "$reason";
        },
    );
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP, host => '127.0.0.1', port => 0,
        stream => { class => 'HardLimitServer' },
    );
    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        max_connections_per_origin => 1,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            $CLIENT_SOCKET = HardLimitClient->connect(
                loop => $LOOP, host => '127.0.0.1',
                port => $listener->port,
                receive_buffer => 16384,
            );
            $CLIENT_SOCKET->{http_ready} = $ready;
        },
        defer => sub ($callback) { $LOOP->defer($callback) },
    );

    $client->request(
        url => 'http://localhost/oversize',
        http_version => $protocol eq 'h2' ? '2' : '1.1',
        on_finish => sub ($tx) {
            $CLIENT_TERMINALS++;
            $CLIENT_COMPLETE++ if $tx->can('is_complete') && $tx->is_complete;
        },
    );
    $WATCHDOG = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 5,
        on_timer => sub ($timer) {
            $TIMED_OUT++;
            $LOOP->stop;
        },
    );
    $LOOP->run;

    is($TIMED_OUT, 0, "$protocol output-limit failure does not stall");
    is($REQUESTS, 1, "$protocol server processes the oversized request");
    ok($SOCKET_ERROR, "$protocol host reports structured output-limit error");
    if ($SOCKET_ERROR) {
        is($SOCKET_ERROR->type, 'output_limit',
            "$protocol receives fatal output_limit, not cooperative pressure");
        is($SOCKET_ERROR->limit, $cap, "$protocol error carries hard queue cap");
        cmp_ok($SOCKET_ERROR->pending_bytes, '>', $cap,
            "$protocol rejected write would exceed hard queue cap");
    }
    ok($SERVER_SOCKET && $SERVER_SOCKET->is_closed,
        "$protocol host stream is closed following hard-limit failure");
    is($SERVER_TERMINALS, 1, "$protocol server transaction terminates once");
    is($SERVER_COMPLETE, 0, "$protocol server transaction cannot complete successfully");
    is($CLIENT_COMPLETE, 0, "$protocol client never sees successful full response");
    is($DRAINS, 0, "$protocol fatal error does not trigger ordinary producer drain");
    note("$protocol hard-cap error=" . ($SOCKET_ERROR || '<missing>')
        . ", rejected sends=$REJECTED_SENDS; server error="
        . (defined($SERVER_ERROR) ? $SERVER_ERROR : '<none>')
        . ", client terminal callbacks=$CLIENT_TERMINALS");
    $WATCHDOG->cancel if $WATCHDOG && $WATCHDOG->is_active;
    $CLIENT_SOCKET->close if $CLIENT_SOCKET && !$CLIENT_SOCKET->is_closed;
    $listener->close if $listener->can('close');
}

done_testing;
