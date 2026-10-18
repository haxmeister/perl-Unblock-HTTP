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

# Advanced pull Reader: queued data is NOT automatically credited to QUIC.
# The ordinary high-level Client still uses its buffered-default API.
# This fixture deliberately tests the existing H3 lower-level interface.
my $dir = tempdir(CLEANUP => 1);
my $cert = "$dir/cert.pem";
my $key = "$dir/key.pem";
if (system('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
    '-nodes', '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout', $key, '-out', $cert) != 0) {
    plan skip_all => 'openssl executable is needed for QUIC TLS fixture';
}

my $loop = Linux::Event::Loop->new;
my ($server, $client, $server_timer, $client_timer, $client_socket);
my ($hold_timer, $poll_timer, $watchdog);
my ($error, $ready, $requests, $completed) = (undef, 0, 0, 0);
my ($slow_tx, $reader, $server_tx);
my ($slow_finished, $fast_finished, $fast_before_resume) = (0, 0, 0);
my ($hold_released, $pending_at_release, $max_pending) = (0, 0, 0);
my ($slow_bytes, $slow_chunks, $poll_turns) = (0, 0, 0);
my $digest = Digest::SHA->new(256);
my $part = '0123456789abcdef' x 256;      # 4 KiB
my $parts = 512;                          # 2 MiB response
my $length = length($part) * $parts;
my $expected_digest = sha256_hex($part x $parts);
my ($produced, $blocked, $resumed, $on_drains, $end_count, $producer_turns, $max_burst)
    = (0) x 7;
my ($producer_waiting, $producer_queued, $producer_done) = (0, 0, 0);
my ($emit, $schedule, $poll);

$schedule = sub {
    return if $producer_queued || $producer_done || $error;
    $producer_queued = 1;
    $loop->defer(sub {
        $producer_queued = 0;
        $emit->();
    });
};
$emit = sub {
    return if !$server_tx || $producer_waiting || $producer_done || $error;
    my $burst = 0;
    $producer_turns++;
    while ($produced < $parts && $burst < 4) {
        # Accepted-byte semantics: never resend this chunk on false.
        my $can_continue = $server_tx->write($part);
        $produced++;
        $burst++;
        if (!$can_continue) {
            $producer_waiting = 1;
            $blocked++;
            last;
        }
    }
    $max_burst = $burst if $burst > $max_burst;
    if ($produced == $parts && !$producer_waiting) {
        $producer_done = 1;
        $end_count++;
        $server_tx->end;
    } elsif (!$producer_waiting) {
        $schedule->();
    }
};

my $server_socket = Linux::Event::IO::Sock::Dgram->new(
    loop => $loop, host => '127.0.0.1', port => 0,
    on_datagram => sub ($sock, $bytes, $peer) {
        $server->receive($bytes, $sock->local->sockaddr, $peer->sockaddr);
    },
    on_drain => sub ($sock) { $server->writable },
    on_error => sub ($sock, $e) {
        $error = "server UDP: $e";
        $loop->stop;
    },
);
$server = Unblock::HTTP::QUIC->server(
    certificate_file => $cert, private_key_file => $key,
    server => Unblock::HTTP::Server->new(
        http3 => { send_buffer_limit => 8192 },
        on_request => sub ($tx, $request) {
            my $target = $request->target;
            $requests++;
            if ($target eq '/slow') {
                $server_tx = $tx;
                $tx->respond(status => 200, stream_body => 1,
                    on_drain => sub ($live_tx) {
                        $on_drains++;
                        $error ||= 'H3 producer transaction changed'
                            unless refaddr($live_tx) == refaddr($server_tx);
                        if ($producer_waiting) {
                            $producer_waiting = 0;
                            $resumed++;
                            $schedule->();
                        }
                    },
                );
                $schedule->();
            } elsif ($target eq '/fast') {
                $tx->respond(status => 200, body => 'fast-and-complete');
            } else {
                $error = "unknown H3 request $target";
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
                on_timer => sub ($t) { undef $server_timer; $server->timeout },
            );
        }
    },
);
$server->start;

