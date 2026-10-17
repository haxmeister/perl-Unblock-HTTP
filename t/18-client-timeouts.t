use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);

BEGIN {
    package Uniform::HTTP::Request;
    sub new { my ($class, %field) = @_; bless \%field, $class }
    $INC{'Uniform/HTTP/Request.pm'} = __FILE__;

    package TimeoutTest::Transaction;
    sub new {
        my ($class, $engine, $callbacks) = @_;
        bless { engine => $engine, cb => $callbacks, state => 'active' }, $class;
    }
    sub is_cancelled { $_[0]{state} eq 'cancelled' }
    sub is_error { $_[0]{state} eq 'error' }
    sub error { $_[0]{error} }
    sub cancel {
        my ($self) = @_;
        return if $self->{state} ne 'active';
        $self->{state} = 'cancelled';
        $self->{cb}{on_finish}->($self);
    }
    sub finish {
        my ($self) = @_;
        return if $self->{state} ne 'active';
        $self->{state} = 'complete';
        $self->{cb}{on_finish}->($self);
    }

    package TimeoutTest::Engine;
    sub new { my ($class, %option) = @_; bless { option => \%option, closed => 0 }, $class }
    sub request {
        my ($self, $request, %cb) = @_;
        return TimeoutTest::Transaction->new($self, \%cb);
    }
    sub is_closed { $_[0]{closed} }
    sub close { $_[0]{closed} = 1 }
    sub can_open_transaction { 1 }
    for my $num (1, 2) {
        my $package = 'Unblock::HTTP' . $num . '::Client';
        (my $file = $package) =~ s{::}{/}g;
        $INC{"$file.pm"} = __FILE__;
        no strict 'refs';
        @{$package . '::ISA'} = ('TimeoutTest::Engine');
    }

    package TimeoutTest::Host;
    sub new { bless {}, shift }
    sub unblock_send { 1 }
    sub unblock_finish {}
    sub unblock_abort {}
}

use Unblock::HTTP::Client;

my (@timers, @connects, @deferred, @events);
my $timer_factory = sub {
    my ($seconds, $callback) = @_;
    my $timer = { seconds => $seconds, callback => $callback, cancelled => 0, cancels => 0 };
    push @timers, $timer;
    return sub { $timer->{cancelled} = 1; $timer->{cancels}++ };
};
my $drain = sub {
    my $limit = 100;
    while (@deferred && $limit--) { shift(@deferred)->() }
    die 'too many deferred callbacks' unless $limit > 0;
};

my $client = Unblock::HTTP::Client->new(
    http1 => {},
    connect_stream => sub {
        my ($origin, $alpn, $ready) = @_;
        my $connection = { ready => $ready, cancelled => 0 };
        push @connects, $connection;
        return sub { $connection->{cancelled}++ };
    },
    defer => sub { push @deferred, $_[0] },
    schedule_timer => $timer_factory,
    max_connections_per_origin => 1,
);
my $first = $client->request(
    url => 'https://pending.test/first',
    timeout => 0.25,
    on_error => sub { push @events, [error => @_] },
    on_finish => sub { push @events, [finish => @_] },
);
is($first->state, 'connecting', 'first request awaits connection');
is($timers[0]{seconds}, 0.25, 'framework timer takes fractional seconds');
my $second = $client->request(
    url => 'https://pending.test/second',
    timeout => 2,
);
is(scalar(@connects), 1, 'only one pending factory for origin');
$timers[0]{callback}->();
is($first->state, 'error', 'connection deadline reports error');
like($first->error, qr/request timed out after 0\.25 seconds/, 'timeout reason retained');
is_deeply([map { $_->[0] } @events], [qw(error finish)],
    'pending error precedes finish exactly once');
