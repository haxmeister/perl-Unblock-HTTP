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
use Scalar::Util qw(weaken);
sub on_ready ($self) {
    my $stream = $self;
    weaken($stream);
    $self->{client} = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            my $engine = $ready->(
                transport => $stream, alpn => $main::PROTOCOL,
            );
            $stream->{http} = $engine if $stream;
        },
        defer => sub {
            my ($callback) = @_;
            $main::LOOP->defer($callback);
        },
        schedule_timer => sub {
            my ($seconds, $callback) = @_;
            my $timer = Linux::Event::Kernel::Timer->new(
                loop => $main::LOOP,
                after => $seconds,
                on_timer => sub { $callback->() },
            );
            return sub {
                $timer->cancel if $timer->is_active;
                $main::TIMER_CANCELLATIONS++;
            };
        },
    );
    for my $index (1 .. $main::REQUESTS) {
        $self->{client}->request(
            method => 'GET',
            url => 'http://localhost/test' . $index,
            timeout => 5,
            http_version => $main::PROTOCOL eq 'h2' ? '2' : '1.1',
            on_response => sub ($tx, $response) {
                $main::FAILED = "unexpected status: " . $response->status
                    unless $response->status == 200;
                $main::BODY .= $response->body;
            },
            on_error => sub ($tx, $error) {
                $main::FAILED = "request failed: $error";
                $main::LOOP->stop;
            },
            on_finish => sub ($tx) {
                $main::FAILED ||= 'request ended without success'
                    unless $tx->is_complete;
                $main::COMPLETED++;
                $main::LOOP->stop if $main::COMPLETED == $main::REQUESTS;
            },
        );
    }
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
    my $client = TestHTTPClient->connect(
        loop => $LOOP,
        host => '127.0.0.1',
        port => $listener->port,
    );
    $LOOP->run;
    is($FAILED, undef, "$protocol completes without error");
    is($SERVER_REQUESTS, $REQUESTS, "$protocol delivered all requests");
    is($COMPLETED, $REQUESTS, "$protocol all requests finished");
    is($BODY, ("hello from $protocol\n" x $REQUESTS), "$protocol bodies complete");
    is($TIMER_CANCELLATIONS, $REQUESTS, "$protocol cancels all operation timers");
    $client->close unless $client->is_closed;
    $listener->close if $listener->can('close');
    $timer->cancel if $timer->is_active;
}
done_testing;
