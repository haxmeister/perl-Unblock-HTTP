use v5.36;
use strict;
use warnings;
use Time::HiRes qw(time clock_gettime CLOCK_PROCESS_CPUTIME_ID);
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/lib";
use H3Profile::Summary qw(summarize_trials);
use POSIX qw(_exit);
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
# Comma-separated response sizes cycle through the same request paths in each
# mode, without introducing a second response accumulator.
# Each trial forks fresh, separate server/client processes before initializing
# their event loops or QUIC. Client CPU is process user+system; client VmRSS
# is sampled, not an allocator high-water mark.
my ($samples, $warmup, $rounds, $concurrency, $body_bytes) = @ARGV;
$samples     //= 150;
$warmup      //= 24;
$rounds      //= 3;
$concurrency //= 4;
$body_bytes  //= 16384;
die "usage: perl bench/h3-workload-profile.pl [samples] [warmup] [rounds] [inflight] [response_bytes_or_comma_sizes]\n"
    unless $samples =~ /\A[1-9][0-9]*\z/ && $samples <= 20000
        && $warmup =~ /\A[1-9][0-9]*\z/ && $warmup <= 2000
        && $rounds =~ /\A[1-9][0-9]*\z/ && $rounds <= 15
        && $concurrency =~ /\A[1-9][0-9]*\z/ && $concurrency <= 32
        && $body_bytes =~ /\A[1-9][0-9]*(?:,[1-9][0-9]*)*\z/;
my @sizes = split /,/, $body_bytes;
die "specify at most eight response sizes, each no larger than 1048576\n"
    if @sizes > 8 || grep { $_ > 1048576 } @sizes;
my @bodies = map { 'B' x $_ } @sizes;
my $url_mode = $ENV{UNBLOCK_H3_PROFILE_URL_MODE} // 'cycled';
die "UNBLOCK_H3_PROFILE_URL_MODE must be cycled or unique\n"
    unless $url_mode eq 'cycled' || $url_mode eq 'unique';
my $json_report = $ENV{UNBLOCK_H3_PROFILE_JSON_FILE};
die "UNBLOCK_H3_PROFILE_JSON_FILE must be a nonempty path\n"
    if defined($json_report) && !length($json_report);
my $heap_dir = $ENV{UNBLOCK_H3_HEAP_DIR};
my $profile_wire = $ENV{UNBLOCK_H3_PROFILE_WIRE} ? 1 : 0;
my $checkpoint_every = $ENV{UNBLOCK_H3_PROFILE_CHECKPOINT_EVERY} // 0;
my $profile_registry = $ENV{UNBLOCK_H3_PROFILE_REGISTRY} // 0;
my $assert_bounded = $ENV{UNBLOCK_H3_PROFILE_ASSERT_BOUNDED} // 0;
die "UNBLOCK_H3_PROFILE_ASSERT_BOUNDED must be 0 or 1\n"
    unless $assert_bounded =~ /\A[01]\z/;
die "UNBLOCK_H3_PROFILE_ASSERT_BOUNDED requires registry checkpoints\n"
    if $assert_bounded && (!$profile_registry || !$checkpoint_every);
die "UNBLOCK_H3_PROFILE_REGISTRY must be 0 or 1\n"
    unless $profile_registry =~ /\A[01]\z/;
die "UNBLOCK_H3_PROFILE_REGISTRY requires memory checkpoints\n"
    if $profile_registry && !$checkpoint_every;
die "UNBLOCK_H3_PROFILE_CHECKPOINT_EVERY must be 0 or an integer 64..4096\n"
    unless $checkpoint_every =~ /\A(?:0|[1-9][0-9]*)\z/
        && ($checkpoint_every == 0
            || ($checkpoint_every >= 64 && $checkpoint_every <= 4096));
my $watchdog_seconds = $ENV{UNBLOCK_H3_PROFILE_WATCHDOG_SECONDS} // 60;
die "UNBLOCK_H3_PROFILE_WATCHDOG_SECONDS must be 60..3600\n"
    unless $watchdog_seconds =~ /\A[1-9][0-9]*\z/
        && $watchdog_seconds >= 60 && $watchdog_seconds <= 3600;
