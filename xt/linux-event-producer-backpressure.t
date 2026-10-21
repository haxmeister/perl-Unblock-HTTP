use v5.36;
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(refaddr);

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use FindBin;
use lib "$FindBin::Bin/lib";
use Unblock::HTTP::Adapter::LinuxEvent;

# A real TCP receiver stops reading while a bounded producer feeds the
# original HTTP transaction through write()/on_drain/end(). A watermark
# is advisory; the socket has an independent hard pending-output cap.
my $chunk = '0123456789abcdef' x 512;
my $chunks = 1024;                         # 8 MiB
my $total_bytes = length($chunk) * $chunks;
my $expected_digest = sha256_hex($chunk x $chunks);
my $hard_pending_cap = 524288;             # 512 KiB socket queue only
my $max_burst = 8;                         # 64 KiB per deferred producer tick

our ($LOOP, $SERVER, $PROTOCOL, $ERROR, $SERVER_TX,
    $WATCHDOG, $RESUME_TIMER, $CLIENT_STREAM);
our ($SENT_CHUNKS, $END_COUNT, $WRITE_BLOCKS, $DRAIN_CALLBACKS,
    $DEFER_TICKS, $MAX_SENT_PER_TICK, $MAX_SOCKET_PENDING,
    $TRANSPORT_BLOCKS, $TRANSPORT_DRAINS, $PRODUCER_RESUMES,
    $READER_RESUMED, $READ_WHILE_PAUSED, $CLIENT_BYTES,
    $CLIENT_CHUNKS, $CLIENT_ENDS, $CLIENT_FINISHES, $SERVER_FINISHES,
    $CLIENT_HEADERS, $SCHEDULED, $WAITING, $PRODUCER_DONE);
our ($DIGEST, @CLIENT_EVENTS);

sub sample_socket ($stream) {
    my $pending = $stream->pending_bytes;
    $MAX_SOCKET_PENDING = $pending if $pending > $MAX_SOCKET_PENDING;
    $ERROR ||= "socket queue exceeded $hard_pending_cap bytes"
        if $pending > $hard_pending_cap;
}

package ProducerServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }
sub socket_options ($class) { (send_buffer => 32768) }
sub stream_tuning ($class) {
    return (
        high_watermark => 32768,
        low_watermark => 8192,
        max_pending_bytes => 524288,
        read_budget_bytes => 65536,
    );
}
sub unblock_send ($self, $bytes) {
    my $ready = $self->SUPER::unblock_send($bytes);
    $main::TRANSPORT_BLOCKS++ unless $ready;
    main::sample_socket($self);
    return $ready;
}
sub on_drain ($self) {
    $main::TRANSPORT_DRAINS++;
    main::sample_socket($self);
    $self->SUPER::on_drain;
}

package ProducerClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{http_ready}
        or die 'missing waiting Client factory';
    $self->{http} = $ready->(transport => $self, alpn => $main::PROTOCOL);
    $self->pause_read;
    $main::RESUME_TIMER = Linux::Event::Kernel::Timer->new(
        loop => $main::LOOP, after => 0.4,
        on_timer => sub ($timer) {
            $main::READER_RESUMED = 1;
            $self->resume_read;
        },
    );
}
sub on_data ($self, $bytes) {
    $main::READ_WHILE_PAUSED++ unless $main::READER_RESUMED;
    $self->{http}->input($bytes);
}
sub on_eof ($self) {
    $self->{http}->input_eof
        if $self->{http} && $self->{http}->want_read;
}
sub on_error ($self, $error) {
    $main::ERROR = "client socket error: $error";
    $main::LOOP->stop;
}
sub on_drain ($self) { $self->{http}->resume_output if $self->{http} }
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'client socket closed during HTTP output' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
is($total_bytes, 8 * 1024 * 1024, 'producer fixture is bounded at eight MiB');

