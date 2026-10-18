use v5.36;
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

# Three independent pooled connections for one origin. Two receivers stop
# reading; the third must finish while their reads are still paused.
# The producer budgets each loop turn and honors native on_drain.
my $chunk = '0123456789abcdef' x 256;         # 4 KiB
my $chunks = 512;                             # 2 MiB per response
my $body_length = length($chunk) * $chunks;
my $digest = sha256_hex($chunk x $chunks);
my $pending_cap = 524288;
our ($LOOP, $SERVER, $PROTOCOL, $ERROR, $WATCHDOG,
     $CONNECTIONS, $SLOW_RESUMED, $FAST_BEFORE_RESUME,
     $SERVER_FINISHED, $CLIENT_FINISHED, $SERVER_DRAINS,
     $SOCKET_DRAINS, $MAX_SOCKET_PENDING);
our (%PRODUCERS, %CLIENT_BYTES, %CLIENT_DIGEST, %CLIENT_EVENTS, %END_COUNT,
     %SERVER_TX_COUNT, %CLIENT_TX_COUNT, %CLIENT_CHUNKS);
our (@STREAMS, @TIMERS);

sub sample_queue ($stream) {
    my $value = $stream->pending_bytes;
    $MAX_SOCKET_PENDING = $value if $value > $MAX_SOCKET_PENDING;
    $ERROR ||= "socket output queue exceeded cap"
        if $value > $pending_cap;
}

sub push_more ($key) {
    my $p = $PRODUCERS{$key} or return;
    return if $p->{waiting} || $p->{ended} || $ERROR;
    my $count = 0;
    while ($p->{written} < $chunks && $count < 4) {
        my $ok = $p->{tx}->write($chunk);
        $p->{written}++;
        $count++;
        if (!$ok) {
            $p->{waiting} = 1;
            $p->{blocks}++;
            last;
        }
    }
    $p->{max_burst} = $count if $count > ($p->{max_burst} || 0);
    if ($p->{written} == $chunks && !$p->{waiting}) {
        $p->{ended} = 1;
        $p->{tx}->end;
    } elsif (!$p->{waiting}) {
        schedule_more($key);
    }
}

sub schedule_more ($key) {
    my $p = $PRODUCERS{$key} or return;
    return if $p->{scheduled} || $p->{ended} || $ERROR;
    $p->{scheduled} = 1;
    $LOOP->defer(sub {
        $p->{scheduled} = 0;
        push_more($key);
    });
}

package FairnessServer;
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
    my $ok = $self->SUPER::unblock_send($bytes);
    main::sample_queue($self);
    return $ok;
}
sub on_drain ($self) {
    $main::SOCKET_DRAINS++;
    main::sample_queue($self);
    $self->SUPER::on_drain;
}
sub on_error ($self, $error) {
    $main::ERROR = "server transport: $error";
    $main::LOOP->stop;
    $self->SUPER::on_error($error);
}

package FairnessClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{http_ready}
        or die 'missing pooled Client factory ready callback';
    $self->{http} = $ready->(transport => $self, alpn => $main::PROTOCOL);
    if ($self->{slow}) {
        $self->pause_read;
        my $timer = Linux::Event::Kernel::Timer->new(
            loop => $main::LOOP, after => 0.8,
            on_timer => sub ($timer) {
                $self->{resumed} = 1;
                $main::SLOW_RESUMED++;
                $self->resume_read;
            },
        );
        push @main::TIMERS, $timer;
    }
}
sub on_data ($self, $bytes) {
    $main::ERROR ||= "slow reader received early bytes"
        if $self->{slow} && !$self->{resumed};
    $self->{http}->input($bytes);
}
sub on_eof ($self) {
    $self->{http}->input_eof
        if $self->{http} && $self->{http}->want_read;
}
sub on_error ($self, $err) {
    $main::ERROR = "client transport: $err";
    $main::LOOP->stop;
}
sub on_drain ($self) { $self->{http}->resume_output if $self->{http} }
sub unblock_send ($self, $bytes) {
    my $ok = $self->write($bytes);
    die 'client stream closed while sending' if $self->is_closed;
    return $ok;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
is($body_length, 2 * 1024 * 1024, 'per-response body is bounded to two MiB');

for my $protocol ('http/1.1', 'h2') {
    ($LOOP, $PROTOCOL, $ERROR, $WATCHDOG, $CONNECTIONS,
     $SLOW_RESUMED, $FAST_BEFORE_RESUME, $SERVER_FINISHED,
     $CLIENT_FINISHED, $SERVER_DRAINS, $SOCKET_DRAINS,
     $MAX_SOCKET_PENDING) =
        (Linux::Event::Loop->new, $protocol, undef, undef,
         (0) x 8);
    %PRODUCERS = (); %CLIENT_BYTES = (); %CLIENT_DIGEST = ();
    %CLIENT_EVENTS = (); %END_COUNT = (); %SERVER_TX_COUNT = ();
    %CLIENT_TX_COUNT = (); %CLIENT_CHUNKS = ();
    @STREAMS = (); @TIMERS = ();

    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_request => sub ($tx, $req) {
            my $key = $req->target;
            $PRODUCERS{$key} = {
                tx => $tx, written => 0, ended => 0,
                waiting => 0, scheduled => 0, blocks => 0,
            };
            $SERVER_TX_COUNT{$key}++;
            $tx->on_finish(sub ($final) {
                $SERVER_FINISHED++;
                $ERROR ||= "$key server tx did not complete"
                    unless $final->is_complete;
            });
            $tx->respond(status => 200, stream_body => 1,
                on_drain => sub ($active_tx) {
                    $SERVER_DRAINS++;
                    $ERROR ||= "$key drain transaction changed"
                        unless $active_tx == $tx;
                    my $p = $PRODUCERS{$key};
                    if ($p->{waiting}) {
                        $p->{waiting} = 0;
                        schedule_more($key);
                    }
                },
            );
            schedule_more($key);
        },
        on_error => sub ($tx, $reason) {
            $ERROR = "server HTTP: $reason";
            $LOOP->stop;
        },
    );
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP, host => '127.0.0.1', port => 0,
        stream => { class => 'FairnessServer' },
    );
    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        max_connections_per_origin => 3,
        max_streams_per_connection => 1,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            my $index = ++$CONNECTIONS;
            my $stream = FairnessClient->connect(
                loop => $LOOP, host => '127.0.0.1',
                port => $listener->port, receive_buffer => 16384,
            );
            $stream->{http_ready} = $ready;
            $stream->{slow} = $index <= 2 ? 1 : 0;
            push @STREAMS, $stream;
        },
        defer => sub ($cb) { $LOOP->defer($cb) },
    );
    for my $key (qw(/slow1 /slow2 /fast)) {
        $CLIENT_DIGEST{$key} = Digest::SHA->new(256);
        $client->request(
            url => "http://localhost$key",
            http_version => $protocol eq 'h2' ? '2' : '1.1',
            on_response => sub ($tx, $resp) {
                push @{ $CLIENT_EVENTS{$key} }, 'headers';
                $ERROR ||= "$key unexpected HTTP status"
                    unless $resp->status == 200;
            },
            on_data => sub ($tx, $bytes) {
                $CLIENT_BYTES{$key} += length($bytes);
                $CLIENT_DIGEST{$key}->add($bytes);
                $CLIENT_CHUNKS{$key}++;
            },
            on_end => sub ($tx) {
                $END_COUNT{$key}++;
                push @{ $CLIENT_EVENTS{$key} }, 'end';
            },
            on_error => sub ($tx, $reason) {
                $ERROR = "$key client HTTP: $reason";
                $LOOP->stop;
            },
            on_finish => sub ($tx) {
                $CLIENT_FINISHED++;
                $CLIENT_TX_COUNT{$key}++;
                $ERROR ||= "$key did not complete"
                    unless $tx->is_complete;
                push @{ $CLIENT_EVENTS{$key} }, 'finish';
                $FAST_BEFORE_RESUME = 1
                    if $key eq '/fast' && !$SLOW_RESUMED;
                $LOOP->stop if $CLIENT_FINISHED == 3 || $ERROR;
            },
        );
    }
    $WATCHDOG = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 20,
        on_timer => sub ($timer) {
            $ERROR = "$protocol fairness watchdog expired";
            $LOOP->stop;
        },
    );
    $LOOP->run;

    is($ERROR, undef, "$protocol concurrent clients finish without error");
    is($CONNECTIONS, 3, "$protocol uses three independent pooled sockets");
    is($SLOW_RESUMED, 2, "$protocol both intentionally slow readers resumed");
    ok($FAST_BEFORE_RESUME, "$protocol fast transfer finishes before slow read release");
    is($CLIENT_FINISHED, 3, "$protocol all three client transactions finish");
    is($SERVER_FINISHED, 3, "$protocol all three server transactions finish");
    ok($MAX_SOCKET_PENDING <= $pending_cap,
        "$protocol sampled socket pending bytes never exceed configured hard cap");
    for my $key (qw(/slow1 /slow2 /fast)) {
        is($CLIENT_BYTES{$key}, $body_length,
            "$protocol $key bytes received exactly once");
        is($CLIENT_DIGEST{$key}->hexdigest, $digest,
            "$protocol $key SHA-256 matches");
        is($END_COUNT{$key}, 1, "$protocol $key on_end once");
        is($CLIENT_TX_COUNT{$key}, 1, "$protocol $key on_finish once");
        is($SERVER_TX_COUNT{$key}, 1, "$protocol $key on_request once");
        is_deeply($CLIENT_EVENTS{$key}, ['headers', 'end', 'finish'],
            "$protocol $key callback order");
        ok(($CLIENT_CHUNKS{$key} || 0) > 1,
            "$protocol $key streamed in multiple chunks");
        ok(($PRODUCERS{$key}{max_burst} || 0) <= 4,
            "$protocol $key producer respects per-tick chunk budget");
    }
    note("$protocol pooled sockets=$CONNECTIONS, producer drain callbacks="
        . "$SERVER_DRAINS, socket drains=$SOCKET_DRAINS, "
        . "maximum sampled socket queue=$MAX_SOCKET_PENDING bytes");
    $WATCHDOG->cancel if $WATCHDOG && $WATCHDOG->is_active;
    $_->cancel if $_->is_active for @TIMERS;
    $_->close unless $_->is_closed for @STREAMS;
    $listener->close if $listener->can('close');
}

done_testing;
