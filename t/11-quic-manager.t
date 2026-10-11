use strict;
use warnings;
use Test::More;

BEGIN {
    $INC{'Net/QUIC/Driver.pm'} = __FILE__;
    package Net::QUIC::Driver;
    sub server { my ($class, %opt) = @_; bless { options => \%opt, fresh => [], events => [] }, $class }
    sub client { my ($class, %opt) = @_; bless { options => \%opt, client => TestQuic->new, events => [] }, $class }
    sub connection { $_[0]{client} }
    sub next_connection { shift @{ $_[0]{fresh} } }
    sub start { push @{ $_[0]{events} }, 'start'; $_[0] }
    sub receive { push @{ $_[0]{events} }, 'receive' }
    sub timeout { push @{ $_[0]{events} }, 'timeout' }
    sub writable { push @{ $_[0]{events} }, 'writable' }

    $INC{'Unblock/HTTP3/Client.pm'} = __FILE__;
    $INC{'Unblock/HTTP3/Server.pm'} = __FILE__;
    package Unblock::HTTP3::Client;
    sub new { my ($class, %opt) = @_; bless { opt => \%opt }, $class }
    sub start { $_[0]{started}++; $_[0] }
    sub started { $_[0]{started} || 0 }
    sub request { my ($self, @arg) = @_; $self->{request} = \@arg; return 'fake tx' }
    package Unblock::HTTP3::Server;
    sub new { my ($class, %opt) = @_; bless { opt => \%opt }, $class }
    sub start { $_[0]{started}++; $_[0] }
    sub started { $_[0]{started} || 0 }
}

{
    package TestQuic;
    sub new { bless { ready => 0, closed => 0 }, shift }
    sub ready { $_[0]{ready} }
    sub closed { $_[0]{closed} }
}

use Unblock::HTTP::QUIC;

my @server_ready;
my $callback = sub {};
my $server = Unblock::HTTP::QUIC->server(
    certificate_file => 'cert', private_key_file => 'key',
    on_request => $callback,
    send => sub {}, set_timeout => sub {},
    on_ready => sub { push @server_ready, shift },
);
isa_ok($server->driver, 'Net::QUIC::Driver');
is($server->driver->{options}{alpn}, 'h3', 'server sets correct ALPN');
ok(!exists $server->driver->{options}{on_request}, 'request handler stays on HTTP side');
$server->start;
my $q1 = TestQuic->new;
my $q2 = TestQuic->new;
push @{ $server->driver->{fresh} }, $q1, $q2;
$server->receive('packet', 'local', 'peer');
is(scalar $server->sessions, 0, 'new connections await handshake');
$q1->{ready} = 1;
$server->timeout;
is(scalar $server->sessions, 1, 'ready connection gets HTTP/3 Server');
is(scalar @server_ready, 1, 'on_ready invoked once');
is($server_ready[0]->backend->{opt}{on_request}, $callback, 'handler forwarded to HTTP/3');
is($server_ready[0]->backend->{started}, 1, 'HTTP/3 started once');
$server->writable;
is(scalar @server_ready, 1, 'no duplicate on_ready');
$q2->{ready} = 1;
$server->receive('next', 'local', 'peer');
is(scalar @server_ready, 2, 'second server session starts after handshake');
$q1->{closed} = 1;
$server->timeout;
is(scalar $server->sessions, 1, 'closed server session is released');
is_deeply($server->driver->{events}, [qw(start receive timeout writable receive timeout)], 'driver events forwarded');

my @client_ready;
my $client = Unblock::HTTP::QUIC->client(
    local => 'local', peer => 'peer', server_name => 'example.test',
    send => sub {}, set_timeout => sub {},
    on_ready => sub { push @client_ready, shift },
);
$client->start;
ok(!defined $client->session, 'client initially not ready');
$client->driver->{client}{ready} = 1;
$client->receive('packet', 'local', 'peer');
isa_ok($client->session, 'Unblock::HTTP::Client');
is($client->session->protocol, 'h3', 'client HTTP/3 selected');
is(scalar @client_ready, 1, 'client on_ready invoked');
$client->session->request(method => 'GET', target => '/');
is_deeply($client->session->backend->{request}, [ method => 'GET', target => '/' ], 'client request passes through');
$client->timeout;
is(scalar @client_ready, 1, 'client handler not repeated');
$client->driver->{client}{closed} = 1;
$client->writable;
ok(!defined $client->session, 'closed client session released');

for my $bad (
    [ sub { Unblock::HTTP::QUIC->server(send => sub {}, set_timeout => sub {}) }, qr/on_request/ ],
    [ sub { Unblock::HTTP::QUIC->client(alpn => 'h2', send => sub {}, set_timeout => sub {}) }, qr/Only the h3 ALPN/ ],
    [ sub { Unblock::HTTP::QUIC->server(on_request => sub {}, http3 => { on_request => sub {} }) }, qr/specified twice/ ],
    [ sub { Unblock::HTTP::QUIC->client(http3 => { quic => 1 }) }, qr/managed/ ],
) {
    ok(!eval { $bad->[0]->(); 1 }, 'invalid manager options rejected');
    like($@, $bad->[1], 'actionable error');
}

done_testing;