for my $protocol ('http/1.1', 'h2') {
    ($LOOP, $PROTOCOL, $ERROR, $SERVER_TX,
     $WATCHDOG, $RESUME_TIMER, $CLIENT_STREAM,
     $SENT_CHUNKS, $END_COUNT, $WRITE_BLOCKS, $DRAIN_CALLBACKS,
     $DEFER_TICKS, $MAX_SENT_PER_TICK, $MAX_SOCKET_PENDING,
     $TRANSPORT_BLOCKS, $TRANSPORT_DRAINS, $PRODUCER_RESUMES,
     $READER_RESUMED, $READ_WHILE_PAUSED, $CLIENT_BYTES,
     $CLIENT_CHUNKS, $CLIENT_ENDS, $CLIENT_FINISHES, $SERVER_FINISHES,
     $CLIENT_HEADERS, $SCHEDULED, $WAITING, $PRODUCER_DONE) =
       (Linux::Event::Loop->new, $protocol, undef, undef,
        undef, undef, undef,
        (0) x 21);
    $DIGEST = Digest::SHA->new(256);
    @CLIENT_EVENTS = ();

    my ($emit, $schedule);
    $schedule = sub {
        return if $SCHEDULED || $PRODUCER_DONE || $ERROR;
        $SCHEDULED = 1;
        $LOOP->defer(sub {
            $SCHEDULED = 0;
            $emit->() if $emit;
        });
    };
    $emit = sub {
        return if $WAITING || $PRODUCER_DONE || $ERROR;
        my $written = 0;
        $DEFER_TICKS++;
        while ($SENT_CHUNKS < $chunks && $written < $max_burst) {
            my $ready = $SERVER_TX->write($chunk);
            $SENT_CHUNKS++;
            $written++;
            if (!$ready) {
                $WRITE_BLOCKS++;
                $WAITING = 1;
                last;
            }
        }
        $MAX_SENT_PER_TICK = $written if $written > $MAX_SENT_PER_TICK;
        # The last write() may also return false after accepting bytes.
        # Defer even the final empty end() until the matching on_drain.
        if ($SENT_CHUNKS == $chunks && !$WAITING) {
            $PRODUCER_DONE = 1;
            $END_COUNT++;
            $SERVER_TX->end;
        } elsif (!$WAITING) {
            $schedule->();
        }
    };

    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_request => sub ($tx, $request) {
            $SERVER_TX = $tx;
            $tx->on_finish(sub ($final) {
                $SERVER_FINISHES++;
                $ERROR ||= "server transaction failed: " . $final->state
                    unless $final->is_complete;
            });
            $tx->respond(status => 200, stream_body => 1,
                on_drain => sub ($active_tx) {
                    $DRAIN_CALLBACKS++;
                    $ERROR ||= 'unexpected transaction in drain callback'
                        if !defined($active_tx)
                            || refaddr($active_tx) != refaddr($SERVER_TX);
                    if ($WAITING) {
                        $WAITING = 0;
                        $PRODUCER_RESUMES++;
                        $schedule->();
                    }
                },
            );
            $schedule->();
        },
        on_error => sub ($tx, $reason) {
            $ERROR = "server HTTP error: $reason";
            $LOOP->stop;
        },
    );

    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP, host => '127.0.0.1', port => 0,
        stream => { class => 'ProducerServer' },
    );
    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        max_connections_per_origin => 1,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            $CLIENT_STREAM = ProducerClient->connect(
                loop => $LOOP, host => '127.0.0.1',
                port => $listener->port, receive_buffer => 16384,
            );
            $CLIENT_STREAM->{http_ready} = $ready;
        },
        defer => sub ($callback) { $LOOP->defer($callback) },
    );

    $client->request(
        url => 'http://localhost/producer',
        http_version => $protocol eq 'h2' ? '2' : '1.1',
        on_response => sub ($tx, $response) {
            $CLIENT_HEADERS++;
            push @CLIENT_EVENTS, 'headers';
            $ERROR ||= "unexpected status " . $response->status
                unless $response->status == 200;
        },
        on_data => sub ($tx, $bytes) {
            $CLIENT_BYTES += length($bytes);
            $CLIENT_CHUNKS++;
            $DIGEST->add($bytes);
        },
        on_end => sub ($tx) {
            $CLIENT_ENDS++;
            push @CLIENT_EVENTS, 'end';
        },
        on_error => sub ($tx, $error) {
            $ERROR = "client HTTP error: $error";
            $LOOP->stop;
        },
        on_finish => sub ($tx) {
            $CLIENT_FINISHES++;
            push @CLIENT_EVENTS, 'finish';
            $ERROR ||= 'client transaction did not complete'
                unless $tx->can('is_complete') && $tx->is_complete;
            $LOOP->stop;
        },
    );
    $WATCHDOG = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 25,
        on_timer => sub ($timer) {
            $ERROR = "$protocol sustained producer watchdog expired";
            $LOOP->stop;
        },
    );
    $LOOP->run;
    is($ERROR, undef, "$protocol producer/receiver completes without error");
    is($READER_RESUMED, 1, "$protocol paused reader resumed");
    is($READ_WHILE_PAUSED, 0, "$protocol no early client reads");
    is($SENT_CHUNKS, $chunks, "$protocol all producer chunks issued once");
    is($END_COUNT, 1, "$protocol producer ends once");
    is($CLIENT_BYTES, $total_bytes, "$protocol all bytes received exactly once");
    is($DIGEST->hexdigest, $expected_digest, "$protocol received digest matches");
    is($CLIENT_HEADERS, 1, "$protocol one response header");
    is($CLIENT_ENDS, 1, "$protocol one on_end");
    is($CLIENT_FINISHES, 1, "$protocol one client finish");
    is($SERVER_FINISHES, 1, "$protocol one server finish");
    is_deeply(\@CLIENT_EVENTS, ['headers', 'end', 'finish'],
        "$protocol streaming response callback order");
    ok($CLIENT_CHUNKS > 1, "$protocol received in multiple chunks");
    ok($WRITE_BLOCKS > 0, "$protocol producer actually received backpressure");
    ok($PRODUCER_RESUMES > 0, "$protocol producer resumed after drain");
    ok($MAX_SENT_PER_TICK <= $max_burst,
        "$protocol producer respects per-event-loop emission budget");
    ok($MAX_SOCKET_PENDING <= $hard_pending_cap,
        "$protocol observed socket pending queue stays within hard cap");
    note("$protocol producer blocks=$WRITE_BLOCKS, resumes=$PRODUCER_RESUMES,"
        . " socket blocked=$TRANSPORT_BLOCKS, socket drains=$TRANSPORT_DRAINS,"
        . " max measured socket pending=$MAX_SOCKET_PENDING bytes,"
        . " producer ticks=$DEFER_TICKS");
    $WATCHDOG->cancel if $WATCHDOG && $WATCHDOG->is_active;
    $RESUME_TIMER->cancel if $RESUME_TIMER && $RESUME_TIMER->is_active;
    $CLIENT_STREAM->close if $CLIENT_STREAM && !$CLIENT_STREAM->is_closed;
    $listener->close if $listener->can('close');
}

done_testing;
