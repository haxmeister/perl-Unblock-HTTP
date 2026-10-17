use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);

BEGIN {
    package Uniform::HTTP::Request;
    sub new { my ($class, %field) = @_; bless \%field, $class }
    sub method { $_[0]{method} }
    sub scheme { $_[0]{scheme} }
    sub authority { $_[0]{authority} }
    sub target { $_[0]{target} }
    $INC{'Uniform/HTTP/Request.pm'} = __FILE__;

    package PoolTest::Transaction;
    sub new {
        my ($class, $engine, $request, $callbacks) = @_;
        bless { engine => $engine, request => $request,
                callbacks => $callbacks, state => 'active' }, $class;
    }
    sub request { $_[0]{request} }
    sub response { $_[0]{response} }
    sub error { $_[0]{error} }
    sub is_cancelled { $_[0]{state} eq 'cancelled' }
    sub is_error { $_[0]{state} eq 'error' }
    sub is_terminal { $_[0]{state} =~ /^(?:complete|error|cancelled)$/ }
    sub cancel {
        my ($self) = @_;
        return if $self->is_terminal;
        $self->{state} = 'cancelled';
        $self->{callbacks}{on_finish}->($self);
    }
    sub finish {
        my ($self, @chunks) = @_;
        return if $self->is_terminal;
        my $response = bless { status => 200 }, 'PoolTest::Response';
        $self->{response} = $response;
        $self->{callbacks}{on_response}->($self, $response)
            if $self->{callbacks}{on_response};
        for my $chunk (@chunks) {
            $self->{callbacks}{on_data}->($self, $chunk)
                if $self->{callbacks}{on_data};
        }
        $self->{callbacks}{on_complete}->($self)
            if $self->{callbacks}{on_complete};
        $self->{state} = 'complete';
        $self->{callbacks}{on_finish}->($self);
    }
    sub fail {
        my ($self, $message) = @_;
        $self->{error} = $message;
        $self->{state} = 'error';
        $self->{callbacks}{on_error}->($self, $message)
            if $self->{callbacks}{on_error};
        $self->{callbacks}{on_finish}->($self);
    }
    package PoolTest::Engine;
    sub new {
        my ($class, %opt) = @_;
        bless { options => \%opt, transactions => [],
                closed => 0, started => 0, capacity => 1 }, $class;
    }
    sub request {
        my ($self, $request, %callback) = @_;
        my $tx = PoolTest::Transaction->new($self, $request, \%callback);
        push @{ $self->{transactions} }, $tx;
        return $tx;
    }
    sub is_closed { $_[0]{closed} }
    sub failed { $_[0]{closed} }
    sub can_open_transaction { 1 }
    sub start { $_[0]{started}++; $_[0] }
    for my $version (1..3) {
        my $package = "Unblock::HTTP${version}::Client";
        (my $file = $package) =~ s{::}{/}g;
        $INC{"$file.pm"} = __FILE__;
        no strict 'refs';
        @{"${package}::ISA"} = ('PoolTest::Engine');
    }

    package PoolTest::Transport;
    sub new { bless {}, shift }
    sub unblock_send { 1 }
    sub unblock_finish {}
    sub unblock_abort {}
    package PoolTest::Quic;
    sub new { bless { ready => 1, closed => 0 }, shift }
    sub ready { $_[0]{ready} }
    sub closed { $_[0]{closed} }
}

use Unblock::HTTP::Client;

my (@deferred, @connects, @seen);
my @hosts;
my $stream_factory = sub {
    my ($origin, $alpn, $ready) = @_;
    push @connects, { origin => $origin, alpn => [@$alpn], ready => $ready };
};
my $defer = sub { push @deferred, $_[0] };
my $drain = sub {
    my $limit = 100;
    while (@deferred && $limit--) { shift(@deferred)->() }
    die "defer loop did not settle" unless $limit > 0;
};

