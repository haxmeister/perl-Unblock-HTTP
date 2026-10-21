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
use FindBin;
use lib "$FindBin::Bin/lib";
use Unblock::HTTP::Adapter::LinuxEvent;

our ($LOOP, $PROTOCOL, $SERVER, $FAILED, $REQUESTS, $WS_MESSAGES);

# ADAPTER: one subclass provides the shared Server definition. H1 Upgrade
# changes the consumer; H2 Extended CONNECT keeps the original HTTP engine.
package Local::WebSocketServerStream;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }

# ADAPTER: a shared Client factory creates framework-owned TCP sockets.
# No WebSocket framing or HTTP parsing belongs in this adapter.
package Local::WebSocketClientStream;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{ready}
        or die 'missing Client transport ready callback';
    $self->{http} = $ready->(
        transport => $self, alpn => $main::PROTOCOL,
    );
}
sub unblock_upgrade ($self, $websocket) {
    die 'already upgraded' if $self->{websocket};
    $self->{websocket} = $websocket;
    return;
}
sub consumer ($self) { $self->{websocket} || $self->{http} }
sub on_data ($self, $bytes) { $self->consumer->input($bytes) }
sub on_eof ($self) {
    my $consumer = $self->consumer;
    $consumer->input_eof if $consumer && $consumer->want_read;
}
sub on_error ($self, $error) {
    $main::FAILED = "socket error: $error";
    $main::LOOP->stop;
}
sub on_drain ($self) { $self->consumer->resume_output if $self->consumer }
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'stream closed during write' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
for my $protocol ('http/1.1', 'h2') {
    ($PROTOCOL, $LOOP, $FAILED, $REQUESTS, $WS_MESSAGES) =
        ($protocol, Linux::Event::Loop->new, undef, 0, 0);
    my $server_websocket_requests = 0;
    $SERVER = Unblock::HTTP::Server->new(
        http1 => { websocket => 1 },
        http2 => { websocket => 1 },
        defer => sub ($cb) { $LOOP->defer($cb) },
        on_request => sub ($tx, $request) {
            $REQUESTS++;
            $tx->respond(status => 200, body => 'ordinary-ok');
        },
        on_websocket => sub ($tx, $request) {
            $server_websocket_requests++;
            return unless $request->target eq '/ws';
            return {
                backend => 'perl',
                on_message => sub ($ws, $payload, $type) {
                    $ws->send_text("echo:$payload");
                },
            };
        },
    );

    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP,
        host => '127.0.0.1',
        port => 0,
        stream => { class => 'Local::WebSocketServerStream' },
    );
    my @client_streams;
    my $client_connections = 0;
    my $client = Unblock::HTTP::Client->new(
        http1 => { websocket => 1 },
        http2 => { websocket => 1 },
        max_connections_per_origin => 1,
        connect_stream => sub ($origin, $alpn, $ready) {
            $client_connections++;
            my $stream = Local::WebSocketClientStream->connect(
                loop => $LOOP, host => '127.0.0.1', port => $listener->port,
            );
            $stream->{ready} = $ready;
            push @client_streams, $stream;
        },
        defer => sub ($cb) { $LOOP->defer($cb) },
    );

    my ($got_echo, $got_ordinary, $websocket_opened) = ('', '', 0);
    my $started_ordinary = 0;
    my $maybe_done = sub {
        $LOOP->stop if $got_echo eq 'echo:ping'
            && $got_ordinary eq 'ordinary-ok';
    };
    my $fail = sub ($error) {
        $FAILED ||= "$error";
        $LOOP->stop;
    };

    # APPLICATION: no socket class or engine framing in this callback.
    my $websocket_op = $client->connect_websocket(
        url => 'ws://127.0.0.1:' . $listener->port . '/ws',
        http_version => $protocol eq 'h2' ? '2' : '1.1',
        backend => 'perl',
        on_open => sub ($ws, $tx) {
            $websocket_opened++;
            $ws->send_text('ping');
        },
        on_message => sub ($ws, $payload, $type) {
            $got_echo = $payload;
            $ws->close;
            if (!$started_ordinary++) {
                # Avoid reentering nghttp2 from a WebSocket input callback.
                $LOOP->defer(sub {
                    $client->request(
                        url => 'http://127.0.0.1:' . $listener->port . '/ordinary',
                        http_version => $protocol eq 'h2' ? '2' : '1.1',
                        on_response => sub ($tx, $response) {
                            $got_ordinary = $response->body;
                        },
                        on_error => sub ($tx, $error) { $fail->($error) },
                        on_finish => sub ($tx) { $maybe_done->() },
                    );
                });
            }
            $maybe_done->();
        },
        on_error => sub ($object, $error) { $fail->($error) },
    );
    my $watchdog = Linux::Event::Kernel::Timer->new(
        loop => $LOOP,
        after => 10,
        on_timer => sub ($timer) { $fail->('timeout') },
    );
    $LOOP->run;

    is($FAILED, undef, "$protocol WebSocket live TCP exchange succeeds");
    is($websocket_opened, 1, "$protocol opens one WebSocket");
    is($got_echo, 'echo:ping', "$protocol receives one echoed frame");
    is($server_websocket_requests, 1, "$protocol invokes on_websocket once");
    is($got_ordinary, 'ordinary-ok', "$protocol retains ordinary HTTP");
    is($REQUESTS, 1, "$protocol ordinary request served once");
    is($client_connections, $protocol eq 'h2' ? 1 : 2,
        "$protocol pool handles WebSocket socket/stream ownership");
    ok($websocket_op->websocket, "$protocol operation exposes WebSocket");

    $client->shutdown;
    for my $stream (@client_streams) {
        $stream->close unless $stream->is_closed;
    }
    $listener->close if $listener->can('close');
    $watchdog->cancel if $watchdog->is_active;
}
done_testing;
