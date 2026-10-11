use strict;
use warnings;
use Test::More;

BEGIN {
    # Isolated selector test. Real engines have their own wire-level tests.
    for my $version (1 .. 3) {
        for my $side (qw(Client Server)) {
            my $package = 'Unblock::HTTP' . $version . '::' . $side;
            (my $path = $package) =~ s{::}{/}g;
            $INC{"$path.pm"} = __FILE__;
            no strict 'refs';
            *{$package . '::new'} = sub {
                my ($class, %opt) = @_;
                return bless { options => \%opt, events => [] }, $class;
            };
            *{$package . '::input'} = sub { push @{ $_[0]{events} }, ['input', $_[1]]; return length $_[1] };
            *{$package . '::input_eof'} = sub { push @{ $_[0]{events} }, ['eof']; return 1 };
            *{$package . '::transport_error'} = sub { push @{ $_[0]{events} }, ['error', $_[1]]; return 1 };
            *{$package . '::resume_output'} = sub { push @{ $_[0]{events} }, ['resume']; return 1 };
            *{$package . '::close'} = sub { push @{ $_[0]{events} }, ['close']; return 1 };
            *{$package . '::want_read'} = sub { return 1 };
            *{$package . '::want_write'} = sub { return 0 };
            *{$package . '::output'} = sub { return 'wire' };
            *{$package . '::start'} = sub { $_[0]{started} = 1; return $_[0] };
            *{$package . '::started'} = sub { return $_[0]{started} ? 1 : 0 };
            *{$package . '::request'} = sub { my ($self, @arg) = @_; $self->{request_args} = \@arg; return 'transaction' };
        }
    }
}

use Unblock::HTTP::Client;
use Unblock::HTTP::Server;

my $host = bless {}, 'TestTransport';
my $quic = bless {}, 'TestQuic';

my $h1 = Unblock::HTTP::Server->new(transport => $host, on_request => sub {});
is($h1->protocol, 'http/1.1', 'default is HTTP/1.1');
isa_ok($h1->backend, 'Unblock::HTTP1::Server');
is($h1->backend->{options}{transport}, $host, 'host passed through');
ok(!exists $h1->backend->{options}{alpn}, 'ALPN not forwarded to engine');
$h1->input('abc');
$h1->input_eof;
$h1->resume_output;
is_deeply($h1->backend->{events}, [['input', 'abc'], ['eof'], ['resume']], 'stream events are delegated');

my $h2 = Unblock::HTTP::Server->new(alpn => 'h2', transport => $host, on_request => sub {});
isa_ok($h2->backend, 'Unblock::HTTP2::Server');
is($h2->protocol, 'h2', 'H2 protocol remembered');
is($h2->started, 1, 'byte stream engine is already started');

my $h3 = Unblock::HTTP::Server->new(quic => $quic, on_request => sub {});
isa_ok($h3->backend, 'Unblock::HTTP3::Server');
is($h3->protocol, 'h3', 'QUIC selects HTTP/3');
is($h3->started, 0, 'H3 awaits start');
$h3->start;
is($h3->started, 1, 'H3 start delegated');
like(eval { $h3->input('udp'); 1 } ? '' : $@, qr/QUIC streams/, 'H3 byte input is rejected');

my $client = Unblock::HTTP::Client->new(protocol => 'h2', transport => $host);
isa_ok($client->backend, 'Unblock::HTTP2::Client');
is($client->request(method => 'GET', target => '/'), 'transaction', 'request result passed through');
is_deeply($client->backend->{request_args}, [method => 'GET', target => '/'], 'request args unchanged');

for my $case (
    [ { alpn => 'spdy/3', transport => $host }, qr/unsupported HTTP protocol/ ],
    [ { alpn => 'h2', protocol => 'h3', quic => $quic }, qr/either protocol or alpn/ ],
    [ { protocol => 'h3', transport => $host }, qr/HTTP\/3 requires quic/ ],
    [ { protocol => 'h2', quic => $quic }, qr/requires a byte transport/ ],
    [ { transport => $host, quic => $quic }, qr/both quic and transport/ ],
) {
    my ($options, $error) = @$case;
    my $success = eval { Unblock::HTTP::Server->new(%$options); 1 };
    ok(!$success, 'bad protocol/transport combination rejected');
    like($@, $error, 'specific error');
}

done_testing;
