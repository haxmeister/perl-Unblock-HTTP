use v5.36;
use strict;
use warnings;
use Time::HiRes qw(time);
use File::Temp qw(tempdir);
use Linux::Event::IO::Sock::Dgram;
use Linux::Event::Address;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Net::QUIC::Driver;
use Unblock::HTTP::QUIC;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use Unblock::HTTP3::Client;

# Opt-in workload profiler. Not a CI performance gate.
# Same HTTP3 Server, Net::QUIC::Driver, TLS, payload, and UDP loopback
# on both paths. One connection per trial; concurrency is strictly bounded.
# CPU is per-process user+system; VmRSS is sampled, not peak allocator usage.
my ($samples, $warmup, $rounds, $concurrency, $body_bytes) = @ARGV;
$samples     //= 150;
$warmup      //= 24;
$rounds      //= 3;
$concurrency //= 4;
$body_bytes  //= 16384;
die "usage: perl bench/h3-workload-profile.pl [samples] [warmup] [rounds] [inflight] [response_bytes]\n"
    unless $samples =~ /\A[1-9][0-9]*\z/ && $samples <= 20000
        && $warmup =~ /\A[1-9][0-9]*\z/ && $warmup <= 2000
        && $rounds =~ /\A[1-9][0-9]*\z/ && $rounds <= 15
        && $concurrency =~ /\A[1-9][0-9]*\z/ && $concurrency <= 16
        && $body_bytes =~ /\A[1-9][0-9]*\z/ && $body_bytes <= 1048576;

my $body = 'B' x $body_bytes;
my $dir = tempdir(CLEANUP => 1);
my $cert = "$dir/cert.pem";
my $key = "$dir/key.pem";
die "openssl needed for benchmark TLS certificate\n"
    if system('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
        '-nodes', '-days', '1', '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
        '-keyout', $key, '-out', $cert) != 0;

sub sampled_rss_kib {
    open my $fh, '<', '/proc/self/status' or return undef;
    while (my $line = <$fh>) {
        if ($line =~ /^VmRSS:\s+(\d+)\s+kB/) {
            close $fh;
            return 0 + $1;
        }
    }
    close $fh;
    return undef;
}

sub percentile {
    my ($sorted, $p) = @_;
    return 0 unless @$sorted;
    my $index = int(($p / 100) * (@$sorted - 1) + 0.5);
    return $sorted->[$index];
}

