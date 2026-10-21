#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

# APPLICATION CODE: the same callbacks serve HTTP1 Upgrade and HTTP2
# Extended CONNECT. Neither callback knows anything about Linux::Event.
my $loop = Linux::Event::Loop->new;
my $server = Unblock::HTTP::Server->new(
    http1 => { websocket => 1 },
    http2 => { websocket => 1 },
    defer => sub ($callback) {
        # Mandatory for H2: never write to nghttp2 from inside input().
        $loop->defer($callback);
    },
    on_request => sub ($tx, $request) {
        $tx->respond(
            status => 200,
            headers => [ [ 'Content-Type' => 'text/plain' ] ],
            body => "HTTP is still available\n",
        );
    },
    on_websocket => sub ($tx, $request) {
        # A declined WebSocket handshake receives an HTTP 403.
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

# ADAPTER CODE: Linux::Event owns the listener, socket and ordered write
# queue. H1 changes the consumer after 101; H2 retains its HTTP engine
# and dispatches WebSocket frames through independent request streams.
package Example::WebSocketStream;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_server ($self) { $server }
sub http_protocol ($self) { $ENV{UNBLOCK_HTTP_PROTOCOL} }

package main;
my $port = shift // 8080;
die "usage: $0 [PORT]\n"
    unless $port =~ /\A[0-9]+\z/ && $port >= 1 && $port <= 65535;
die "UNBLOCK_HTTP_PROTOCOL must be h2 when set\n"
    if defined($ENV{UNBLOCK_HTTP_PROTOCOL})
        && $ENV{UNBLOCK_HTTP_PROTOCOL} ne 'h2';

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    stream => { class => 'Example::WebSocketStream' },
);
print "HTTP1: ws://127.0.0.1:", $listener->port, "/ws\n";
print "HTTP2 prior knowledge: UNBLOCK_HTTP_PROTOCOL=h2 $0 ",
      $listener->port, "\n";
print "HTTP2 WebSocket uses Extended CONNECT; ordinary clients must use H2.\n";
$loop->run;
