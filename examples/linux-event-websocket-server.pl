#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

# APPLICATION CODE: the same listener accepts ordinary HTTP and WebSockets.
my $server = Unblock::HTTP::Server->new(
    http1 => { websocket => 1 },
    on_request => sub ($tx, $request) {
        $tx->respond(
            status => 200,
            headers => [ [ 'Content-Type' => 'text/plain' ] ],
            body => "HTTP is still available\n",
        );
    },
    on_websocket => sub ($tx, $request) {
        # Requests for other paths are rejected with HTTP 403.
        return unless $request->target eq '/ws';
        return {
            on_message => sub ($ws, $payload, $type) {
                $type eq 'text'
                    ? $ws->send_text("echo:$payload")
                    : $ws->send_binary($payload);
            },
        };
    },
);

# ADAPTER CODE: the optional LinuxEvent adapter switches the consumer
# to WebSocket after the original HTTP1 engine queues the 101 response.
# The same Stream and ordered write queue survive the transition.
package Example::WebSocketStream;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_server ($self) { $server }

package main;
my $port = shift // 8080;
die "usage: $0 [PORT]\n"
    unless $port =~ /\A[0-9]+\z/ && $port >= 1 && $port <= 65535;

my $loop = Linux::Event::Loop->new;
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    stream => { class => 'Example::WebSocketStream' },
);
print "HTTP:      http://127.0.0.1:", $listener->port, "/\n";
print "WebSocket: ws://127.0.0.1:", $listener->port, "/ws\n";
$loop->run;