$poll = sub {
    return unless $hold_released && $reader && !$error;
    $poll_turns++;
    my $burst = 0;
    while ($burst < 8) {
        my $bytes = $reader->next_chunk;
        last unless defined $bytes;
        $digest->add($bytes);
        $slow_bytes += length($bytes);
        $slow_chunks++;
        $burst++;
    }
    my $pending = $reader->pending_bytes;
    $max_pending = $pending if $pending > $max_pending;
    return if $slow_finished || $error;
    if ($pending > 0) {
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
            # This is an advanced pull Reader, not upper Client on_data.
            http3 => { receive_body => 'buffered' },
            transport => {
                stream_window => 32768,
                connection_window => 131072,
            },
            on_ready => sub ($h3, $manager) {
                $ready++;
                $slow_tx = $h3->request(
                    method => 'GET', scheme => 'https',
                    authority => 'localhost', target => '/slow',
                    receive_body => 'stream',
                    on_response => sub ($tx, $response) {
                        $error ||= 'bad slow response status'
                            unless $response->status == 200;
                        $reader = $tx->response_body;
                    },
                    on_error => sub ($tx, $e) {
                        $error = "slow HTTP3 response: $e";
                        $loop->stop;
                    },
                    on_finish => sub ($tx) {
                        $error ||= 'slow stream did not complete'
                            unless $tx->is_complete;
                        $slow_finished++;
                        $completed++;
                        $loop->stop if $completed == 2 || $error;
                    },
                );
                $h3->request(
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
                        $fast_before_resume = 1 unless $hold_released;
                        $completed++;
                        $loop->stop if $completed == 2 || $error;
                    },
                );
                $hold_timer = Linux::Event::Kernel::Timer->new(
                    loop => $loop, after => 0.5,
                    on_timer => sub ($t) {
                        $hold_released = 1;
                        $pending_at_release = $reader
                            ? $reader->pending_bytes : 0;
                        $max_pending = $pending_at_release
                            if $pending_at_release > $max_pending;
                        $error ||= 'Reader not yet present when hold expired'
                            unless $reader;
                        $error ||= 'slow transaction finished before Reader was drained'
                            if $slow_finished;
                        $error ||= 'all producer data submitted before receiver consumed'
                            if $produced == $parts;
                        $poll->() if !$error;
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
        my $pending = $reader ? $reader->pending_bytes : 0;
        $max_pending = $pending if $pending > $max_pending;
    },
    on_drain => sub ($sock) { $client->writable if $client },
    on_error => sub ($sock, $e) {
        $error = "client UDP: $e";
        $loop->stop;
    },
);
$watchdog = Linux::Event::Kernel::Timer->new(
    loop => $loop, after => 35,
    on_timer => sub ($t) { $error = 'H3 receive-credit watchdog expired'; $loop->stop },
);
$loop->run;

is($error, undef, 'H3 pull-mode slow consumer finishes without error');
is($ready, 1, 'one authenticated H3 client connection');
is($requests, 2, 'two H3 concurrent requests reach the reusable upper Server');
is($fast_finished, 1, 'fast H3 response finishes once');
ok($fast_before_resume, 'fast H3 response completes before slow Reader is released');
is($hold_released, 1, 'slow Reader remains unconsumed for a timed hold');
ok($pending_at_release > 0, 'unconsumed Reader holds body bytes during pause');
ok($pending_at_release < $length, 'unconsumed Reader does not hold entire 2 MiB body');
is($slow_finished, 1, 'slow response reaches terminal only after Reader draining');
is($slow_bytes, $length, 'slow Reader ultimately returns every byte');
is($digest->hexdigest, $expected_digest, 'slow Reader SHA-256 matches');
ok($slow_chunks > 1, 'slow Reader received multiple incremental chunks');
is($produced, $parts, 'producer issues every accepted chunk exactly once');
is($end_count, 1, 'H3 producer calls end exactly once');
ok($blocked > 0 && $resumed > 0, 'H3 outbound producer backs off and resumes');
is($blocked, $resumed, 'producer receives one resume for each blocked write');
ok($max_burst <= 4, 'producer never exceeds four writes per event loop turn');
ok($poll_turns > 1, 'pull Reader consumes in multiple scheduled polling turns');
note("H3 Reader pending at release=$pending_at_release, peak sampled=$max_pending"
    . ", producer blocks=$blocked, resumes=$resumed, poll turns=$poll_turns");

for my $timer ($hold_timer, $poll_timer, $watchdog, $server_timer, $client_timer) {
    $timer->cancel if $timer && $timer->is_active;
}
done_testing;
