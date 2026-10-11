#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::IO::Sock::Listener;
use Linux::Event::Loop;
use Unblock::HTTP::Adapter::LinuxEvent;

# APPLICATION CODE: supply only HTTP behavior.
package Example::HelloHTTPStream;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';

sub http_protocol ($self) {
    # For plain HTTP/2 prior knowledge, set UNBLOCK_HTTP_PROTOCOL=h2.
    # For TLS, leave this undefined so negotiated ALPN is used.
    return $ENV{UNBLOCK_HTTP_PROTOCOL};
}

sub on_http_request ($self, $tx, $request) {
    $tx->respond(
        status => 200,
        headers => [ [ 'Content-Type' => 'text/plain' ] ],
        body => "hello from Unblock::HTTP\n",
    );
}

package main;
my $port = shift // 8080;
die "usage: $0 [PORT]\n"
    unless $port =~ /\A[0-9]+\z/ && $port >= 1 && $port <= 65535;

# ADAPTER CODE: the Linux::Event subclass owns the HTTP connection.
my $loop = Linux::Event::Loop->new;
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    stream => { class => 'Example::HelloHTTPStream' },
);

print "HTTP listening on ", $listener->port, "\n";
$loop->run;