my $client = Unblock::HTTP::Client->new(
    http1 => {}, http2 => {},
    connect_stream => $stream_factory, defer => $defer,
    max_pending_requests => 2,
    max_connections_per_origin => 1,
    max_streams_per_connection => 2,
);
is_deeply([$client->protocols], ['http/1.1', 'h2'], 'reusable protocol policy');
my $one = $client->request(
    method => 'GET', url => 'https://Example.test:444/a?q=1',
    on_response => sub { push @seen, [response => @_] },
    on_finish => sub { push @seen, [finish => @_] },
);
is($one->state, 'connecting', 'operation available during asynchronous connect');
is($client->pending_count, 1, 'pending count includes connecting request');
is(scalar(@connects), 1, 'one factory invoked');
is_deeply($connects[0]{alpn}, ['h2','http/1.1'], 'ALPN choices follow policy');
is($connects[0]{origin}{host}, 'Example.test', 'factory receives host metadata');
my $two = $client->request(
    method => 'GET', url => 'https://example.test:444/b',
    on_response => sub { push @seen, [response_two => @_] },
);
is($client->pending_count, 2, 'second request queued');
ok(!eval { $client->request(url => 'https://example.test:444/c'); 1 },
    'queue bound rejects a third request');
like($@, qr/pending queue is full/, 'clear queue overflow error');
is(scalar(@connects), 1, 'only one concurrent connect per origin');

my $host = PoolTest::Transport->new;
my $attached_engine = $connects[0]{ready}->(transport => $host, alpn => 'h2');
is($client->pending_count, 0, 'H2 has multiplexed both requests');
my ($h2) = @{ $one->{origin}{connections} };
isa_ok($h2->{engine}, 'Unblock::HTTP2::Client');
is(refaddr($attached_engine), refaddr($h2->{engine}), 'factory receives actual attached engine');
is($h2->{host}, $host, 'pool retains transport identity');
is($h2->{active}, 2, 'two active streams share one H2 engine');
ok($one->transaction && $two->transaction, 'both operations hold real transactions');
is($one->transaction->request->target, '/a?q=1', 'URL maps to origin-form target');
is($one->transaction->request->authority, 'Example.test:444', 'URL authority is preserved');
is($h2->{engine}{options}{receive_body}, 'buffered', 'engine performs bounded buffering');
is($h2->{engine}{options}{max_buffered_body_bytes}, 1_048_576, 'buffer limit configured');
$one->transaction->finish('test');
is_deeply([map { $_->[0] } @seen], ['response','finish'],
    'buffered response fires only at completion then terminal notification');
is(refaddr($seen[0][1]), refaddr($one->transaction), 'real transaction passed to callback');
is($one->state, 'complete', 'operation observes final state');
is($h2->{active}, 1, 'finished stream releases pool capacity');
$two->transaction->finish;
$drain->();
is($h2->{active}, 0, 'second transaction finishes');

my @stream;
my $on_data = sub { push @stream, [data => @_] };
my $three = $client->request(
    method => 'POST', url => 'https://example.test:444/upload',
    on_data => $on_data,
    on_response => sub { push @stream, [headers => @_] },
    on_end => sub { push @stream, [end => @_] },
    on_finish => sub { push @stream, [finish => @_] },
);
is(scalar(@connects), 1, 'H2 existing connection reused');
is(refaddr($three->transaction->{callbacks}{on_data}), refaddr($on_data),
    'per-byte on_data is passed directly to engine, no forwarding closure');
$three->transaction->finish('a','b');
is_deeply([map { $_->[0] } @stream], [qw(headers data data end finish)],
    'streamed callback sequencing is correct');
is($three->state, 'complete', 'streamed operation terminates');

