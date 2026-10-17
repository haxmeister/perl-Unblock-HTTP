use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Linux::Event::IO::Sock::Dgram;
use Linux::Event::Address;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Unblock::HTTP::QUIC;
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
my ($server, $client, $server_timer, $client_timer, $client_socket);
my ($body, $error, $requests, $ready) = ('', undef, 0, 0);

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
        on_request => sub ($tx, $request) {
            $requests++;
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

$client_socket = Linux::Event::IO::Sock::Dgram->connect(
    loop => $loop, host => '127.0.0.1', port => $server_socket->local->port,
    on_ready => sub ($socket) {
        $client = Unblock::HTTP::QUIC->client(
            local => $socket->local->sockaddr,
            peer => $socket->peer->sockaddr,
            server_name => 'localhost', ca_file => $cert,
            on_ready => sub ($http, $manager) {
                $ready++;
                $http->request(
                    method => 'GET', target => '/', scheme => 'https',
                    authority => 'localhost',
                    on_response => sub ($tx, $response) {
                        $error = "HTTP/3 status " . $response->status
                            unless $response->status == 200;
                    },
                    on_body => sub ($tx, $response, $bytes) { $body .= $bytes },
                    on_complete => sub ($tx) { $loop->stop },
                    on_error => sub ($tx, $e) { $error = "HTTP/3: $e"; $loop->stop },
                );
            },
            send => sub ($datagram) { $socket->send($datagram->data) },
            set_timeout => sub ($seconds) {
                $client_timer->cancel if $client_timer && $client_timer->is_active;
                undef $client_timer;
                if (defined $seconds) {
                    $client_timer = Linux::Event::Kernel::Timer->new(
                        loop => $loop, after => $seconds,
                        on_timer => sub ($t) { undef $client_timer; $client->timeout },
                    );
                }
            },
        );
        $client->start;
    },
    on_datagram => sub ($socket, $bytes, $peer) {
        $client->receive($bytes, $socket->local->sockaddr, $peer->sockaddr) if $client;
    },
    on_drain => sub ($socket) { $client->writable if $client },
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
is($body, "hello over quic\n", 'HTTP/3 body received');
$server_timer->cancel if $server_timer && $server_timer->is_active;
$client_timer->cancel if $client_timer && $client_timer->is_active;
$limit->cancel if $limit->is_active;
done_testing;
