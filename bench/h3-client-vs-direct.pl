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

# Compares one outstanding HTTP/3 GET over authenticated loopback QUIC.
# Both modes use exactly the same Net::QUIC::Driver and upper Server.
# The DIRECT path uses Unblock::HTTP3::Client; UNIFIED uses the shared
# Unblock::HTTP::Client. Handshake, socket construction and warmup are
# excluded from timed requests. Allocation and process RSS not measured.
my ($sample, $warmup, $rounds) = @ARGV;
$sample = 500 unless defined $sample;
$warmup = 50 unless defined $warmup;
$rounds = 3 unless defined $rounds;
die "usage: perl bench/h3-client-vs-direct.pl [sample>0] [warmup>0] [rounds>0]\n"
    unless defined($sample) && $sample =~ /\A[1-9][0-9]*\z/
        && defined($warmup) && $warmup =~ /\A[1-9][0-9]*\z/
        && defined($rounds) && $rounds =~ /\A[1-9][0-9]*\z/
        && $sample <= 10000 && $warmup <= 1000 && $rounds <= 15;

my $dir = tempdir(CLEANUP => 1);
my $cert = "$dir/cert.pem";
my $key = "$dir/key.pem";
die "openssl executable needed for local QUIC/TLS benchmark\n"
    if system('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
        '-nodes', '-days', '1', '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
        '-keyout', $key, '-out', $cert) != 0;

sub run_one ($mode) {
    my $loop = Linux::Event::Loop->new;
    my ($server, $server_timer, $server_socket, $client_driver,
        $client_socket, $client_timer, $quic, $direct, $unified);
    my ($ready_factory, $attached, $started, $done, $responses, $error)
        = (undef, 0, 0, 0, 0, undef);
    my ($start, $elapsed, $request_time, $request_count)
        = (undef, undef, 0, 0);
    my $total = $sample + $warmup;
    my ($next, $check_ready);

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
                $tx->respond(status => 200, body => 'ok');
            },
            on_error => sub ($tx, $e) {
                $error = "server HTTP3: $e"; $loop->stop;
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
                    on_timer => sub ($t) {
                        undef $server_timer; $server->timeout;
                    },
                );
            }
        },
    );
    $server->start;

    $next = sub {
        return if $error || $done >= $total;
        my $on_finish = sub ($tx) {
            if (!$tx->is_complete) {
                $error = "$mode transaction did not complete";
                $loop->stop;
                return;
            }
            $done++;
            $start = time() if $done == $warmup;
            if ($done == $total) {
                $elapsed = time() - $start;
                $loop->stop;
                return;
            }
            $loop->defer(sub { $next->() });
        };
        my $on_error = sub ($tx, $e) {
            $error = "$mode HTTP3 response: $e";
            $loop->stop;
        };
        my $on_response = sub ($tx, $response) {
            $error ||= 'invalid HTTP3 response'
                unless $response->status == 200
                    && $response->body eq 'ok';
            $loop->stop if $error;
        };
        my $measure = $done >= $warmup;
        my $call_start = time() if $measure;
        if ($mode eq 'direct') {
            $direct->request(
                method => 'GET', scheme => 'https',
                authority => 'localhost', target => '/ping',
                receive_body => 'buffered',
                on_complete => $on_response,
                on_error => $on_error,
                on_finish => $on_finish,
            );
        } else {
            $unified->request(
                method => 'GET', url => 'https://localhost/ping',
                http_version => '3',
                on_response => $on_response,
                on_error => $on_error,
                on_finish => $on_finish,
            );
        }
        if ($measure) {
            $request_time += time() - $call_start;
            $request_count++;
        }
    };
    $check_ready = sub {
        return if $attached || !$quic || !$quic->ready;
        if ($mode eq 'unified') {
            return unless $ready_factory;
        }
        $attached = 1;
        if ($mode eq 'direct') {
            $direct = Unblock::HTTP3::Client->new(
                quic => $quic, receive_body => 'buffered',
                max_buffered_body_bytes => 1048576,
            );
            $direct->start;
            $loop->defer(sub { $next->() });
        } else {
            $ready_factory->(connection => $quic, verified_origin => 1);
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
                    max_pending_requests => 1,
                    connect_quic => sub {
                        my ($origin, $callback) = @_;
                        $ready_factory = $callback;
                        $check_ready->();
                    },
                    defer => sub {
                        my ($callback) = @_;
                        $loop->defer($callback);
                    },
                );
                # The warmup opens the pool; no preconnect API is required.
                $loop->defer(sub { $next->() });
            }
            $client_driver = Net::QUIC::Driver->client(
                local => $socket->local->sockaddr,
                peer => $socket->peer->sockaddr,
                alpn => 'h3', server_name => 'localhost', ca_file => $cert,
                send => sub ($datagram) { $socket->send($datagram->data) },
                set_timeout => sub ($seconds) {
                    $client_timer->cancel
                        if $client_timer && $client_timer->is_active;
                    undef $client_timer;
                    if (defined $seconds) {
                        $client_timer = Linux::Event::Kernel::Timer->new(
                            loop => $loop, after => $seconds,
                            on_timer => sub ($t) {
                                undef $client_timer;
                                $client_driver->timeout;
                                $check_ready->();
                            },
                        );
                    }
                },
            );
            $quic = $client_driver->connection;
            $client_driver->start;
            $check_ready->();
        },
        on_datagram => sub ($socket, $bytes, $peer) {
            if ($client_driver) {
                $client_driver->receive(
                    $bytes, $socket->local->sockaddr, $peer->sockaddr);
                $check_ready->();
            }
        },
        on_drain => sub ($socket) {
            $client_driver->writable if $client_driver;
            $check_ready->();
        },
        on_error => sub ($socket, $e) {
            $error = "client UDP: $e"; $loop->stop;
        },
    );
    my $watchdog = Linux::Event::Kernel::Timer->new(
        loop => $loop, after => 30,
        on_timer => sub ($t) {
            $error = "$mode benchmark watchdog expired ($done/$total)";
            $loop->stop;
        },
    );
    $loop->run;
    for my $timer ($client_timer, $server_timer, $watchdog) {
        $timer->cancel if $timer && $timer->is_active;
    }
    die "$error\n" if $error;
    die "$mode completed $done/$total requests\n" unless $done == $total;
    die "$mode server sent $responses/$total responses\n"
        unless $responses == $total;
    die "$mode timed $request_count/$sample calls\n"
        unless $request_count == $sample;
    return ($elapsed, 1_000_000 * $request_time / $request_count);
}

