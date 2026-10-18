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

# A new streamed producer joins while another is QUIC-credit-blocked,
# and a third producer is cancelled. Tests the existing fair-share
# implementation through one real authenticated QUIC connection.
my $dir = tempdir(CLEANUP => 1);
my $cert = "$dir/cert.pem";
my $key = "$dir/key.pem";
if (system('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
    '-nodes', '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout', $key, '-out', $cert) != 0) {
    plan skip_all => 'openssl executable required for live H3 TLS';
}

my $loop = Linux::Event::Loop->new;
my ($server, $client, $client_h3, $server_timer, $client_timer, $client_socket);
my ($cancel_timer, $release_timer, $pull_timer, $watchdog);
my ($error, $ready, $requests, $release, $join_started) = (undef, 0, 0, 0, 0);
my (%producer, %server_tx, %server_finish, %client_finish);
my ($keep_tx, $cancel_tx, $late_tx, $keep_reader);
my ($keep_bytes, $keep_chunks, $keep_pulls) = (0, 0, 0);
my ($fast_before_release, $cancel_called, $cancel_client_finish) = (0, 0, 0);
my ($cancel_server_finish, $cancel_native_remaining) = (0, undef);
my ($accounting_samples, $accounting_mismatches, $blocked_total, $resumed_total)
    = (0, 0, 0, 0);
my $keep_digest = Digest::SHA->new(256);
my $part_size = 4096;
my %parts = (keep => 256, cancel => 256, late => 128);
my %payload = (keep => 'K' x $part_size,
               cancel => 'C' x $part_size,
               late => 'L' x $part_size);
my ($schedule, $produce, $sample, $pull, $maybe_stop);

$maybe_stop = sub {
    $loop->stop if $error
        || ($client_finish{keep} && $client_finish{cancel}
            && $client_finish{late} && $client_finish{fast}
            && $cancel_server_finish);
};
$sample = sub {
    return unless $server;
    for my $h3 ($server->sessions) {
        my $native = $h3->{native};
        my $sum = 0;
        for my $name (qw(keep cancel late)) {
            next unless $server_tx{$name};
            $sum += $native->streaming_retained_bytes_for_stream(
                $server_tx{$name}->stream_id);
        }
        $accounting_samples++;
        $accounting_mismatches++
            if $sum != $native->streaming_retained_bytes;
    }
};
$schedule = sub ($name) {
    my $p = $producer{$name} or return;
    return if $p->{queued} || $p->{ended} || $p->{tx}->is_terminal || $error;
    $p->{queued} = 1;
    $loop->defer(sub {
        $p->{queued} = 0;
        $produce->($name);
    });
};
$produce = sub ($name) {
    my $p = $producer{$name} or return;
    return if $p->{waiting} || $p->{ended} || $p->{tx}->is_terminal || $error;
    my $burst = 0;
    while ($p->{issued} < $parts{$name} && $burst < 4) {
        # write(false) means the entire supplied chunk was accepted.
        my $ok = $p->{tx}->write($payload{$name});
        $p->{issued}++;
        $burst++;
        if (!$ok) {
            $p->{waiting} = 1;
            $p->{blocked}++;
            $blocked_total++;
            last;
        }
    }
    $p->{max_burst} = $burst if $burst > $p->{max_burst};
    $sample->();
    if ($p->{issued} == $parts{$name} && !$p->{waiting}) {
        $p->{ended}++;
        $p->{tx}->end;
    } elsif (!$p->{waiting}) {
        $schedule->($name);
    }
};

my $server_socket = Linux::Event::IO::Sock::Dgram->new(
    loop => $loop, host => '127.0.0.1', port => 0,
    on_datagram => sub ($socket, $bytes, $peer) {
        $server->receive($bytes, $socket->local->sockaddr, $peer->sockaddr);
        $sample->();
    },
    on_drain => sub ($socket) { $server->writable },
    on_error => sub ($socket, $e) { $error = "server UDP: $e"; $loop->stop },
);
$server = Unblock::HTTP::QUIC->server(
    certificate_file => $cert, private_key_file => $key,
    server => Unblock::HTTP::Server->new(
        http3 => { send_buffer_limit => 8192 },
        on_headers => sub ($tx, $request) {
            my $name = substr($request->target, 1);
            return unless $name eq 'cancel';
            $tx->on_finish(sub ($finished) {
                $server_finish{$name}++;
                $cancel_server_finish++;
                $error ||= 'server cancel transaction was not cancelled'
                    unless $finished->is_cancelled;
                $cancel_native_remaining = $server->sessions
                    ? ($server->sessions)[0]{native}
                        ->streaming_retained_bytes_for_stream(
                            $finished->stream_id)
                    : undef;
                $sample->();
                $maybe_stop->();
            });
        },
        on_request => sub ($tx, $request) {
            my $name = substr($request->target, 1);
            $requests++;
            if ($name eq 'fast') {
                $tx->respond(status => 200, body => 'fast-and-complete');
                return;
            }
            if (!exists $parts{$name}) {
                $error = "unexpected H3 path $name";
                $loop->stop;
                return;
            }
            $server_tx{$name} = $tx;
            my $p = $producer{$name} = {
                tx => $tx, issued => 0, waiting => 0, queued => 0,
                blocked => 0, resumed => 0, ended => 0, max_burst => 0,
            };
            $tx->respond(status => 200, stream_body => 1,
                on_drain => sub ($live_tx) {
                    $error ||= "producer identity changed: $name"
                        if refaddr($live_tx) != refaddr($p->{tx});
                    if ($p->{waiting} && !$p->{tx}->is_terminal) {
                        $p->{waiting} = 0;
                        $p->{resumed}++;
                        $resumed_total++;
                        $schedule->($name);
                    }
                },
            );
            $schedule->($name);
        },
        on_error => sub ($tx, $e) {
            $error = "server HTTP3: $e";
            $loop->stop;
        },
    ),
    send => sub ($datagram) {
        $server_socket->send($datagram->data,
            to => Linux::Event::Address->new($datagram->peer));
    },
    set_timeout => sub ($seconds) {
        $server_timer->cancel if $server_timer && $server_timer->is_active;
        undef $server_timer;
        if (defined $seconds) {
            $server_timer = Linux::Event::Kernel::Timer->new(
                loop => $loop, after => $seconds,
                on_timer => sub ($t) { undef $server_timer; $server->timeout },
            );
        }
    },
);
$server->start;

