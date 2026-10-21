use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::TLS;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;

our ($LOOP, $SERVER, $FAILED, @ALPN_SERVER, @ALPN_CLIENT, $TLS_READY);

# SERVER ADAPTER: Linux::Event decrypts TLS and selects HTTP/2 ALPN before
# the unified Server attaches to the accepted socket.
package Local::WebSocketTLSServerStream;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_server ($self) { $main::SERVER }
sub on_ready ($self) {
    push @main::ALPN_SERVER, $self->selected_alpn // '';
    $self->SUPER::on_ready;
}

# CLIENT ADAPTER: one Stream owns TLS, the queued output and the actual
# HTTP2 engine. HTTP2 Extended CONNECT never changes this input consumer.
package Local::WebSocketTLSClientStream;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    push @main::ALPN_CLIENT, $self->selected_alpn // '';
    $main::TLS_READY++ if $self->is_transport_ready
        && $self->transport_name eq 'tls'
        && defined $self->tls_cipher;
    my $ready = delete $self->{http_ready}
        or die 'missing TLS HTTP Client ready callback';
    $self->{http} = $ready->(
        transport => $self,
        alpn => $self->selected_alpn,
        verified_origin => 1,
    );
}
sub on_data ($self, $bytes) { $self->{http}->input($bytes) }
sub on_eof ($self) {
    $self->{http}->input_eof if $self->{http} && $self->{http}->want_read;
}
sub on_error ($self, $error) {
    $main::FAILED ||= "TLS client failure: $error";
    $main::LOOP->stop;
}
sub on_drain ($self) { $self->{http}->resume_output if $self->{http} }
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'TLS socket closed while sending HTTP2' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
my $dir = tempdir(CLEANUP => 1);
my ($cert, $key) = ("$dir/localhost-cert.pem", "$dir/localhost-key.pem");
my $openssl = system(
    'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout', $key, '-out', $cert,
);
if ($openssl != 0) {
    plan skip_all => 'openssl is required for authenticated TLS/ALPN loopback';
}

$LOOP = Linux::Event::Loop->new;
my ($websocket_server_calls, $ordinary_calls, $server_messages) = (0, 0, 0);
$SERVER = Unblock::HTTP::Server->new(
    http2 => { websocket => 1 },
    defer => sub ($cb) { $LOOP->defer($cb) },
    on_request => sub ($tx, $request) {
        $ordinary_calls++;
        $tx->respond(status => 200, body => 'tls-h2-ok');
    },
    on_websocket => sub ($tx, $request) {
        $websocket_server_calls++;
        return unless $request->target eq '/ws';
        return {
            backend => 'perl',
            on_message => sub ($ws, $payload, $type) {
                $server_messages++;
                $ws->send_text("secure:$payload");
            },
        };
    },
);

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $LOOP,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'Local::WebSocketTLSServerStream',
        tls => {
            cert_file => $cert,
            key_file => $key,
            alpn => $SERVER->alpn_protocols,
        },
    },
);
my @connections;
my $created = 0;
my $client = Unblock::HTTP::Client->new(
    http2 => { websocket => 1 },
    max_connections_per_origin => 1,
    connect_stream => sub ($origin, $alpn, $ready) {
        $created++;
        my $tls = Linux::Event::TLS->client(
            server_name => 'localhost',
            verify => 1,
            ca_file => $cert,
            alpn => $alpn,
        );
        my $stream = Local::WebSocketTLSClientStream->connect(
            loop => $LOOP,
            host => '127.0.0.1',
            port => $listener->port,
            transport => $tls,
        );
        $stream->{http_ready} = $ready;
        push @connections, $stream;
    },
    defer => sub ($cb) { $LOOP->defer($cb) },
);

my ($ws_opened, $ws_echo, $http_body, $http_done, $ws_done) =
    (0, '', '', 0, 0);
my $maybe_finish = sub {
    $LOOP->stop if $ws_echo eq 'secure:hello'
        && $http_body eq 'tls-h2-ok'
        && $http_done && $ws_done;
};
my $fail = sub ($reason) {
    $FAILED ||= "$reason";
    $LOOP->stop;
};

my $websocket_op = $client->connect_websocket(
    url => 'wss://localhost:' . $listener->port . '/ws',
    http_version => '2',
    backend => 'perl',
    on_open => sub ($ws, $tx) {
        $ws_opened++;
        $ws->send_text('hello');
    },
    on_message => sub ($ws, $payload, $type) {
        $ws_echo = $payload;
        $ws->close;
    },
    on_error => sub ($obj, $error) { $fail->($error) },
    on_finish => sub ($tx) {
        $ws_done++;
        $maybe_finish->();
    },
);
my $http_op = $client->request(
    url => 'https://localhost:' . $listener->port . '/ordinary',
    http_version => '2',
    on_response => sub ($tx, $response) {
        $http_body = $response->body;
    },
    on_error => sub ($tx, $error) { $fail->($error) },
    on_finish => sub ($tx) {
        $http_done++;
        $maybe_finish->();
    },
);
my $watchdog = Linux::Event::Kernel::Timer->new(
    loop => $LOOP,
    after => 10,
    on_timer => sub ($timer) { $fail->('TLS H2 WebSocket test timeout') },
);
$LOOP->run;

is($FAILED, undef, 'TLS/ALPN H2 client and server complete without error');
is_deeply(\@ALPN_SERVER, ['h2'], 'real TLS server selects HTTP2 ALPN');
is_deeply(\@ALPN_CLIENT, ['h2'], 'authenticated TLS Client selects HTTP2 ALPN');
is($TLS_READY, 1, 'Client on_ready waits for established authenticated TLS');
is($created, 1, 'ordinary HTTP and WebSocket share one verified TLS connection');
is($ws_opened, 1, 'RFC8441 WebSocket on_open called once after TLS handshake');
is($ws_echo, 'secure:hello', 'encrypted H2 DATA carries WebSocket echo');
is($server_messages, 1, 'server receives one real WebSocket frame');
is($websocket_server_calls, 1, 'only the WebSocket stream enters on_websocket');
is($ordinary_calls, 1, 'ordinary HTTP2 request is served independently');
is($http_body, 'tls-h2-ok', 'ordinary HTTP2 response survives WebSocket traffic');
is($http_done, 1, 'ordinary H2 transaction finishes once');
is($ws_done, 1, 'WebSocket H2 transaction finishes on Close');
is($client->pool_stats->{connections}, 1, 'HTTP2 TLS socket remains pooled');
is($client->pool_stats->{active}, 0, 'all H2 stream credits return to pool');
ok($websocket_op->websocket, 'operation retains established WebSocket object');
ok($http_op->is_terminal, 'ordinary HTTP operation is terminal');

$client->shutdown;
for my $stream (@connections) {
    $stream->close unless $stream->is_closed;
}
$listener->close if $listener->can('close');
$watchdog->cancel if $watchdog->is_active;
done_testing;