sub run_trial ($mode) {
    my $loop = Linux::Event::Loop->new;
    my ($server, $server_socket, $server_timer, $driver, $client_socket,
        $client_timer, $quic, $direct, $unified, $factory_ready);
    my ($attached, $error, $sent, $finished, $inflight, $max_inflight,
        $responses, $pump_queued) = (0, undef, 0, 0, 0, 0, 0, 0);
    my ($phase, $phase_target) = ('warmup', $warmup);
    my ($elapsed, $cpu_seconds, $call_seconds, $call_count)
        = (undef, undef, 0, 0);
    my ($start, $rss_start, $rss_peak, $rss_end, @cpu_before);
    my @latency;
    my ($pump, $schedule, $check_ready, $sample_rss);

    $sample_rss = sub {
        my $rss = sampled_rss_kib();
        return unless defined $rss;
        $rss_peak = $rss if !defined($rss_peak) || $rss > $rss_peak;
    };
    $schedule = sub {
        return if $pump_queued || $error;
        $pump_queued = 1;
        $loop->defer(sub {
            $pump_queued = 0;
            $pump->();
        });
    };

    $pump = sub {
        return if $error || $phase eq 'finished';
        while ($sent < $phase_target && $inflight < $concurrency) {
            $sent++;
            $inflight++;
            $max_inflight = $inflight if $inflight > $max_inflight;
            my $issued_at = time();
            my $measured = $phase eq 'measure' ? 1 : 0;
            my $saw_response = 0;
            my $on_response = sub ($tx, $response) {
                if (!$response || $response->status != 200
                    || $response->body ne $body) {
                    $error = "$mode response body/status mismatch";
                    $loop->stop;
                    return;
                }
                $saw_response++;
            };
            my $on_finish = sub ($tx) {
                if (!$tx->is_complete || $saw_response != 1) {
                    $error = "$mode incomplete/duplicate response callback";
                    $loop->stop;
                    return;
                }
                $inflight--;
                $finished++;
                if ($measured) {
                    push @latency, 1_000_000 * (time() - $issued_at);
                    $sample_rss->() if $finished % 16 == 0;
                }
                if ($finished == $phase_target && !$inflight) {
                    if ($phase eq 'warmup') {
                        $phase = 'measure';
                        $phase_target = $samples;
                        ($sent, $finished, $max_inflight) = (0, 0, 0);
                        @cpu_before = times();
                        $start = time();
                        $rss_start = sampled_rss_kib();
                        $rss_peak = $rss_start;
                        $schedule->();
                    } else {
                        $elapsed = time() - $start;
                        my @after = times();
                        $cpu_seconds = $after[0] + $after[1]
                            - $cpu_before[0] - $cpu_before[1];
                        $rss_end = sampled_rss_kib();
                        $sample_rss->();
                        $phase = 'finished';
                        $loop->stop;
                    }
                } else {
                    $schedule->();
                }
            };
            my $on_error = sub ($tx, $e) {
                $error = "$mode HTTP3 error: $e";
                $loop->stop;
            };
            my $call_start = time() if $measured;
            my $request;
            if ($mode eq 'direct') {
                $request = $direct->request(
                    method => 'GET', scheme => 'https',
                    authority => 'localhost', target => '/profile',
                    receive_body => 'buffered',
                    on_complete => sub ($tx) {
                        $on_response->($tx, $tx->response);
                    },
                    on_error => $on_error,
                    on_finish => $on_finish,
                );
            } else {
                $request = $unified->request(
                    method => 'GET', url => 'https://localhost/profile',
                    http_version => '3',
                    on_response => $on_response,
                    on_error => $on_error,
                    on_finish => $on_finish,
                );
            }
            if (!defined $request) {
                $error = "$mode did not admit request at inflight=$inflight";
                $loop->stop;
                return;
            }
            if ($measured) {
                $call_seconds += time() - $call_start;
                $call_count++;
            }
        }
    };

    $server_socket = Linux::Event::IO::Sock::Dgram->new(
        loop => $loop, host => '127.0.0.1', port => 0,
        on_datagram => sub ($socket, $bytes, $peer) {
            $server->receive($bytes, $socket->local->sockaddr, $peer->sockaddr);
        },
        on_drain => sub ($socket) { $server->writable },
        on_error => sub ($socket, $e) {
            $error = "server UDP: $e"; $loop->stop;
        },
    );
    $server = Unblock::HTTP::QUIC->server(
        certificate_file => $cert, private_key_file => $key,
        server => Unblock::HTTP::Server->new(
            http3 => {},
            on_request => sub ($tx, $request) {
                $responses++;
                $tx->respond(status => 200, body => $body);
            },
            on_error => sub ($tx, $e) {
                $error = "server HTTP3: $e"; $loop->stop;
            },
        ),
        send => sub ($packet) {
            $server_socket->send($packet->data,
                to => Linux::Event::Address->new($packet->peer));
        },
        set_timeout => sub ($seconds) {
            $server_timer->cancel if $server_timer && $server_timer->is_active;
            undef $server_timer;
            if (defined $seconds) {
                $server_timer = Linux::Event::Kernel::Timer->new(
                    loop => $loop, after => $seconds,
                    on_timer => sub ($timer) {
                        undef $server_timer;
                        $server->timeout;
                    },
                );
            }
        },
    );
    $server->start;

    $check_ready = sub {
        return if $attached || !$quic || !$quic->ready;
        return if $mode eq 'unified' && !$factory_ready;
        $attached = 1;
        if ($mode eq 'direct') {
            $direct = Unblock::HTTP3::Client->new(
                quic => $quic,
                receive_body => 'buffered',
                max_buffered_body_bytes => 1048576,
            );
            $direct->start;
            $schedule->();
        } else {
            $factory_ready->(connection => $quic, verified_origin => 1);
        }
    };

    $client_socket = Linux::Event::IO::Sock::Dgram->connect(
        loop => $loop, host => '127.0.0.1',
        port => $server_socket->local->port,
        on_ready => sub ($socket) {
            if ($mode eq 'unified') {
                $unified = Unblock::HTTP::Client->new(
                    http3 => {},
                    max_connections_per_origin => 1,
                    max_streams_per_connection => $concurrency,
                    max_pending_requests => $concurrency + 4,
                    connect_quic => sub {
                        my ($origin, $ready) = @_;
                        $factory_ready = $ready;
                        $check_ready->();
                    },
                    defer => sub {
                        my ($callback) = @_;
                        $loop->defer($callback);
                    },
                );
                # Requests may queue until the authenticated QUIC is ready.
                $schedule->();
            }
            $driver = Net::QUIC::Driver->client(
                local => $socket->local->sockaddr,
                peer => $socket->peer->sockaddr,
                alpn => 'h3', server_name => 'localhost', ca_file => $cert,
                send => sub ($packet) { $socket->send($packet->data) },
                set_timeout => sub ($seconds) {
                    $client_timer->cancel if $client_timer && $client_timer->is_active;
                    undef $client_timer;
                    if (defined $seconds) {
                        $client_timer = Linux::Event::Kernel::Timer->new(
                            loop => $loop, after => $seconds,
                            on_timer => sub ($timer) {
                                undef $client_timer;
                                $driver->timeout;
                                $check_ready->();
                            },
                        );
                    }
                },
            );
            $quic = $driver->connection;
            $driver->start;
            $check_ready->();
        },
        on_datagram => sub ($socket, $bytes, $peer) {
            if ($driver) {
                $driver->receive(
                    $bytes, $socket->local->sockaddr, $peer->sockaddr);
                $check_ready->();
            }
        },
        on_drain => sub ($socket) {
            $driver->writable if $driver;
            $check_ready->();
        },
        on_error => sub ($socket, $e) {
            $error = "client UDP: $e"; $loop->stop;
        },
    );
    my $watchdog = Linux::Event::Kernel::Timer->new(
        loop => $loop, after => 60,
        on_timer => sub ($timer) {
            $error = "$mode watchdog: phase=$phase completed=$finished/$phase_target"
                . " sent=$sent inflight=$inflight";
            $loop->stop;
        },
    );
    $loop->run;
    for my $timer ($watchdog, $server_timer, $client_timer) {
        $timer->cancel if $timer && $timer->is_active;
    }
    die "$error\n" if $error;
    die "$mode ended before measurement finished\n"
        unless $phase eq 'finished' && defined $elapsed;
    die "$mode server processed $responses, expected " . ($warmup + $samples) . "\n"
        unless $responses == $warmup + $samples;
    die "$mode request count $call_count != $samples\n"
        unless $call_count == $samples;
    die "$mode latency sample count mismatch\n"
        unless @latency == $samples;
    die "$mode concurrency $max_inflight out of range\n"
        if !$max_inflight || $max_inflight > $concurrency;
    my @ordered = sort { $a <=> $b } @latency;
    return {
        mode => $mode,
        elapsed => $elapsed,
        cpu => $cpu_seconds,
        call_us => 1_000_000 * $call_seconds / $call_count,
        p50 => percentile(\@ordered, 50),
        p95 => percentile(\@ordered, 95),
        p99 => percentile(\@ordered, 99),
        rss_start => $rss_start,
        rss_end => $rss_end,
        rss_peak => $rss_peak,
        inflight_peak => $max_inflight,
    };
}