$pull = sub {
    return unless $release && $keep_reader && !$error;
    $keep_pulls++;
    my $burst = 0;
    while ($burst < 8) {
        my $bytes = $keep_reader->next_chunk;
        last unless defined $bytes;
        $keep_bytes += length($bytes);
        $keep_chunks++;
        $keep_digest->add($bytes);
        $burst++;
    }
    $sample->();
    return if $client_finish{keep} || $error;
    if ($keep_reader->pending_bytes > 0) {
        $loop->defer(sub { $pull->() });
    } else {
        $pull_timer = Linux::Event::Kernel::Timer->new(
            loop => $loop, after => 0.005,
            on_timer => sub ($t) { undef $pull_timer; $pull->() },
        );
    }
};
$client_socket = Linux::Event::IO::Sock::Dgram->connect(
    loop => $loop, host => '127.0.0.1',
    port => $server_socket->local->port,
    on_ready => sub ($sock) {
        $client = Unblock::HTTP::QUIC->client(
            local => $sock->local->sockaddr,
            peer => $sock->peer->sockaddr,
            alpn => 'h3', server_name => 'localhost', ca_file => $cert,
            http3 => { receive_body => 'buffered' },
            transport => {
                stream_window => 32768,
                connection_window => 262144,
            },
            on_ready => sub ($h3, $manager) {
                $ready++;
                $client_h3 = $h3;
                $keep_tx = $h3->request(
                    method => 'GET', scheme => 'https',
                    authority => 'localhost', target => '/keep',
                    receive_body => 'stream',
                    on_response => sub ($tx, $response) {
                        $error ||= 'bad keep status' unless $response->status == 200;
                        $keep_reader = $tx->response_body;
                    },
                    on_error => sub ($tx, $e) {
                        $error = "keep response: $e"; $loop->stop;
                    },
                    on_finish => sub ($tx) {
                        $error ||= 'keep did not complete' unless $tx->is_complete;
                        $client_finish{keep}++;
                        $maybe_stop->();
                    },
                );
                $cancel_tx = $h3->request(
                    method => 'GET', scheme => 'https',
                    authority => 'localhost', target => '/cancel',
                    receive_body => 'stream',
                    on_error => sub ($tx, $e) {
                        $error = "cancel response raised on_error: $e";
                        $loop->stop;
                    },
                    on_finish => sub ($tx) {
                        $error ||= 'cancel did not mark cancelled'
                            unless $tx->is_cancelled;
                        $cancel_client_finish++;
                        $client_finish{cancel}++;
                        $maybe_stop->();
                    },
                );
                my $fast_tx = $h3->request(
                    method => 'GET', scheme => 'https',
                    authority => 'localhost', target => '/fast',
                    on_complete => sub ($tx) {
                        $error ||= 'bad fast body'
                            unless $tx->response->body eq 'fast-and-complete';
                    },
                    on_error => sub ($tx, $e) {
                        $error = "fast response: $e"; $loop->stop;
                    },
                    on_finish => sub ($tx) {
                        $error ||= 'fast did not complete' unless $tx->is_complete;
                        $client_finish{fast}++;
                        $fast_before_release = 1 unless $release;
                        $maybe_stop->();
                    },
                );
                $error ||= 'initial requests were not admitted'
                    unless $keep_tx && $cancel_tx && $fast_tx;
                $cancel_timer = Linux::Event::Kernel::Timer->new(
                    loop => $loop, after => 0.5,
                    on_timer => sub ($t) {
                        undef $cancel_timer;
                        $error ||= 'cancel producer never started'
                            unless $server_tx{cancel};
                        $error ||= 'keep producer never started'
                            unless $server_tx{keep};
                        if ($error) { $loop->stop; return }
                        $cancel_called++;
                        $cancel_tx->cancel;
                        $cancel_tx->cancel; # idempotent
                        $join_started++;
                        $late_tx = $client_h3->request(
                            method => 'GET', scheme => 'https',
                            authority => 'localhost', target => '/late',
                            on_complete => sub ($tx) {
                                $error ||= 'late response body mismatch'
                                    unless $tx->response->body
                                        eq $payload{late} x $parts{late};
                            },
                            on_error => sub ($tx, $e) {
                                $error = "late response: $e";
                                $loop->stop;
                            },
                            on_finish => sub ($tx) {
                                $error ||= 'late did not complete'
                                    unless $tx->is_complete;
                                $client_finish{late}++;
                                $maybe_stop->();
                            },
                        );
                        $error ||= 'late producer request was not admitted'
                            unless $late_tx;
                        $sample->();
                    },
                );
                $release_timer = Linux::Event::Kernel::Timer->new(
                    loop => $loop, after => 1.0,
                    on_timer => sub ($t) {
                        undef $release_timer;
                        $release = 1;
                        $error ||= 'keep Reader missing at release'
                            unless $keep_reader;
                        $error ||= 'keep prematurely completed'
                            if $client_finish{keep};
                        $pull->() unless $error;
                        $loop->stop if $error;
                    },
                );
            },
            send => sub ($datagram) { $sock->send($datagram->data) },
            set_timeout => sub ($seconds) {
                $client_timer->cancel if $client_timer && $client_timer->is_active;
                undef $client_timer;
                if (defined $seconds) {
                    $client_timer = Linux::Event::Kernel::Timer->new(
                        loop => $loop, after => $seconds,
                        on_timer => sub ($t) {
                            undef $client_timer; $client->timeout;
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
        $sample->();
    },
    on_drain => sub ($sock) { $client->writable if $client },
    on_error => sub ($sock, $e) { $error = "client UDP: $e"; $loop->stop },
);
$watchdog = Linux::Event::Kernel::Timer->new(
    loop => $loop, after => 35,
    on_timer => sub ($t) {
        $error = 'join/cancel watchdog expired'
            . ' requests=' . $requests
            . ' outcomes=' . join(',', map { "$_:" . ($client_finish{$_} // 0) }
                qw(keep cancel late fast))
            . ' server_cancel=' . $cancel_server_finish
            . ' produced=' . join(',', map {
                "$_:" . ($producer{$_}{issued} // 0)
              } qw(keep cancel late));
        $loop->stop;
    },
);
$loop->run;

is($error, undef, 'H3 producer join/cancel traffic completes without failure');
is($ready, 1, 'one authenticated H3 connection');
is($requests, 4, 'all four multiplexed HTTP3 paths reached server');
is($cancel_called, 1, 'cancel invoked once, repeated cancel idempotent');
is($join_started, 1, 'late response begins after cancellation');
is($cancel_client_finish, 1, 'cancelled client transaction finishes once');
is($cancel_server_finish, 1, 'cancelled server transaction finishes once');
is($server_finish{cancel}, 1, 'server cancellation terminal callback once');
is($cancel_native_remaining, 0, 'cancel releases native body storage for its stream');
is($client_finish{keep}, 1, 'held keep response completes once');
is($client_finish{late}, 1, 'newly joined late response completes once');
is($client_finish{fast}, 1, 'small independent response completes once');
ok($fast_before_release, 'small response finishes without waiting for held Reader');
is($keep_bytes, $part_size * $parts{keep}, 'held Reader eventually receives all bytes');
is($keep_digest->hexdigest, sha256_hex($payload{keep} x $parts{keep}),
    'held Reader payload SHA-256 matches');
ok($keep_chunks > 1 && $keep_pulls > 1,
    'held Reader consumes incrementally over multiple turns');
for my $name (qw(keep late)) {
    is($producer{$name}{issued}, $parts{$name},
        "$name producer issues every complete chunk exactly once");
    is($producer{$name}{ended}, 1, "$name response calls end once");
    cmp_ok($producer{$name}{max_burst}, '<=', 4,
        "$name producer respects four-write fairness limit");
    ok($producer{$name}{blocked} > 0 && $producer{$name}{resumed} > 0,
        "$name producer blocks and resumes with tight native budget");
    is($producer{$name}{blocked}, $producer{$name}{resumed},
        "$name drain resumptions match blocked writes");
}
cmp_ok($producer{cancel}{issued}, '<', $parts{cancel},
    'cancelled producer did not submit its whole large body');
is($producer{cancel}{ended}, 0, 'cancelled producer never calls end');
ok($accounting_samples > 0, 'native counters observed during active requests');
is($accounting_mismatches, 0,
    'native outgoing per-stream counts reconcile through join/cancel/EOF');
note("H3 join/cancel native samples=$accounting_samples"
    . ", blocked=$blocked_total resumed=$resumed_total"
    . ", keep pulls=$keep_pulls, cancel issued="
    . ($producer{cancel}{issued} // 0));
for my $timer ($cancel_timer, $release_timer, $pull_timer,
               $watchdog, $server_timer, $client_timer) {
    $timer->cancel if $timer && $timer->is_active;
}
done_testing;
