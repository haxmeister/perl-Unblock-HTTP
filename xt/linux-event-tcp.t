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

our ($PROTOCOL, $LOOP, $BODY, $FAILED, $SERVER_REQUESTS, $SERVER);

package TestHTTPServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }

package TestHTTPClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    $self->{http} = Unblock::HTTP::Client->new(
        protocol => $main::PROTOCOL,
        transport => $self,
    );
    $self->{http}->request(
        method => 'GET', target => '/', scheme => 'http',
        authority => 'localhost',
        on_response => sub ($tx, $response) {
            $main::FAILED = "unexpected status: " . $response->status
                unless $response->status == 200;
        },
        on_body => sub ($tx, $response, $bytes) {
            $main::BODY .= $bytes;
        },
        on_complete => sub ($tx) { $main::LOOP->stop },
        on_error => sub ($tx, $error) {
            $main::FAILED = "request failed: $error";
            $main::LOOP->stop;
        },
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
    ($PROTOCOL, $LOOP, $BODY, $FAILED, $SERVER_REQUESTS) = ($protocol, Linux::Event::Loop->new, '', undef, 0);
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
    is($SERVER_REQUESTS, 1, "$protocol delivered one request");
    is($BODY, "hello from $protocol\n", "$protocol body complete");
    $client->close unless $client->is_closed;
    $listener->close if $listener->can('close');
    $timer->cancel if $timer->is_active;
}
done_testing;
