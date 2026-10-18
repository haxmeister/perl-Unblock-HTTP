use v5.36;
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(refaddr);
use File::Temp qw(tempdir);

use Linux::Event::IO::Sock::Dgram;
use Linux::Event::Address;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Unblock::HTTP::QUIC;
use Unblock::HTTP::Server;

# Six H3 1 MiB producers and an independent fast stream share one QUIC
# connection with 8192 bytes of advisory native producer send budget.
# Each of six pull Readers owns its receive credit; release sequentially.
# This is a real-socket load and fairness regression, not a memory cap.
my $dir = tempdir(CLEANUP => 1);
my $cert = "$dir/cert.pem";
my $key = "$dir/key.pem";
if (system('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
    '-nodes', '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout', $key, '-out', $cert) != 0) {
    plan skip_all => 'openssl is needed for the QUIC TLS fixture';
}

my $loop = Linux::Event::Loop->new;
my ($server, $client, $server_timer, $client_timer, $client_socket);
my ($hold_timer, $poll_timer, $watchdog);
my ($error, $ready, $requests, $completed) = (undef, 0, 0, 0);
my $streams = 6;
my $send_limit = 8192;
my $chunk = '0123456789abcdef' x 256;  # 4 KiB
my $parts = 256;                       # 1 MiB per slow stream
my $length = length($chunk) * $parts;
my $expected_digest = sha256_hex($chunk x $parts);
my (@server_tx, @client_tx, @reader, @digests, @received, @received_chunks,
    @produced, @blocked, @resumed, @drains, @ends, @waiting, @queued,
    @finished, @producer_turns, @max_burst, @max_pending);
my ($fast_finished, $fast_before_release) = (0, 0);
my ($released, $hold_observed, $release_stage) = (0, 0, -1);
my (@pending_at_release, @produced_at_release);
my (@finished_at_stage, @received_at_stage);
my $poll_turns = 0;
my ($quic_peak, $quic_samples) = (0, 0);
my ($native_samples, $native_accounting_mismatches, $native_retained_peak)
    = (0, 0, 0);
my @native_stream_peak = (0) x $streams;
my ($schedule, $emit, $poll, $advance);

for my $i (0 .. $streams - 1) {
    $digests[$i] = Digest::SHA->new(256);
    $received[$i] = 0;
    $received_chunks[$i] = 0;
    $produced[$i] = 0;
    $blocked[$i] = 0;
    $resumed[$i] = 0;
    $drains[$i] = 0;
    $ends[$i] = 0;
    $waiting[$i] = 0;
    $queued[$i] = 0;
    $finished[$i] = 0;
    $producer_turns[$i] = 0;
    $max_burst[$i] = 0;
    $max_pending[$i] = 0;
}

my $sample_quic = sub {
    return unless $server;
    for my $session ($server->sessions) {
        my $bytes = $session->quic->send_buffered_bytes;
        $quic_samples++;
        $quic_peak = $bytes if $bytes > $quic_peak;
    }
    # Test-only native observation: reconcile the complete per-stream
    # provider body storage with its connection-wide retained counter.
    # These do not include QUIC, TLS, kernel, or allocator memory.
    for my $http ($server->sessions) {
        my $native = $http->{native};
        my $connection_bytes = $native->streaming_retained_bytes;
        $native_samples++;
        $native_retained_peak = $connection_bytes
            if $connection_bytes > $native_retained_peak;
        my $sum = 0;
        for my $i (0 .. $streams - 1) {
            next unless $server_tx[$i];
            my $bytes = $native->streaming_retained_bytes_for_stream(
                $server_tx[$i]->stream_id
            );
            $sum += $bytes;
            $native_stream_peak[$i] = $bytes
                if $bytes > $native_stream_peak[$i];
        }
        $native_accounting_mismatches++ if $sum != $connection_bytes;
    }
};
my $sample_readers = sub {
    for my $i (0 .. $streams - 1) {
        next unless $reader[$i];
        my $bytes = $reader[$i]->pending_bytes;
        $max_pending[$i] = $bytes if $bytes > $max_pending[$i];
    }
};

