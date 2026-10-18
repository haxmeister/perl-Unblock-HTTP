use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use Linux::Event::IO::Sock::Dgram;
use Linux::Event::Address;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Net::QUIC::Driver;
use Unblock::HTTP::QUIC;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;

my $dir = tempdir(CLEANUP => 1);
my $cert = "$dir/cert.pem";
my $key = "$dir/key.pem";
my $openssl = system('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
    '-nodes', '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout', $key, '-out', $cert);
if ($openssl != 0) {
    plan skip_all => 'openssl executable is required for QUIC test certificate';
}

my $loop = Linux::Event::Loop->new;
my ($server, $client, $client_driver, $server_timer, $client_timer, $client_socket);
my ($error, $requests, $ready, $completed) = (undef, 0, 0, 0);
my $total = 8;
# Exercise a >1 MiB streamed request/response alongside seven ordinary
# buffered transactions on the SAME H3 connection.
my $large_target = '/job8';
my $large_request = '0123456789ABCDEF' x 73728;
my $producer_chunk = 'fedcba9876543210' x 256;  # 4096 bytes
my $producer_chunks = 512;                        # 2 MiB
my $large_response_size = length($producer_chunk) * $producer_chunks;
my $large_response_digest = sha256_hex($producer_chunk x $producer_chunks);
my ($producer_tx, $producer_scheduled, $producer_waiting, $producer_done);
my ($produced_chunks, $producer_blocks, $producer_resumes, $producer_drains,
    $producer_ticks, $producer_max_burst, $producer_end) = (0) x 7;
my ($schedule, $emit);
$schedule = sub {
    return if $producer_scheduled || $producer_done || $error;
    $producer_scheduled = 1;
    $loop->defer(sub {
        $producer_scheduled = 0;
        $emit->() if $emit;
    });
};
$emit = sub {
    return if $producer_waiting || $producer_done || $error;
    my $burst = 0;
    $producer_ticks++;
    while ($produced_chunks < $producer_chunks && $burst < 4) {
        # HTTP3 native write() owns the complete chunk even on false.
        # Resume from the NEXT chunk only after the engine on_drain.
        my $ok = $producer_tx->write($producer_chunk);
        $produced_chunks++;
        $burst++;
        if (!$ok) {
            $producer_blocks++;
            $producer_waiting = 1;
            last;
        }
    }
    $producer_max_burst = $burst if $burst > $producer_max_burst;
    if ($produced_chunks == $producer_chunks && !$producer_waiting) {
        $producer_done = 1;
        $producer_end++;
        $producer_tx->end;
    } elsif (!$producer_waiting) {
        $schedule->();
    }
};
my ($incoming_bytes, $incoming_chunks, $outgoing_bytes, $outgoing_chunks) = (0, 0, 0, 0);
my ($incoming_digest, $outgoing_digest) = (Digest::SHA->new(256), Digest::SHA->new(256));
my (%header_request, %header_tx, %received_body, %response_body,
    %server_events, %client_events, %completed_index);

my $server_socket = Linux::Event::IO::Sock::Dgram->new(
    loop => $loop, host => '127.0.0.1', port => 0,
    on_datagram => sub ($socket, $bytes, $peer) {
        $server->receive($bytes, $socket->local->sockaddr, $peer->sockaddr);
    },
    on_drain => sub ($socket) { $server->writable },
    on_error => sub ($socket, $e) { $error = "server UDP: $e"; $loop->stop },
);

