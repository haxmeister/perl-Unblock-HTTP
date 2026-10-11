use strict;
use warnings;
use Test::More;

BEGIN {
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

{
    package MyStream;
    use parent -norequire, 'Unblock::HTTP::Adapter::LinuxEvent';
    sub on_http_request { $_[0]{request_seen}++ }
}
{
    package H2Stream;
    use parent -norequire, 'MyStream';
    sub http_protocol { 'h2' }
}

my $h1 = MyStream->new;
$h1->on_ready;
is($h1->http->protocol, 'http/1.1', 'plain stream selects HTTP/1');
$h1->on_data('abc');
is_deeply($h1->http->backend->{received}, ['abc'], 'incoming data reaches underlying engine');
$h1->http->backend->{options}{on_request}->('tx','request');
is($h1->{request_seen}, 1, 'application request callback dispatches');
$h1->on_eof;
is($h1->http->backend->{eof}, 1, 'EOF forwarded');
$h1->on_drain;
is($h1->http->backend->{resumed}, 1, 'backpressure resume forwarded');
$h1->on_error('oops');
is($h1->http->backend->{error}, 'oops', 'transport failure forwarded');
ok($h1->unblock_send('wire'), 'host accepted engine output');
is_deeply($h1->{sent}, ['wire'], 'wire bytes queued');
$h1->unblock_finish;
is($h1->{ended}, 1, 'graceful finish invoked');
$h1->unblock_abort('reason');
is($h1->{closed}, 1, 'abort closes socket');

my $tls = MyStream->new;
$tls->{alpn} = 'h2';
$tls->on_ready;
is($tls->http->protocol, 'h2', 'TLS ALPN selects H2');

my $prior = H2Stream->new;
$prior->on_ready;
is($prior->http->protocol, 'h2', 'explicit HTTP/2 prior knowledge selected');

$h1->http->backend->{writable} = 0;
$h1->on_eof;
is($h1->http->backend->{eof}, 1, 'EOF not forwarded again after read stops');

done_testing;