$schedule = sub ($i) {
    return if $queued[$i] || $ends[$i] || $error;
    $queued[$i] = 1;
    $loop->defer(sub {
        $queued[$i] = 0;
        $emit->($i);
    });
};
$emit = sub ($i) {
    return if !$server_tx[$i] || $waiting[$i] || $ends[$i] || $error;
    my $burst = 0;
    $producer_turns[$i]++;
    while ($produced[$i] < $parts && $burst < 4) {
        # False means this complete chunk was accepted. Do not replay it.
        my $ok = $server_tx[$i]->write($chunk);
        $produced[$i]++;
        $burst++;
        if (!$ok) {
            $waiting[$i] = 1;
            $blocked[$i]++;
            last;
        }
    }
    $max_burst[$i] = $burst if $burst > $max_burst[$i];
    $sample_quic->();
    if ($produced[$i] == $parts && !$waiting[$i]) {
        $ends[$i]++;
        $server_tx[$i]->end;
    } elsif (!$waiting[$i]) {
        $schedule->($i);
    }
};

my $server_socket = Linux::Event::IO::Sock::Dgram->new(
    loop => $loop, host => '127.0.0.1', port => 0,
    on_datagram => sub ($socket, $bytes, $peer) {
        $server->receive($bytes, $socket->local->sockaddr, $peer->sockaddr);
        $sample_quic->();
    },
    on_drain => sub ($socket) { $server->writable },
    on_error => sub ($socket, $e) {
        $error = "server UDP: $e";
        $loop->stop;
    },
);
$server = Unblock::HTTP::QUIC->server(
    certificate_file => $cert, private_key_file => $key,
    server => Unblock::HTTP::Server->new(
        http3 => { send_buffer_limit => $send_limit },
        on_request => sub ($tx, $request) {
            my $target = $request->target;
            $requests++;
            if ($target =~ m{\A/slow([0-5])\z}) {
                my $i = $1;
                $server_tx[$i] = $tx;
                $tx->respond(status => 200, stream_body => 1,
                    on_drain => sub ($live_tx) {
                        $drains[$i]++;
                        $error ||= "producer identity changed for slow$i"
                            if refaddr($live_tx) != refaddr($server_tx[$i]);
                        if ($waiting[$i]) {
                            $waiting[$i] = 0;
                            $resumed[$i]++;
                            $schedule->($i);
                        }
                    },
                );
                $schedule->($i);
            } elsif ($target eq '/fast') {
                $tx->respond(status => 200, body => 'fast-and-complete');
            } else {
                $error = "unexpected H3 request $target";
                $loop->stop;
            }
        },
        on_error => sub ($tx, $e) {
            $error = "server H3: $e";
            $loop->stop;
        },
    ),
    send => sub ($datagram) {
        $server_socket->send(
            $datagram->data,
            to => Linux::Event::Address->new($datagram->peer),
        );
    },
    set_timeout => sub ($seconds) {
        $server_timer->cancel if $server_timer && $server_timer->is_active;
        undef $server_timer;
        if (defined $seconds) {
            $server_timer = Linux::Event::Kernel::Timer->new(
                loop => $loop, after => $seconds,
                on_timer => sub ($t) {
                    undef $server_timer;
                    $server->timeout;
                },
            );
        }
    },
);
$server->start;

# Release exactly one Reader at a time. A different response still has no
# receive credit merely because the first Reader is now being consumed.
$poll = sub {
    my $i = $release_stage;
    return if $i < 0 || $i >= $streams || $error;
    # A late response HEADERS callback is possible under contention.
    # Wait for this stream's Reader without granting credit to siblings.
    if (!$reader[$i]) {
        $poll_timer = Linux::Event::Kernel::Timer->new(
            loop => $loop, after => 0.005,
            on_timer => sub ($t) {
                undef $poll_timer;
                $poll->();
            },
        );
        return;
    }
    $poll_turns++;
    my $burst = 0;
    while ($burst < 8) {
        my $bytes = $reader[$i]->next_chunk;
        last unless defined $bytes;
        $digests[$i]->add($bytes);
        $received[$i] += length($bytes);
        $received_chunks[$i]++;
        $burst++;
    }
    $sample_readers->();
    return if $finished[$i] || $error;
    if ($reader[$i]->pending_bytes > 0) {
        $loop->defer(sub { $poll->() });
    } else {
        $poll_timer = Linux::Event::Kernel::Timer->new(
            loop => $loop, after => 0.005,
            on_timer => sub ($t) {
                undef $poll_timer;
                $poll->();
            },
        );
    }
};
$advance = sub {
    # At each stage, capture all other streams' completion and byte state.
    my $next = ++$release_stage;
    return if $next >= $streams;
    $released++;
    $finished_at_stage[$next] = [@finished];
    $received_at_stage[$next] = [@received];
    $poll->();
};