die "UNBLOCK_H3_HEAP_DIR must be an existing writable directory\n"
    if defined($heap_dir) && (!-d $heap_dir || !-w $heap_dir);
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

# /proc/self/smaps_rollup is Linux-specific and sampled only at phase
# boundaries. Neither PSS nor private memory measures SV allocation rate.
sub sampled_smaps_kib {
    open my $fh, '<', '/proc/self/smaps_rollup' or return {};
    my %values;
    while (my $line = <$fh>) {
        if ($line =~ /\A(Pss|Private_Clean|Private_Dirty):\s+(\d+)\s+kB/) {
            $values{$1} = 0 + $2;
        }
    }
    close $fh;
    return {
        pss => $values{Pss},
        private => defined($values{Private_Clean})
            && defined($values{Private_Dirty})
            ? $values{Private_Clean} + $values{Private_Dirty}
            : undef,
    };
}

sub percentile {
    my ($sorted, $p) = @_;
    return 0 unless @$sorted;
    my $index = int(($p / 100) * (@$sorted - 1) + 0.5);
    return $sorted->[$index];
}

sub median {
    my ($values) = @_;
    my @ordered = sort { $a <=> $b } @$values;
    my $mid = int(@ordered / 2);
    return @ordered % 2
        ? $ordered[$mid]
        : ($ordered[$mid - 1] + $ordered[$mid]) / 2;
}

