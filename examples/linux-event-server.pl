#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Loop;
use Unblock::HTTP::Server;

# ADAPTER CODE: one framework stream hosts either HTTP/1 or HTTP/2.
package Example::HTTPStream;
use parent 'Linux::Event::IO::Sock::Stream';
use Scalar::Util qw(weaken);

sub new ($class, %args) {
    my $self = $class->SUPER::new(%args);
    my $stream = $self;
    weaken($stream);

    # Set UNBLOCK_HTTP_PROTOCOL=h2 for cleartext HTTP/2 prior knowledge.
    # A TLS adapter should supply its negotiated ALPN instead.
    $self->{http} = Unblock::HTTP::Server->new(
        transport  => $self,
        protocol   => $ENV{UNBLOCK_HTTP_PROTOCOL} // 'http/1.1',
        on_request => sub ($tx, $request) {
            $stream->on_http_request($tx, $request) if $stream;
        },
    );
    return $self;
}

sub on_data ($self, $bytes) {
    $self->{http}->input($bytes);
}

sub on_eof ($self) {
    $self->{http}->input_eof if $self->{http}->want_read;
}

sub on_error ($self, $error) {
    $self->{http}->transport_error("$error");
}

sub on_drain ($self) {
    $self->{http}->resume_output;
}

sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die "Linux::Event stream closed during HTTP output\n" if $self->is_closed;
    return $ready;
}

sub unblock_finish ($self) {
    $self->end;
}

sub unblock_abort ($self, $reason) {
    $self->close;
}

sub on_http_request ($self, $tx, $request) {
    die "on_http_request() must be implemented\n";
}

# APPLICATION CODE: no knowledge of which HTTP engine was selected.
package Example::HelloHTTPStream;
use parent -norequire, 'Example::HTTPStream';

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

my $loop = Linux::Event::Loop->new;
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    stream => { class => 'Example::HelloHTTPStream' },
);

print "HTTP listening on ", $listener->port, "\n";
$loop->run;