$client_socket = Linux::Event::IO::Sock::Dgram->connect(
    loop => $loop, host => '127.0.0.1',
    port => $server_socket->local->port,
    on_ready => sub ($sock) {
        $client = Unblock::HTTP::QUIC->client(
            local => $sock->local->sockaddr,
            peer => $sock->peer->sockaddr,
            alpn => 'h3',
            server_name => 'localhost',
            ca_file => $cert,
            http3 => { receive_body => 'buffered' },
            transport => {
                stream_window => 32768,
                # Six independent 32 KiB Readers plus fast response.
                connection_window => 262144,
            },
            on_ready => sub ($h3, $manager) {
                $ready++;
                for my $i (0 .. $streams - 1) {
                    $client_tx[$i] = $h3->request(
                        method => 'GET', scheme => 'https',
                        authority => 'localhost', target => "/slow$i",
                        receive_body => 'stream',
                        on_response => sub ($tx, $response) {
                            $error ||= "bad response status for slow$i"
                                unless $response->status == 200;
                            $error ||= "client identity changed for slow$i"
                                if refaddr($tx) != refaddr($client_tx[$i]);
                            $reader[$i] = $tx->response_body;
                        },
                        on_error => sub ($tx, $e) {
                            $error = "slow$i HTTP3 response: $e";
                            $loop->stop;
                        },
                        on_finish => sub ($tx) {
                            $error ||= "slow$i did not complete"
                                unless $tx->is_complete;
                            $finished[$i]++;
                            $completed++;
                            if ($i == $release_stage && $i < $streams - 1) {
                                $poll_timer->cancel
                                    if $poll_timer && $poll_timer->is_active;
                                undef $poll_timer;
                                $advance->();
                            }
                            $loop->stop if $completed == $streams + 1 || $error;
                        },
                    );
                    $error ||= "slow$i request was not admitted"
                        unless $client_tx[$i];
                }
                my $fast = $h3->request(
                    method => 'GET', scheme => 'https',
                    authority => 'localhost', target => '/fast',
                    on_complete => sub ($tx) {
                        $error ||= 'wrong fast response body'
                            unless $tx->response->body eq 'fast-and-complete';
                    },
                    on_error => sub ($tx, $e) {
                        $error = "fast HTTP3 response: $e";
                        $loop->stop;
                    },
                    on_finish => sub ($tx) {
                        $error ||= 'fast stream did not complete'
                            unless $tx->is_complete;
                        $fast_finished++;
                        $fast_before_release = 1 if !$hold_observed;
                        $completed++;
                        $loop->stop if $completed == $streams + 1 || $error;
                    },
                );
                $error ||= 'fast request was not admitted' unless $fast;
                $hold_timer = Linux::Event::Kernel::Timer->new(
                    loop => $loop, after => 0.5,
                    on_timer => sub ($t) {
                        $hold_observed = 1;
                        $sample_readers->();
                        $sample_quic->();
                        for my $i (0 .. $streams - 1) {
                            $pending_at_release[$i] = $reader[$i]
                                ? $reader[$i]->pending_bytes : 0;
                            $produced_at_release[$i] = $produced[$i];
                            $error ||= "slow$i producer absent at hold"
                                unless $server_tx[$i] && $produced[$i] > 0;
                            $error ||= "slow$i completed with credit held"
                                if $finished[$i];
                        }
                        $advance->() unless $error;
                        $loop->stop if $error;
                    },
                );
                $loop->stop if $error;
            },
            send => sub ($datagram) { $sock->send($datagram->data) },
            set_timeout => sub ($seconds) {
                $client_timer->cancel
                    if $client_timer && $client_timer->is_active;
                undef $client_timer;
                if (defined $seconds) {
                    $client_timer = Linux::Event::Kernel::Timer->new(
                        loop => $loop, after => $seconds,
                        on_timer => sub ($t) {
                            undef $client_timer;
                            $client->timeout;
                        },
                    );
                }
            },
        );
        $client->start;
    },
    on_datagram => sub ($sock, $bytes, $peer) {
        $client->receive($bytes, $sock->local->sockaddr, $peer->sockaddr)
            if $client;
        $sample_readers->();
    },
    on_drain => sub ($sock) { $client->writable if $client },
    on_error => sub ($sock, $e) {
        $error = "client UDP: $e";
        $loop->stop;
    },
);
$watchdog = Linux::Event::Kernel::Timer->new(
    loop => $loop, after => 60,
    on_timer => sub ($t) {
        $sample_readers->();
        my @sessions = $server->sessions;
        my @quic = map { $_->quic->send_buffered_bytes } @sessions;
        my @native = map { $_->{native}->streaming_retained_bytes } @sessions;
        $error = 'multi-Reader QUIC watchdog expired'
            . ' produced=' . join(',', @produced)
            . ' received=' . join(',', @received)
            . ' pending=' . join(',', map { $_ ? $_->pending_bytes : -1 } @reader)
            . ' quic_send=' . join(',', @quic)
            . ' native_body=' . join(',', @native);
        $loop->stop;
    },
);
$loop->run;