sub run_client_trial ($mode, $server_port, $round) {
    my $loop = Linux::Event::Loop->new;
    my ($driver, $client_socket, $client_timer, $quic, $direct, $unified,
        $factory_ready);
    my ($attached, $error, $sent, $finished, $inflight, $max_inflight,
        $pump_queued) = (0, undef, 0, 0, 0, 0, 0);
    my ($phase, $phase_target) = ('warmup', $warmup);
    my ($elapsed, $cpu_seconds, $call_seconds, $call_count)
        = (undef, undef, 0, 0);
    my ($start, $cpu_start, $rss_start, $rss_peak, $rss_end);
    my ($memory_start, $memory_end);
    my ($wire_sent_bytes, $wire_recv_bytes, $wire_sent_packets,
        $wire_recv_packets) = (0, 0, 0, 0);
    my %heap_files;
    my @latency;
    my @checkpoints;
    my ($pump, $schedule, $check_ready, $sample_rss);

    my $snapshot_heap = sub {
        my ($when) = @_;
        return unless defined $heap_dir;
        require Devel::MAT::Dumper;  # Opt-in only; never a runtime dependency.
        my $path = File::Spec->catfile(
            $heap_dir, "h3-$mode-round$round-client-$when-$$.pmat",
        );
        Devel::MAT::Dumper::dump($path);
        $heap_files{$when} = $path;
    };

    my $snapshot_registries = sub {
        return {} unless $profile_registry;
        my $engine = $direct;
        if ($mode eq 'unified' && $unified) {
            # Diagnostic-only introspection. The unified pool owns the
            # actual same HTTP3 engine; do not alter application APIs.
            for my $pool (values %{ $unified->{pools} // {} }) {
                for my $conn (@{ $pool->{connections} // [] }) {
                    $engine = $conn->{engine}
                        if $conn->{protocol} eq 'h3';
                }
            }
        }
        my %count;
        for my $key (qw(transactions streams messages stream_lifecycle
                        outgoing building)) {
            $count{$key} = $engine && ref($engine->{$key}) eq 'HASH'
                ? scalar(keys %{ $engine->{$key} }) : undef;
        }
        for my $key (qw(ready_transactions ready_informational)) {
            $count{$key} = $engine && ref($engine->{$key}) eq 'ARRAY'
                ? scalar(@{ $engine->{$key} }) : undef;
        }
        $count{quic_send_buffered} = $quic
            ? $quic->send_buffered_bytes : undef;
        return \%count;
    };

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
            my $body_index = ($sent - 1) % @sizes;
            my $expected_body = $bodies[$body_index];
            my $target = @sizes == 1 ? '/profile' : "/profile/$body_index";
            # A unique URL per request, including across warmup and
            # measurement. Do not alter response-size selection or
            # permit callback completion order to affect the target.
            if ($url_mode eq 'unique') {
                my $serial = $sent + ($phase eq 'measure' ? $warmup : 0);
                $target .= "?req=$serial";
            }
            my $measured = $phase eq 'measure' ? 1 : 0;
            my $saw_response = 0;
            my $on_response = sub ($tx, $response) {
                if (!$response || $response->status != 200
                    || $response->body ne $expected_body) {
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
                    if ($checkpoint_every
                        && $finished % $checkpoint_every == 0) {
                        # Samples are after validation, at deterministic
                        # completion counts and while the connection stays up.
                        # smaps scanning changes timing; never mix results
                        # with uninstrumented throughput comparisons.
                        my $rollup = sampled_smaps_kib();
                        push @checkpoints, {
                            completed => $finished,
                            elapsed => time() - $start,
                            inflight => $inflight,
                            rss => sampled_rss_kib(),
                            pss => $rollup->{pss},
                            private => $rollup->{private},
                            registry => $snapshot_registries->(),
                        };
                        if ($assert_bounded) {
                            my $sample = $checkpoints[-1];
                            my $reg = $sample->{registry};
                            # For the 4/16 KiB callback-only CI workload,
                            # catch old strong queue/Transaction retention.
                            # Private KiB is not an allocation counter.
                            if (!defined($reg->{ready_transactions})
                                || $reg->{ready_transactions} > $concurrency + 64
                                || !defined($reg->{transactions})
                                || $reg->{transactions} > $concurrency + 1
                                || !defined($memory_start->{private})
                                || !defined($sample->{private})
                                || $sample->{private} - $memory_start->{private}
                                    > 8192) {
                                $error = "$mode bounded-memory assertion at "
                                    . "$finished completions: ready_tx="
                                    . (defined($reg->{ready_transactions})
                                        ? $reg->{ready_transactions} : 'NA')
                                    . " transactions="
                                    . (defined($reg->{transactions})
                                        ? $reg->{transactions} : 'NA')
                                    . " private_start="
                                    . (defined($memory_start->{private})
                                        ? $memory_start->{private} : 'NA')
                                    . " private_now="
                                    . (defined($sample->{private})
                                        ? $sample->{private} : 'NA');
                                $loop->stop;
                                return;
                            }
                        }
                    }
                }
                if ($finished == $phase_target && !$inflight) {
                    if ($phase eq 'warmup') {
                        $phase = 'measure';
                        $phase_target = $samples;
                        ($sent, $finished, $max_inflight) = (0, 0, 0);
                        $snapshot_heap->('before');
                        # Sampling must finish BEFORE starting the timed
                        # measured phase. Reading smaps can be expensive.
                        $rss_start = sampled_rss_kib();
                        $memory_start = sampled_smaps_kib();
                        $rss_peak = $rss_start;
                        $cpu_start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
                        $start = time();
                        $schedule->();
                    } else {
                        $elapsed = time() - $start;
                        $cpu_seconds = clock_gettime(CLOCK_PROCESS_CPUTIME_ID)
                            - $cpu_start;
                        $rss_end = sampled_rss_kib();
                        $sample_rss->();
                        $memory_end = sampled_smaps_kib();
                        $snapshot_heap->('after');
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
                    authority => 'localhost', target => $target,
                    receive_body => 'buffered',
                    on_complete => sub ($tx) {
                        $on_response->($tx, $tx->response);
                    },
                    on_error => $on_error,
                    on_finish => $on_finish,
                );
            } else {
                $request = $unified->request(
                    method => 'GET', url => "https://localhost$target",
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
        port => $server_port,
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
                send => sub ($packet) {
                    if ($profile_wire && $phase eq 'measure') {
                        my $bytes = $packet->data;
                        $wire_sent_bytes += length($bytes);
                        $wire_sent_packets++;
                        return $socket->send($bytes);
                    }
                    return $socket->send($packet->data);
                },
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
                if ($profile_wire && $phase eq 'measure') {
                    $wire_recv_bytes += length($bytes);
                    $wire_recv_packets++;
                }
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
        loop => $loop, after => $watchdog_seconds,
        on_timer => sub ($timer) {
            $error = "$mode watchdog: phase=$phase completed=$finished/$phase_target"
                . " sent=$sent inflight=$inflight";
            $loop->stop;
        },
    );
    $loop->run;
    for my $timer ($watchdog, $client_timer) {
        $timer->cancel if $timer && $timer->is_active;
    }
    die "$error\n" if $error;
    die "$mode ended before measurement finished\n"
        unless $phase eq 'finished' && defined $elapsed;
    die "$mode request count $call_count != $samples\n"
        unless $call_count == $samples;
    die "$mode latency sample count mismatch\n"
        unless @latency == $samples;
    die "$mode concurrency $max_inflight out of range\n"
        if !$max_inflight || $max_inflight > $concurrency;
    if ($checkpoint_every) {
        my $expected = int($samples / $checkpoint_every);
        die "$mode checkpoint count mismatch: "
            . scalar(@checkpoints) . " != $expected\n"
            unless @checkpoints == $expected;
        my ($last_count, $last_time) = (0, -1);
        for my $checkpoint (@checkpoints) {
            die "$mode checkpoint count or time is nonmonotonic\n"
                unless $checkpoint->{completed} == $last_count
                    + $checkpoint_every
                    && $checkpoint->{elapsed} > $last_time;
            ($last_count, $last_time) = (
                $checkpoint->{completed}, $checkpoint->{elapsed},
            );
        }
    }
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
        pss_start => $memory_start->{pss},
        pss_end => $memory_end->{pss},
        private_start => $memory_start->{private},
        private_end => $memory_end->{private},
        wire_sent_bytes => $wire_sent_bytes,
        wire_recv_bytes => $wire_recv_bytes,
        wire_sent_packets => $wire_sent_packets,
        wire_recv_packets => $wire_recv_packets,
        heap_files => \%heap_files,
        checkpoints => \@checkpoints,
        inflight_peak => $max_inflight,
    };
}

# The server gets its own process and event loop. It stays alive until the
# client validates its last response and writes 'D' to the control pipe.
# Polling for shutdown begins only after all server requests were handled.
sub run_server ($ready_fh, $done_fh) {
    my $loop = Linux::Event::Loop->new;
    my ($server, $server_socket, $server_timer, $done_timer);
    my ($responses, $error) = (0, undef);
    my $check_done;
    $check_done = sub {
        my $readable = '';
        vec($readable, fileno($done_fh), 1) = 1;
        my $ready = select($readable, undef, undef, 0);
        if (!defined $ready) {
            $error = "server control select: $!";
            $loop->stop;
            return;
        }
        if ($ready) {
            my $n = sysread($done_fh, my $command, 1);
            if (defined($n) && $n == 1 && $command eq 'D') {
                $loop->stop;
                return;
            }
            $error = "server lost client completion signal";
            $loop->stop;
            return;
        }
        $done_timer = Linux::Event::Kernel::Timer->new(
            loop => $loop, after => 0.02,
            on_timer => sub ($timer) {
                undef $done_timer;
                $check_done->();
            },
        );
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
                my $target = $request->target;
                # Validate query serial for the unique-target workload.
                # The authoritative response index remains in the path.
                my ($path, $serial) = $target
                    =~ m{\A(/profile(?:/[0-9]+)?)(?:\?req=([1-9][0-9]*))?\z};
                my $valid_serial = $url_mode eq 'unique'
                    ? defined($serial) && $serial <= $warmup + $samples
                    : !defined($serial);
                my $body_index;
                if (defined($path) && $valid_serial) {
                    if (@sizes == 1 && $path eq '/profile') {
                        $body_index = 0;
                    } elsif (@sizes > 1
                        && $path =~ m{\A/profile/([0-9]+)\z}
                        && $1 < @sizes) {
                        $body_index = $1;
                    }
                }
                if (!defined $body_index) {
                    $error = "unexpected benchmark target $target";
                    $loop->stop;
                    return;
                }
                $responses++;
                $tx->respond(status => 200, body => $bodies[$body_index]);
                $check_done->() if $responses == $warmup + $samples;
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

    print {$ready_fh} $server_socket->local->port . "\n"
        or die "server port handshake: $!";
    close $ready_fh or die "close port handshake: $!";

    my $watchdog = Linux::Event::Kernel::Timer->new(
        loop => $loop, after => $watchdog_seconds,
        on_timer => sub ($timer) {
            $error = "server watchdog: handled=$responses/"
                . ($warmup + $samples);
            $loop->stop;
        },
    );
    $loop->run;
    for my $timer ($watchdog, $server_timer, $done_timer) {
        $timer->cancel if $timer && $timer->is_active;
    }
    die "$error\n" if $error;
    die "server handled $responses, expected " . ($warmup + $samples) . "\n"
        unless $responses == $warmup + $samples;
    return { responses => $responses };
}

# The trial process is the client process. The coordinator forks a fresh trial
# process, which forks the server BEFORE either side creates sockets or loops.
sub run_trial ($mode, $round) {
    pipe(my $port_read, my $port_write) or die "port pipe: $!";
    pipe(my $stop_read, my $stop_write) or die "control pipe: $!";
    pipe(my $report_read, my $report_write) or die "server report pipe: $!";
    my $server_pid = fork();
    die "server fork: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        close $port_read;
        close $stop_write;
        close $report_read;
        my ($result, $error);
        eval { $result = run_server($port_write, $stop_read); 1 }
            or $error = "$@";
        my $json = JSON::PP->new->encode(
            $error ? { error => $error } : { result => $result },
        );
        print {$report_write} $json or _exit(1);
        close $report_write;
        _exit($error ? 1 : 0);
    }

    close $port_write;
    close $stop_read;
    close $report_write;
    my ($result, $client_error);
    eval {
        my $port = <$port_read>;
        die "server did not announce a port\n"
            unless defined $port && $port =~ /\A[1-9][0-9]*\n\z/
                && $port <= 65535;
        close $port_read;
        $result = run_client_trial($mode, 0 + $port, $round);
        1;
    } or $client_error = "$@";

    if ($client_error) {
        kill 'TERM', $server_pid;
    } else {
        print {$stop_write} 'D' or $client_error = "server stop pipe: $!";
    }
    close $port_read if defined fileno($port_read);
    close $stop_write;

    my $report;
    {
        local $/;
        $report = <$report_read>;
    }
    close $report_read;
    waitpid($server_pid, 0);
    my $status = $?;
    die $client_error if $client_error;
    die "server child produced no result (status $status)\n"
        unless defined($report) && length($report);
    my $decoded = JSON::PP->new->decode($report);
    die "server child: $decoded->{error}\n"
        if defined $decoded->{error};
    die "server child exited unsuccessfully (status $status)\n"
        if $status;
    die "server response count mismatch\n"
        unless $decoded->{result}{responses} == $warmup + $samples;
    return $result;
}

# Fork BEFORE creating any event loop, socket or QUIC connection for the
# trial. Each trial child also forks its dedicated server. This resets
# client resources and keeps server CPU/RSS out of the client's measurements.
sub run_isolated_trial ($mode, $round) {
    pipe(my $from_child, my $to_parent) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        close $from_child;
        my ($result, $error);
        eval { $result = run_trial($mode, $round); 1 } or $error = "$@";
        my $json = JSON::PP->new->encode(
            $error ? { error => $error } : { result => $result }
        );
        print {$to_parent} $json or _exit(1);
        close $to_parent;
        _exit($error ? 1 : 0);
    }

    close $to_parent;
    my $report;
    {
        local $/;
        $report = <$from_child>;
    }
    close $from_child;
    waitpid($pid, 0);
    my $status = $?;
    die "$mode child produced no profile data (exit status $status)\n"
        unless defined($report) && length($report);
    my $decoded = JSON::PP->new->decode($report);
    die "$mode child profile failed: $decoded->{error}\n"
        if defined $decoded->{error};
    die "$mode child did not exit successfully (status $status)\n"
        if $status;
    return $decoded->{result};
}

print "# HTTP3 loopback: direct engine vs pooled unified Client.\n";
print "# same QUIC Driver, server, body and concurrency; TLS handshake excluded.\n";
print "# requested samples=$samples warmup=$warmup rounds=$rounds inflight=$concurrency response_bytes=$body_bytes\n";
print "# URL mode=$url_mode; unique appends deterministic per-request query serial; default cycled uses original target.\n";
print "# sizes cycle deterministically by request index in both modes.\n" if @sizes > 1;
print "# CPU uses client-only process CPU clock (user+system); RSS is sampled client VmRSS.\n";
print "# Every trial uses fresh client and server processes; samples exclude the server process.\n";
print "# Each request validates the complete buffered response; no 0-RTT or connection migration.\n";
print "# Host CI timing is not a stable performance claim. Copy and allocation counts unavailable.\n";
print "# Client PSS/private memory is sampled at phase boundaries; neither is allocation count.\n";
print "# Memory checkpoints at every $checkpoint_every completions; timing is instrumented.\n"
    if $checkpoint_every;
print "# Private engine registry counts enabled, diagnostic only.\n"
    if $profile_registry;
print "# Opt-in bounded-memory regression guard enabled for callback-only 4/16 KiB workload.\n"
    if $assert_bounded;
print "# Timeout watchdog=$watchdog_seconds seconds per trial.\n"
    if $watchdog_seconds != 60;
print "# Optional Perl heap dumps are diagnostic and invalidate timing comparisons.\n"
    if defined $heap_dir;
my %times;
my @trial_records;
for my $round (1 .. $rounds) {
    for my $mode ($round % 2 ? ('direct', 'unified') : ('unified', 'direct')) {
        my $v = run_isolated_trial($mode, $round);
        push @{ $times{$mode} }, $v->{elapsed};
        push @trial_records, { round => $round, %$v };
        printf "%-7s round=%d req/s=%.1f wall=%.4fs client_cpu=%.4fs"
            . " request_us=%.2f p50_us=%.1f p95_us=%.1f p99_us=%.1f"
            . " inflight_peak=%d client_rss_start_kib=%s client_rss_end_kib=%s client_rss_sample_peak_kib=%s"
            . " client_pss_start_kib=%s client_pss_end_kib=%s"
            . " client_private_start_kib=%s client_private_end_kib=%s\n",
            $mode, $round, $samples / $v->{elapsed}, $v->{elapsed}, $v->{cpu},
            $v->{call_us}, $v->{p50}, $v->{p95}, $v->{p99},
            $v->{inflight_peak},
            (defined $v->{rss_start} ? $v->{rss_start} : 'NA'),
            (defined $v->{rss_end} ? $v->{rss_end} : 'NA'),
            (defined $v->{rss_peak} ? $v->{rss_peak} : 'NA'),
            (defined $v->{pss_start} ? $v->{pss_start} : 'NA'),
            (defined $v->{pss_end} ? $v->{pss_end} : 'NA'),
            (defined $v->{private_start} ? $v->{private_start} : 'NA'),
            (defined $v->{private_end} ? $v->{private_end} : 'NA');
        if ($checkpoint_every) {
            my ($last_count, $last_time) = (0, 0);
            for my $sample (@{ $v->{checkpoints} }) {
                my $span = $sample->{elapsed} - $last_time;
                my $rate = $span > 0
                    ? ($sample->{completed} - $last_count) / $span : 0;
                printf "# checkpoint mode=%s round=%d completed=%d"
                    . " elapsed_s=%.3f interval_req_s=%.1f"
                    . " inflight=%d rss_kib=%s pss_kib=%s private_kib=%s\n",
                    $mode, $round, $sample->{completed}, $sample->{elapsed},
                    $rate, $sample->{inflight},
                    (defined($sample->{rss}) ? $sample->{rss} : 'NA'),
                    (defined($sample->{pss}) ? $sample->{pss} : 'NA'),
                    (defined($sample->{private}) ? $sample->{private} : 'NA');
                if ($profile_registry) {
                    my $reg = $sample->{registry} // {};
                    printf "# registry mode=%s round=%d completed=%d"
                        . " tx=%s streams=%s messages=%s lifecycle=%s"
                        . " outgoing=%s building=%s ready_tx=%s"
                        . " ready_info=%s quic_send_buffered=%s\n",
                        $mode, $round, $sample->{completed},
                        map { defined($reg->{$_}) ? $reg->{$_} : 'NA' }
                            qw(transactions streams messages
                               stream_lifecycle outgoing building
                               ready_transactions ready_informational
                               quic_send_buffered);
                }
                ($last_count, $last_time) =
                    ($sample->{completed}, $sample->{elapsed});
            }
        }
        if ($profile_wire) {
            printf "# %s round=%d client UDP sent=%d bytes/%d datagrams"
                . " recv=%d bytes/%d datagrams (not copy counts)\n",
                $mode, $round,
                $v->{wire_sent_bytes}, $v->{wire_sent_packets},
                $v->{wire_recv_bytes}, $v->{wire_recv_packets};
        }
        if (defined $heap_dir) {
            printf "# %s round=%d client heap before=%s after=%s\n",
                $mode, $round, $v->{heap_files}{before},
                $v->{heap_files}{after};
        }
    }
}
my %median;
for my $mode (qw(direct unified)) {
    $median{$mode} = median($times{$mode});
    printf "# %s median wall %.4fs (%.1f req/s)\n",
        $mode, $median{$mode}, $samples / $median{$mode};
}
printf "# median unified/direct wall ratio %.3f (descriptive only)\n",
    $median{unified} / $median{direct};

# Paired results complement, but do not replace, the historical separate
# median wall times above. They cannot remove hosted-runner scheduling noise.
my $summary = summarize_trials(\@trial_records, $rounds);
for my $pair (@{ $summary->{paired} }) {
    printf "# paired round=%d wall_ratio=%.4f cpu_ratio=%s"
        . " unified_minus_direct_request_us=%.2f"
        . " p50_delta_us=%.1f p95_delta_us=%.1f p99_delta_us=%.1f\n",
        $pair->{round}, $pair->{wall_ratio},
        (defined $pair->{cpu_ratio}
            ? sprintf('%.4f', $pair->{cpu_ratio}) : 'NA'),
        $pair->{request_delta_us}, $pair->{p50_delta_us},
        $pair->{p95_delta_us}, $pair->{p99_delta_us};
}
printf "# median paired unified/direct wall ratio %.4f"
    . " (range %.4f..%.4f; descriptive only)\n",
    $summary->{median_paired_wall_ratio},
    $summary->{min_paired_wall_ratio}, $summary->{max_paired_wall_ratio};

if (defined $json_report) {
    # Optional output occurs AFTER every isolated trial; never add file IO
    # inside request(), callbacks, the QUIC loop or timed measurements.
    my $data = {
        schema_version => 1,
        workload => {
            samples => 0 + $samples, warmup => 0 + $warmup,
            rounds => 0 + $rounds, inflight => 0 + $concurrency,
            response_bytes => [map { 0 + $_ } @sizes],
            url_mode => $url_mode,
            memory_checkpoint_every => 0 + $checkpoint_every,
            registry_checkpoint => 0 + $profile_registry,
            bounded_assertions => 0 + $assert_bounded,
            wire_counters => 0 + $profile_wire,
        },
        trials => \@trial_records,
        summary => $summary,
    };
    open my $fh, '>', $json_report
        or die "cannot open profile JSON report $json_report: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode($data)
        or die "cannot write profile JSON report $json_report: $!\n";
    close $fh or die "cannot close profile JSON report $json_report: $!\n";
    print "# machine-readable profile JSON: $json_report\n";
}
