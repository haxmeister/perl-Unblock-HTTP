#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::IO::Sock::Listener;
use Linux::Event::Loop;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

# APPLICATION CODE: one definition serves all incoming connections.
my $server = Unblock::HTTP::Server->new(
    http1 => {},
    http2 => {},
    on_request => sub ($tx, $request) {
        $tx->respond(
            status => 200,
            headers => [ [ 'Content-Type' => 'text/plain' ] ],
            body => "hello from Unblock::HTTP\n",
        );
    },
);

# ADAPTER CODE: supply the definition to each framework-owned stream.
package Example::HTTPStream;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_server ($self) { $server }
sub http_protocol ($self) { $ENV{UNBLOCK_HTTP_PROTOCOL} }

package main;
my $port = shift // 8080;
die "usage: $0 [PORT]\n"
    unless $port =~ /\A[0-9]+\z/ && $port >= 1 && $port <= 65535;
my $loop = Linux::Event::Loop->new;
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop, host => '127.0.0.1', port => $port,
    stream => { class => 'Example::HTTPStream' },
);

# This example uses cleartext. Set UNBLOCK_HTTP_PROTOCOL=h2 for H2 prior
# knowledge. For a TLS listener use the framework's ALPN configuration
# with the choices returned by $server->alpn_protocols.
print "HTTP listening on ", $listener->port, "\n";
$loop->run;