is($error, undef, 'six independently held H3 Readers complete without starvation');
is($ready, 1, 'all four requests use one authenticated H3 connection');
is($requests, $streams + 1, 'one upper Server receives all multiplexed requests');
is($fast_finished, 1, 'small H3 response completed once');
ok($fast_before_release, 'fast response finished while six Readers held credit');
is($hold_observed, 1, 'all slow Readers were held before credit release');
is($released, $streams, 'six Readers released one at a time');
is($completed, $streams + 1, 'all four requests completed');
my $pending_sum = 0;
$pending_sum += $_ for @pending_at_release;
ok($pending_sum > 0, 'at least one held Reader has uncredited body data');
for my $i (0 .. $streams - 1) {
    if ($send_limit >= $length * $streams) {
        ok($pending_at_release[$i] > 0,
            "slow$i retained data with ample native producer budget");
    }
    cmp_ok($pending_at_release[$i], '<=', 32768,
        "slow$i hold fits advertised individual stream window");
    ok($produced_at_release[$i] > 0,
        "slow$i producer began before receive credit was released");
    if ($send_limit < $length * $streams) {
        cmp_ok($produced_at_release[$i], '<', $parts,
            "slow$i producer is held below completion by shared native budget");
    }
    cmp_ok($max_pending[$i], '<=', 32768,
        "slow$i sampled Reader queue is within stream window");
    is($finished[$i], 1, "slow$i finished exactly once");
    is($received[$i], $length, "slow$i receives its full 1 MiB");
    is($digests[$i]->hexdigest, $expected_digest,
        "slow$i payload digest matches");
    ok($received_chunks[$i] > 1, "slow$i was incrementally consumed");
    is($produced[$i], $parts, "slow$i producer accepted every chunk");
    is($ends[$i], 1, "slow$i producer ended only once");
    if ($send_limit < $length * $streams) {
        ok($blocked[$i] > 0 && $resumed[$i] > 0,
            "slow$i producer really blocked and later resumed");
        is($blocked[$i], $resumed[$i],
            "slow$i received one resumption for each blocked write");
    }
    is($blocked[$i], $resumed[$i],
        "slow$i resume count matches accepted-but-blocked writes");
    cmp_ok($max_burst[$i], '<=', 4,
        "slow$i producer stays within event-turn write budget");
    ok($producer_turns[$i] > 1, "slow$i producer spans deferred turns");
}
for my $stage (1 .. $streams - 1) {
    for my $i ($stage .. $streams - 1) {
        is($finished_at_stage[$stage][$i], 0,
            "slow$i still incomplete before Reader slow$stage released");
        is($received_at_stage[$stage][$i], 0,
            "slow$i received no credited chunks before its release");
    }
}
ok($poll_turns > 1, 'Reader polling is scheduled across event-loop turns');
ok($quic_samples > 0, 'public QUIC retained-send counter sampled');
ok($native_samples > 0, 'native HTTP3 per-stream provider counters sampled');
is($native_accounting_mismatches, 0,
    'native per-stream streaming retention sums to connection total');
note("H3 slow Reader pending=" . join(',', @pending_at_release)
    . ", produced before release=" . join(',', @produced_at_release)
    . ", QUIC peak sampled=$quic_peak, poll turns=$poll_turns"
    . ", send_limit=$send_limit, native peak=$native_retained_peak"
    . ", native per-stream peaks=" . join(',', @native_stream_peak)
    . ", producer blocks=" . join(',', @blocked));

for my $timer ($hold_timer, $poll_timer, $watchdog, $server_timer, $client_timer) {
    $timer->cancel if $timer && $timer->is_active;
}
done_testing;
