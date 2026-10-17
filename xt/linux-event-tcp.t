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

our ($PROTOCOL, $LOOP, $BODY, $FAILED, $SERVER_REQUESTS, $SERVER, $TIMER_CANCELLATIONS,
     $COMPLETED, $REQUESTS);

package TestHTTPServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }

package TestHTTPClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{http_ready}
        or die 'client transport has no waiting engine factory';
    $self->{http} = $ready->(
        transport => $self, alpn => $main::PROTOCOL,
    );
}
sub on_data ($self, $bytes) { $self->{http}->input($bytes) }
sub on_eof ($self) { $self->{http}->input_eof if $self->{http} && $self->{http}->want_read }
sub on_error ($self, $error) {
    $main::FAILED = "socket failed: $error";
    $main::LOOP->stop;
}
sub on_drain ($self) { $self->{http}->resume_output if $self->{http} }
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'socket closed during send' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
for my $protocol ('http/1.1', 'h2') {
    ($PROTOCOL, $LOOP, $BODY, $FAILED, $SERVER_REQUESTS,
        $TIMER_CANCELLATIONS, $COMPLETED, $REQUESTS) =
        ($protocol, Linux::Event::Loop->new, '', undef, 0, 0, 0, 12);
    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_request => sub ($tx, $request) {
            $SERVER_REQUESTS++;
            $tx->respond(status => 200, body => "hello from $PROTOCOL\n");
        },
    );
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP,
        host => '127.0.0.1',
        port => 0,
        stream => { class => 'TestHTTPServer' },
    );
    my $timer = Linux::Event::Kernel::Timer->new(
        loop => $LOOP,
        after => 10,
        on_timer => sub ($t) { $FAILED = 'timeout'; $LOOP->stop },
    );
    my @client_streams;
    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        max_connections_per_origin => 2,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            my $stream = TestHTTPClient->connect(
                loop => $LOOP, host => '127.0.0.1', port => $listener->port,
            );
            $stream->{http_ready} = $ready;
            push @client_streams, $stream;
        },
        defer => sub {
            my ($callback) = @_;
            $LOOP->defer($callback);
        },
        schedule_timer => sub {
            my ($seconds, $callback) = @_;
            my $timer = Linux::Event::Kernel::Timer->new(
                loop => $LOOP, after => $seconds,
                on_timer => sub { $callback->() },
            );
            return sub {
                $timer->cancel if $timer->is_active;
                $TIMER_CANCELLATIONS++;
            };
        },
    );
    for my $index (1 .. $REQUESTS) {
        $client->request(
            method => 'GET',
            url => 'http://localhost/test' . $index,
            timeout => 5,
            http_version => $PROTOCOL eq 'h2' ? '2' : '1.1',
            on_response => sub ($tx, $response) {
                $FAILED = "unexpected status: " . $response->status
                    unless $response->status == 200;
                $BODY .= $response->body;
            },
            on_error => sub ($tx, $error) {
                $FAILED = "request failed: $error";
                $LOOP->stop;
            },
            on_finish => sub ($tx) {
                $FAILED ||= 'request ended without success'
                    unless $tx->is_complete;
                $COMPLETED++;
                $LOOP->stop if $COMPLETED == $REQUESTS;
            },
        );
    }
    $LOOP->run;
    is($FAILED, undef, "$protocol completes without error");
    is($SERVER_REQUESTS, $REQUESTS, "$protocol delivered all requests");
    is($COMPLETED, $REQUESTS, "$protocol all requests finished");
    is($BODY, ("hello from $protocol\n" x $REQUESTS), "$protocol bodies complete");
    is($TIMER_CANCELLATIONS, $REQUESTS, "$protocol cancels all operation timers");
    for my $stream (@client_streams) {
        $stream->close unless $stream->is_closed;
    }
    $listener->close if $listener->can('close');
    $timer->cancel if $timer->is_active;
}
done_testing;