print "# HTTP3 loopback: direct engine vs pooled unified Client.\n";
print "# same QUIC Driver, server, body and concurrency; TLS handshake excluded.\n";
print "# requested samples=$samples warmup=$warmup rounds=$rounds inflight=$concurrency response_bytes=$body_bytes\n";
print "# CPU is process user+system; RSS is /proc/self/status VmRSS sampled every 16 completions.\n";
print "# RSS is process-wide, includes server+client, sampled not allocator peak; trials share one process.\n";
print "# Each request validates the complete buffered response; no 0-RTT or connection migration.\n";
print "# Host CI timing is not a stable performance claim. Copy and allocation counts unavailable.\n";
my %times;
for my $round (1 .. $rounds) {
    for my $mode ($round % 2 ? ('direct', 'unified') : ('unified', 'direct')) {
        my $v = run_trial($mode);
        push @{ $times{$mode} }, $v->{elapsed};
        printf "%-7s round=%d req/s=%.1f wall=%.4fs cpu=%.4fs"
            . " request_us=%.2f p50_us=%.1f p95_us=%.1f p99_us=%.1f"
            . " inflight_peak=%d rss_start_kib=%s rss_end_kib=%s rss_sample_peak_kib=%s\n",
            $mode, $round, $samples / $v->{elapsed}, $v->{elapsed}, $v->{cpu},
            $v->{call_us}, $v->{p50}, $v->{p95}, $v->{p99},
            $v->{inflight_peak},
            (defined $v->{rss_start} ? $v->{rss_start} : 'NA'),
            (defined $v->{rss_end} ? $v->{rss_end} : 'NA'),
            (defined $v->{rss_peak} ? $v->{rss_peak} : 'NA');
    }
}
my %median;
for my $mode (qw(direct unified)) {
    my @sorted = sort { $a <=> $b } @{ $times{$mode} };
    $median{$mode} = $sorted[int(@sorted/2)];
    printf "# %s median wall %.4fs (%.1f req/s)\n",
        $mode, $median{$mode}, $samples / $median{$mode};
}
printf "# median unified/direct wall ratio %.3f (descriptive only)\n",
    $median{unified} / $median{direct};
