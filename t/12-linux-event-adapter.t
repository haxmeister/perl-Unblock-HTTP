use strict;
use warnings;
use Test::More;

BEGIN {
    package Unblock::HTTP1::Transaction;
    sub on_data { }
    sub on_finish { }
    package Unblock::HTTP2::Transaction;
    sub on_data { }
    sub on_finish { }
    package Unblock::HTTP3::Transaction;
    sub on_data { }
    sub on_finish { }
    package main;

    $INC{'Linux/Event/IO/Sock/Stream.pm'} = __FILE__;
    package Linux::Event::IO::Sock::Stream;
    sub new { bless { sent => [], closed => 0 }, shift }
    sub selected_alpn { $_[0]{alpn} }
    sub write { push @{ $_[0]{sent} }, $_[1]; return 1 }
    sub end { $_[0]{ended}++ }
    sub close { $_[0]{closed}++ }
    sub is_closed { $_[0]{closed} }

    for my $version (1, 2) {
        my $package = 'Unblock::HTTP' . $version . '::Server';
        (my $path = $package) =~ s{::}{/}g;
        $INC{"$path.pm"} = __FILE__;
        no strict 'refs';
        *{$package . '::new'} = sub {
            my ($class, %options) = @_;
            bless { options => \%options, received => [], writable => 1 }, $class;
        };
        *{$package . '::input'} = sub { push @{ $_[0]{received} }, $_[1] };
        *{$package . '::want_read'} = sub { $_[0]{writable} };
        *{$package . '::input_eof'} = sub { $_[0]{eof}++ };
        *{$package . '::resume_output'} = sub { $_[0]{resumed}++ };
        *{$package . '::transport_error'} = sub { $_[0]{error} = $_[1] };
    }
}

use Unblock::HTTP::Adapter::LinuxEvent;
use Unblock::HTTP::Server;
our $request_seen = 0;
our $definition = Unblock::HTTP::Server->new(
    http1 => {}, http2 => {}, on_request => sub { $request_seen++ },
);

{
    package MyStream;
    use parent -norequire, 'Unblock::HTTP::Adapter::LinuxEvent';
    sub http_server { $main::definition }
}
{
    package H2Stream;
    use parent -norequire, 'MyStream';
    sub http_protocol { 'h2' }
}

my $h1 = MyStream->new;
$h1->on_ready;
isa_ok($h1->http, 'Unblock::HTTP1::Server');
$h1->on_data('abc');
is_deeply($h1->http->{received}, ['abc'], 'incoming data reaches underlying engine');
$h1->http->{options}{on_request_end}->('tx','request');
is($request_seen, 1, 'application request callback dispatches');
$h1->on_eof;
is($h1->http->{eof}, 1, 'EOF forwarded');
$h1->on_drain;
is($h1->http->{resumed}, 1, 'backpressure resume forwarded');
$h1->on_error('oops');
is($h1->http->{error}, 'oops', 'transport failure forwarded');
ok($h1->unblock_send('wire'), 'host accepted engine output');
is_deeply($h1->{sent}, ['wire'], 'wire bytes queued');
$h1->unblock_finish;
is($h1->{ended}, 1, 'graceful finish invoked');
$h1->unblock_abort('reason');
is($h1->{closed}, 1, 'abort closes socket');

my $tls = MyStream->new;
$tls->{alpn} = 'h2';
$tls->on_ready;
isa_ok($tls->http, 'Unblock::HTTP2::Server');

my $prior = H2Stream->new;
$prior->on_ready;
isa_ok($prior->http, 'Unblock::HTTP2::Server');

$h1->http->{writable} = 0;
$h1->on_eof;
is($h1->http->{eof}, 1, 'EOF not forwarded again after read stops');

{
    package Local::WebSocketConsumer;
    sub new { bless { received => [], readable => 1 }, shift }
    sub input { push @{ $_[0]{received} }, $_[1] }
    sub want_read { $_[0]{readable} }
    sub input_eof { $_[0]{eof}++ }
    sub resume_output { $_[0]{resumed}++ }
    sub transport_error { $_[0]{error} = $_[1] }
}

my $upgradable = MyStream->new;
$upgradable->on_ready;
my $original = $upgradable->http;
my $websocket = Local::WebSocketConsumer->new;
ok(!$upgradable->websocket, 'no WebSocket exists before HTTP upgrade');
$upgradable->unblock_upgrade($websocket);
is($upgradable->http, $original, 'native HTTP engine remains accessible');
is($upgradable->websocket, $websocket, 'adapter retains the new input consumer');
$upgradable->on_data('frame');
is_deeply($websocket->{received}, ['frame'], 'WebSocket receives post-upgrade data');
is_deeply($original->{received}, [], 'HTTP does not see WebSocket frames');
$upgradable->on_drain;
is($websocket->{resumed}, 1, 'WebSocket receives writable notifications');
is($original->{resumed} || 0, 0, 'retired HTTP parser no longer receives writable notifications');
$upgradable->on_eof;
is($websocket->{eof}, 1, 'WebSocket receives post-upgrade EOF');
$upgradable->on_error('transport down');
is($websocket->{error}, 'transport down', 'WebSocket receives post-upgrade transport error');
ok(!eval { $upgradable->unblock_upgrade($websocket); 1 },
    'adapter rejects duplicate upgrade');
like($@, qr/already upgraded/, 'duplicate upgrade reports reason');
ok(!eval { (MyStream->new)->unblock_upgrade(bless {}, 'UnknownConsumer'); 1 },
    'adapter rejects consumer without transport lifecycle methods');
like($@, qr/consumer is required/, 'incomplete consumer is rejected');

done_testing;