is(refaddr($events[0][1]), refaddr($first), 'pending error receives operation');
is(refaddr($events[1][1]), refaddr($first), 'pending finish receives operation');
is($connects[0]{cancelled}, 1, 'cancel pending factory once');
is($client->pending_count, 1, 'deadline releases only expired queue slot');
ok($timers[0]{cancelled}, 'expired timer cleanup invoked');
$drain->();
is(scalar(@connects), 2, 'next request starts connection establishment');
ok(!defined $connects[0]{ready}->(transport => TimeoutTest::Host->new),
    'late ready ignored after cancellation');
is($second->state, 'connecting', 'new request still connecting');
$connects[1]{ready}->(transport => TimeoutTest::Host->new);
is($second->state, 'active', 'new factory dispatches only second request');
$second->transaction->finish;
ok($timers[1]{cancelled}, 'successful request releases timer');
my $finished_state = $second->state;
$timers[1]{callback}->();
is($second->state, $finished_state, 'late timeout after completion ignored');

my @active_events;
my $active = $client->request(
    url => 'https://active.test/',
    timeout => 4,
    on_error => sub { push @active_events, [error => @_] },
    on_finish => sub { push @active_events, [finish => @_] },
);
$connects[2]{ready}->(transport => TimeoutTest::Host->new);
my $tx = $active->transaction;
$timers[2]{callback}->();
is($active->state, 'error', 'active timeout recorded by operation');
ok($tx->is_cancelled, 'real engine transaction cancelled');
is(refaddr($active->transaction), refaddr($tx), 'real engine transaction identity retained');
like($active->error, qr/request timed out/, 'operation holds timeout reason');
is_deeply([map { $_->[0] } @active_events], [qw(error finish)],
    'active timeout error precedes finish');
is(refaddr($active_events[0][1]), refaddr($tx), 'active error sees real transaction');
is(refaddr($active_events[1][1]), refaddr($tx), 'active finish sees real transaction');
is($active->cancel, 0, 'already timed-out request terminal');
is($timers[2]{cancels}, 1, 'timer released exactly once');
is(scalar(@connects), 3, 'expired active request never retried');

my @cancelled;
my $manual = $client->request(
    url => 'https://manual.test/',
    timeout => 3,
    on_error => sub { push @cancelled, 'error' },
    on_finish => sub { push @cancelled, 'finish' },
);
is($manual->cancel, 1, 'manual pending cancellation');
ok($timers[3]{cancelled}, 'manual cancellation releases timer');
is($connects[3]{cancelled}, 1, 'manual cancellation aborts factory');
$timers[3]{callback}->();
ok(!defined $connects[3]{ready}->(transport => TimeoutTest::Host->new),
    'late readiness after manual cancellation ignored');
is($manual->state, 'cancelled', 'intentional cancellation not timeout');
is_deeply(\@cancelled, ['finish'], 'manual cancellation has no on_error');
is($manual->cancel, 0, 'repeat cancellation idempotent');

my $without_timer = Unblock::HTTP::Client->new(
    http1 => {}, connect_stream => sub {}, defer => sub {},
);
for my $case (
    [ sub { $without_timer->request(url => 'http://x.test/', timeout => 1) }, qr/schedule_timer/ ],
    [ sub { $client->request(url => 'http://x.test/', timeout => 0) }, qr/positive/ ],
    [ sub { $client->request(url => 'http://x.test/', timeout => -1) }, qr/positive/ ],
    [ sub { $client->request(url => 'http://x.test/', timeout => 'NaN') }, qr/positive/ ],
    [ sub { $client->request(url => 'http://x.test/', timeout => []) }, qr/positive/ ],
) {
    ok(!eval { $case->[0]->(); 1 }, 'invalid deadline rejected');
    like($@, $case->[1], 'deadline error explained');
}

my $broken = Unblock::HTTP::Client->new(
    http1 => {}, connect_stream => sub {}, defer => sub {},
    schedule_timer => sub { die "timer setup failed\n" },
);
ok(!eval { $broken->request(url => 'http://bad.test/', timeout => 1); 1 },
    'timer setup failure propagates before enqueue');
is($broken->pending_count, 0, 'timer registration failure leaves queue empty');

done_testing;
