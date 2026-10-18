use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Digest::SHA qw(sha256_hex);

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

# Unlike the simulated-backpressure fixture, this test stops kernel
# socket reads. The response is larger than ordinary socket buffers.
# No throughput or memory-high-water claim is made from this fixture.
my $response = '0123456789abcdef' x 393216;  # 6 MiB
my $expected = sha256_hex($response);

our ($LOOP, $SERVER, $PROTOCOL, $ERROR, $RELEASED, $FINISHED,
    $RESPONSE_HEADERS, $RESPONSE_ENDS, $RESPONSE_BYTES, $RESPONSE_CHUNKS,
    $READ_WHILE_PAUSED, $SEND_BACKPRESSURE, $SERVER_DRAIN,
    $CLIENT_TIMER, $WATCHDOG, $CLIENT_STREAM);
our ($RESPONSE_DIGEST, @EVENTS);

package SlowReaderServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }
sub stream_tuning ($class) {
    return (
        high_watermark => 16384,
        low_watermark  => 4096,
        read_budget_bytes => 65536,
    );
}
sub unblock_send ($self, $bytes) {
    my $ready = $self->SUPER::unblock_send($bytes);
    $main::SEND_BACKPRESSURE++ unless $ready;
    return $ready;
}
sub on_drain ($self) {
    $main::SERVER_DRAIN++;
    $self->SUPER::on_drain;
}

package SlowReaderClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{http_ready}
        or die 'client has no pending connection factory';
    $self->{http} = $ready->(transport => $self, alpn => $main::PROTOCOL);
    $self->pause_read;
    $main::CLIENT_TIMER = Linux::Event::Kernel::Timer->new(
        loop => $main::LOOP,
        after => 0.12,
        on_timer => sub ($timer) {
            $main::RELEASED = 1;
            $self->resume_read;
        },
    );
}
sub on_data ($self, $bytes) {
    $main::READ_WHILE_PAUSED++ unless $main::RELEASED;
    $self->{http}->input($bytes);
}
sub on_eof ($self) {
    $self->{http}->input_eof
        if $self->{http} && $self->{http}->want_read;
}
sub on_error ($self, $error) {
    $main::ERROR = "client TCP error: $error";
    $main::LOOP->stop;
}
sub on_drain ($self) {
    $self->{http}->resume_output if $self->{http};
}
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'client stream closed while writing' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
is(length($response), 6 * 1024 * 1024, 'bounded six MiB response fixture');

for my $protocol ('http/1.1', 'h2') {
    ($PROTOCOL, $LOOP, $ERROR, $RELEASED, $FINISHED,
     $RESPONSE_HEADERS, $RESPONSE_ENDS, $RESPONSE_BYTES,
     $RESPONSE_CHUNKS, $READ_WHILE_PAUSED, $SEND_BACKPRESSURE,
     $SERVER_DRAIN, $CLIENT_TIMER, $WATCHDOG, $CLIENT_STREAM) =
        ($protocol, Linux::Event::Loop->new, undef, 0, 0,
         0, 0, 0, 0, 0, 0, 0, undef, undef, undef);
    @EVENTS = ();
    $RESPONSE_DIGEST = Digest::SHA->new(256);

    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_request => sub ($tx, $request) {
            $tx->respond(status => 200, body => $response);
        },
        on_error => sub ($tx, $reason) {
            $ERROR = "server $protocol HTTP error: $reason";
            $LOOP->stop;
        },
    );

    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP, host => '127.0.0.1', port => 0,
        stream => { class => 'SlowReaderServer' },
    );

    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        max_connections_per_origin => 1,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            $CLIENT_STREAM = SlowReaderClient->connect(
                loop => $LOOP, host => '127.0.0.1',
                port => $listener->port,
                receive_buffer => 16384,
            );
            $CLIENT_STREAM->{http_ready} = $ready;
        },
        defer => sub {
            my ($callback) = @_;
            $LOOP->defer($callback);
        },
    );

    $client->request(
        url => 'http://localhost/slow',
        http_version => $protocol eq 'h2' ? '2' : '1.1',
        on_response => sub ($tx, $reply) {
            $RESPONSE_HEADERS++;
            push @EVENTS, 'headers';
            $ERROR = "unexpected $protocol status: " . $reply->status
                unless $reply->status == 200;
            $ERROR = "unexpected buffered response"
                if defined($reply->body) && length($reply->body) >= length($response);
        },
        on_data => sub ($tx, $chunk) {
            $RESPONSE_BYTES += length($chunk);
            $RESPONSE_CHUNKS++;
            $RESPONSE_DIGEST->add($chunk);
        },
        on_end => sub ($tx) {
            $RESPONSE_ENDS++;
            push @EVENTS, 'end';
        },
        on_error => sub ($tx, $reason) {
            $ERROR = "$protocol HTTP error: $reason";
            $LOOP->stop;
        },
        on_finish => sub ($tx) {
            $FINISHED++;
            push @EVENTS, 'finish';
            if (!$tx->can('is_complete')) {
                $ERROR ||= "$protocol failed before dispatch: "
                    . ($tx->error || $tx->state);
                $LOOP->stop;
                return;
            }
            $ERROR ||= "$protocol transaction not complete"
                unless $tx->is_complete;
            $LOOP->stop;
        },
    );

    $WATCHDOG = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 25,
        on_timer => sub ($timer) {
            $ERROR = "$protocol slow-reader watchdog expired";
            $LOOP->stop;
        },
    );
    $LOOP->run unless $ERROR;

    is($ERROR, undef, "$protocol slow reader completes without HTTP error");
    is($RELEASED, 1, "$protocol reader resumed by framework timer");
    is($READ_WHILE_PAUSED, 0, "$protocol no application data delivered while paused");
    is($FINISHED, 1, "$protocol one native transaction finishes");
    is($RESPONSE_HEADERS, 1, "$protocol response headers callback once");
    is($RESPONSE_ENDS, 1, "$protocol response end callback once");
    is($RESPONSE_BYTES, length($response), "$protocol receives every response byte once");
    is($RESPONSE_DIGEST->hexdigest, $expected, "$protocol response SHA-256 matches");
    ok($RESPONSE_CHUNKS > 1, "$protocol response uses incremental chunks");
    is_deeply(\@EVENTS, ['headers', 'end', 'finish'],
        "$protocol stream completion callbacks ordered correctly");
    # Actual socket pressure depends on host TCP buffers and scheduling.
    # Record the result, but do not assume a CI kernel always congests.
    note("$protocol real socket unblock_send=false: $SEND_BACKPRESSURE; on_drain: $SERVER_DRAIN");
    ok($SEND_BACKPRESSURE == 0 || $SERVER_DRAIN > 0,
        "$protocol any observed socket pressure gets a drain notification");
    $CLIENT_TIMER->cancel if $CLIENT_TIMER && $CLIENT_TIMER->is_active;
    $WATCHDOG->cancel if $WATCHDOG && $WATCHDOG->is_active;
    $CLIENT_STREAM->close if $CLIENT_STREAM && !$CLIENT_STREAM->is_closed;
    $listener->close if $listener->can('close');
}

done_testing;