# Separate client isolates HTTP/1 serial scheduling and deferred H1 reuse.
my @h1ready;
my @h1defer;
my $h1 = Unblock::HTTP::Client->new(
    http1 => {},
    connect_stream => sub { push @h1ready, $_[2] },
    defer => sub { push @h1defer, $_[0] },
    max_connections_per_origin => 1,
);
my $h1a = $h1->request(url => 'http://foo.test/a');
my $h1b = $h1->request(url => 'http://foo.test/b');
$h1ready[0]->(transport => PoolTest::Transport->new);
is($h1a->state, 'active', 'first H1 request dispatched');
is($h1b->state, 'queued', 'second H1 request waits for connection to be idle');
$h1a->transaction->finish;
is($h1b->state, 'queued', 'H1 not re-entered in on_finish stack');
shift(@h1defer)->();
is($h1b->state, 'active', 'H1 reuse occurs at next event-loop turn');
is(refaddr($h1a->transaction->{engine}), refaddr($h1b->transaction->{engine}),
    'idle H1 engine reused');
$h1b->transaction->finish;
shift(@h1defer)->() if @h1defer;

my (@cancel_callbacks, @cancel_defer);
my $pending = Unblock::HTTP::Client->new(
    http1 => {},
    connect_stream => sub {},
    defer => sub { push @cancel_defer, $_[0] },
);
my $cancel = $pending->request(url => 'https://cancel.test',
    on_error => sub { push @cancel_callbacks, 'error' },
    on_finish => sub { push @cancel_callbacks, ref($_[0]) },
);
is($cancel->cancel, 1, 'pending request cancellation succeeds');
is($cancel->state, 'cancelled', 'pending request cancelled');
is($cancel->cancel, 0, 'cancellation is idempotent');
is_deeply(\@cancel_callbacks, ['Unblock::HTTP::_ClientOperation'],
    'pending cancellation has finish notification but no manufactured error');
is($pending->pending_count, 0, 'cancelled request released queue slot');

my (@error_callbacks, @bad_ready);
my $broken = Unblock::HTTP::Client->new(
    http2 => {}, connect_stream => sub { push @bad_ready, $_[2] },
    defer => $defer,
);
my $failed = $broken->request(url => 'https://bad.test/',
    on_error => sub { push @error_callbacks, [@_] },
);
$bad_ready[0]->(error => 'TLS verification failed');
is($failed->state, 'error', 'factory failure marks operation');
like($failed->error, qr/TLS verification failed/, 'factory error preserved');
is(refaddr($error_callbacks[0][0]), refaddr($failed), 'pre-dispatch failure reports operation');
ok(!defined $failed->transaction, 'factory failure has no fake transaction');

my @quic_ready;
my $h3 = Unblock::HTTP::Client->new(
    http3 => {},
    connect_quic => sub { push @quic_ready, $_[1] },
    defer => $defer,
);
my $h3op = $h3->request(
    url => 'https://quic.test/', http_version => '3',
);
$quic_ready[0]->(connection => PoolTest::Quic->new);
isa_ok($h3op->transaction->{engine}, 'Unblock::HTTP3::Client');
is($h3op->transaction->{engine}{started}, 1, 'HTTP3 starts exactly once');
$h3op->transaction->finish;
ok(!eval { $h3->request(url => 'http://quic.test/'); 1 },
    'H3 cleartext URL rejected');

for my $case (
    [ sub { Unblock::HTTP::Client->new(http1 => {}) }, qr/defer/ ],
    [ sub { Unblock::HTTP::Client->new(http1 => {}, defer => $defer) }, qr/connect_stream/ ],
    [ sub { Unblock::HTTP::Client->new(http3 => {}, defer => $defer) }, qr/connect_quic/ ],
    [ sub { $client->request(url => 'ftp://example.test/') }, qr/scheme/ ],
    [ sub { $client->request(url => 'https://name:password\@example.test/') }, qr/userinfo/ ],
    [ sub { $client->request(url => 'https://example.test/a#x') }, qr/fragment/ ],
    [ sub { $client->request(url => 'https://example.test/', http_version => '3') }, qr/disabled/ ],
    [ sub { $client->request(url => 'https://example.test/', http_version => '99') }, qr/http_version/ ],
) {
    ok(!eval { $case->[0]->(); 1 }, 'invalid client request or factory rejected');
    like($@, $case->[1], 'specific validation error');
}

done_testing;