$server = Unblock::HTTP::QUIC->server(
    certificate_file => $cert, private_key_file => $key,
    server => Unblock::HTTP::Server->new(
        # Set a small *H3 native retained-body* threshold. Unlike a
        # TCP transport watermark it is not a total QUIC memory cap.
        http3 => { send_buffer_limit => 8192 },
        on_headers => sub ($tx, $request) {
            my $target = $request->target;
            $header_request{$target} = $request;
            $header_tx{$target} = $tx;
            push @{ $server_events{$target} }, 'headers';
            if ($target eq $large_target) {
                $tx->on_data(sub ($data_tx, $chunk) {
                    $error ||= "H3 large upload transaction changed"
                        if refaddr($data_tx) != refaddr($tx);
                    $incoming_bytes += length($chunk);
                    $incoming_chunks++;
                    $incoming_digest->add($chunk);
                });
            }
            $tx->on_finish(sub ($finished) {
                push @{ $server_events{$target} }, 'finish:' . $finished->state;
            });
        },
        on_request => sub ($tx, $request) {
            my $target = $request->target;
            $requests++;
            push @{ $server_events{$target} }, 'request';
            $received_body{$target} = $request->body
                unless $target eq $large_target;
            is(refaddr($request), refaddr($header_request{$target}),
                "$target H3 request identity");
            is(refaddr($tx), refaddr($header_tx{$target}),
                "$target H3 transaction identity");
            ok($request->is_complete && !$request->is_mutable,
                "$target H3 request complete and frozen");
            if ($target eq $large_target) {
                is($incoming_bytes, length($large_request),
                    'H3 streamed upload byte count');
                is($incoming_digest->hexdigest, sha256_hex($large_request),
                    'H3 streamed upload digest');
                $producer_tx = $tx;
                $tx->respond(
                    status => 200, stream_body => 1,
                    on_drain => sub ($current) {
                        $producer_drains++;
                        $error ||= 'H3 producer callback changed transaction'
                            unless refaddr($current) == refaddr($producer_tx);
                        if ($producer_waiting) {
                            $producer_waiting = 0;
                            $producer_resumes++;
                            $schedule->();
                        }
                    },
                );
                $schedule->();
            } else {
                $tx->respond(status => 200, body => "hello over quic $target\n");
            }
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

# The server uses the small QUIC helper. The client instead uses
# Net::QUIC::Driver directly as the framework transport, handing the
# authenticated ready connection to the shared Client's factory.
my ($ready_factory, $client_quic, $attached);
my $check_ready = sub {
    return unless $ready_factory && $client_quic && $client_quic->ready;
    return if $attached;
    $attached = 1;
    $ready++;
    $ready_factory->(
        connection => $client_quic,
        verified_origin => 1,
    );
};

$client_socket = Linux::Event::IO::Sock::Dgram->connect(
    loop => $loop, host => '127.0.0.1', port => $server_socket->local->port,
    on_ready => sub ($socket) {
        $client = Unblock::HTTP::Client->new(
            http3 => {},
            max_connections_per_origin => 1,
            connect_quic => sub {
                my ($origin, $callback) = @_;
                $ready_factory = $callback;
            },
            defer => sub {
                my ($callback) = @_;
                $loop->defer($callback);
            },
        );
        for my $index (1 .. $total) {
            my $target = '/job' . $index;
            $client->request(
                method => 'POST', url => "https://localhost$target",
                body => $target eq $large_target
                    ? $large_request : "request over quic $target\n",
                http_version => '3',
                ($target eq $large_target ? (
                    on_data => sub ($tx, $chunk) {
                        $outgoing_bytes += length($chunk);
                        $outgoing_chunks++;
                        $outgoing_digest->add($chunk);
                    },
                    on_end => sub ($tx) {
                        push @{ $client_events{$target} }, 'end';
                    },
                ) : ()),
                on_response => sub ($tx, $response) {
                    $error = "HTTP/3 status " . $response->status
                        unless $response->status == 200;
                    $response_body{$target} = $response->body
                        unless $target eq $large_target;
                    push @{ $client_events{$target} }, 'response';
                },
                on_error => sub ($tx, $e) {
                    $error = "HTTP/3 $target: $e";
                    $loop->stop;
                },
                on_finish => sub ($tx) {
                    $error ||= "HTTP/3 $target did not complete"
                        unless $tx->is_complete;
                    $completed_index{$target}++;
                    $completed++;
                    push @{ $client_events{$target} }, 'finish';
                    $loop->stop if $completed == $total || $error;
                },
            );
        }
        $client_driver = Net::QUIC::Driver->client(
            local => $socket->local->sockaddr,
            peer => $socket->peer->sockaddr,
            alpn => 'h3',
            server_name => 'localhost',
            ca_file => $cert,
            send => sub ($datagram) { $socket->send($datagram->data) },
            set_timeout => sub ($seconds) {
                $client_timer->cancel if $client_timer && $client_timer->is_active;
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
        $client_quic = $client_driver->connection;
        $client_driver->start;
        $check_ready->();
    },
    on_datagram => sub ($socket, $bytes, $peer) {
        if ($client_driver) {
            $client_driver->receive(
                $bytes, $socket->local->sockaddr, $peer->sockaddr,
            );
            $check_ready->();
        }
    },
    on_drain => sub ($socket) {
        $client_driver->writable if $client_driver;
        $check_ready->();
    },
    on_error => sub ($socket, $e) { $error = "client UDP: $e"; $loop->stop },
);
my $limit = Linux::Event::Kernel::Timer->new(
    loop => $loop, after => 45,
    on_timer => sub ($t) { $error = 'timeout'; $loop->stop },
);
$loop->run;
is($error, undef, 'no QUIC or HTTP/3 error');
is($ready, 1, 'one ready client');
is($requests, $total, 'HTTP/3 server receives all concurrent requests');
is($completed, $total, 'HTTP/3 client completes all concurrent requests');
for my $index (1 .. $total) {
    my $target = '/job' . $index;
    if ($target eq $large_target) {
        is($incoming_bytes, length($large_request),
            "$target H3 streamed request length");
        is($outgoing_bytes, $large_response_size,
            "$target H3 streamed response length");
        is($outgoing_digest->hexdigest, $large_response_digest,
            "$target H3 streamed response digest");
        ok($incoming_chunks > 1, "$target incoming body is chunked");
        ok($outgoing_chunks > 1, "$target outgoing body is chunked");
        is($produced_chunks, $producer_chunks,
            'H3 native producer submitted all complete chunks');
        is($producer_end, 1, 'H3 producer sent one final end');
        ok($producer_ticks > 1, 'H3 native producer uses deferred ticks');
        ok($producer_max_burst <= 4, 'H3 producer respects per-tick fairness budget');
        ok($producer_blocks > 0, 'H3 native producer observed actual backpressure');
        is($producer_resumes, $producer_blocks,
            'H3 producer resumed once for each accepted blocked write');
        note("H3 stream producer blocks=$producer_blocks"
            . " resumes=$producer_resumes drains=$producer_drains"
            . " ticks=$producer_ticks max burst=$producer_max_burst");
    } else {
        is($received_body{$target}, "request over quic $target\n",
            "$target H3 received complete buffered body");
        is($response_body{$target}, "hello over quic $target\n",
            "$target H3 response body");
    }
    is_deeply($server_events{$target}, [ 'headers', 'request', 'finish:complete' ],
        "$target H3 server lifecycle");
    is_deeply($client_events{$target},
        $target eq $large_target ? [ 'response', 'end', 'finish' ]
                                : [ 'response', 'finish' ],
        "$target H3 client lifecycle");
    is($completed_index{$target}, 1, "$target finished exactly once");
}
$server_timer->cancel if $server_timer && $server_timer->is_active;
$client_timer->cancel if $client_timer && $client_timer->is_active;
$limit->cancel if $limit->is_active;
done_testing;