print "# Real localhost QUIC/TLS + HTTP3, shared Server and Net::QUIC driver.\n";
print "# Sequential tiny GET, one connection per trial, handshake excluded by warmup.\n";
print "# End-to-end interval and inclusive request() cost are distinct measures.\n";
print "# Trials alternate ordering, but machine, GC, scheduler and TLS noise remain.\n";
print "# No process RSS, allocations, copy count, streaming or packet-loss measurement.\n";
my (%elapsed, %calls);
for my $round (1 .. $rounds) {
    for my $mode ($round % 2 ? ('direct', 'unified') : ('unified', 'direct')) {
        my ($seconds, $call_us) = run_one($mode);
        push @{ $elapsed{$mode} }, $seconds;
        push @{ $calls{$mode} }, $call_us;
        printf "%-8s round=%d %d requests in %.5f s (%.0f req/s) request() %.2f us\n",
            $mode, $round, $sample, $seconds, $sample/$seconds, $call_us;
    }
}
for my $mode (qw(direct unified)) {
    my @times = sort { $a <=> $b } @{ $elapsed{$mode} };
    my @setup = sort { $a <=> $b } @{ $calls{$mode} };
    printf "# %-8s median %.5f s (%.0f req/s), request() %.2f us\n",
        $mode, $times[int(@times/2)], $sample/$times[int(@times/2)],
        $setup[int(@setup/2)];
}
my @d = sort { $a <=> $b } @{ $elapsed{direct} };
my @u = sort { $a <=> $b } @{ $elapsed{unified} };
printf "# unified/direct wall-time ratio %.3f (not a performance claim)\n",
    $u[int(@u/2)] / $d[int(@d/2)];
