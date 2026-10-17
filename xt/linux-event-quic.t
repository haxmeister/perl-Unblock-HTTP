use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
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
my ($body, $error, $requests, $ready) = ('', undef, 0, 0);
my ($header_request, $header_tx, $received_body);
my @server_events;

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
        http3 => {},
        on_headers => sub ($tx, $request) {
            $header_request = $request;
            $header_tx = $tx;
            push @server_events, 'headers';
            $tx->on_finish(sub ($finished) {
                push @server_events, 'finish:' . $finished->state;
            });
        },
        on_request => sub ($tx, $request) {
            $requests++;
            push @server_events, 'request';
            $received_body = $request->body;
            is(refaddr($request), refaddr($header_request), 'same H3 request at headers and completion');
            is(refaddr($tx), refaddr($header_tx), 'same H3 engine transaction');
            ok($request->is_complete && !$request->is_mutable, 'H3 request complete and frozen');
            $tx->respond(status => 200, body => "hello over quic\n");
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
        my $operation = $client->request(
            method => 'POST', url => 'https://localhost/',
            body => "request over quic\n",
            http_version => '3',
            on_response => sub ($tx, $response) {
                $error = "HTTP/3 status " . $response->status
                    unless $response->status == 200;
                $body = $response->body;
            },
            on_error => sub ($tx, $e) {
                $error = "HTTP/3: $e";
                $loop->stop;
            },
            on_finish => sub ($tx) {
                $error ||= 'HTTP/3 request was not complete'
                    unless $tx->is_complete;
                $loop->stop;
            },
        );
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
    loop => $loop, after => 15,
    on_timer => sub ($t) { $error = 'timeout'; $loop->stop },
);
$loop->run;
is($error, undef, 'no QUIC or HTTP/3 error');
is($ready, 1, 'one ready client');
is($requests, 1, 'HTTP/3 server receives request');
is($received_body, "request over quic\n", 'unified H3 callback receives complete buffered body');
is_deeply(\@server_events, ['headers', 'request', 'finish:complete'], 'unified H3 lifecycle order');
is($body, "hello over quic\n", 'HTTP/3 body received');
$server_timer->cancel if $server_timer && $server_timer->is_active;
$client_timer->cancel if $client_timer && $client_timer->is_active;
$limit->cancel if $limit->is_active;
done_testing;
