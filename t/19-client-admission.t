use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);

BEGIN {
    package Uniform::HTTP::Request;
    sub new { my ($class, %f) = @_; bless \%f, $class }
    $INC{'Uniform/HTTP/Request.pm'} = __FILE__;

    package AdmissionTest::Transaction;
    sub new { my ($class, $engine, $cb) = @_; bless { engine => $engine, cb => $cb, state => 'active' }, $class }
    sub is_error { $_[0]{state} eq 'error' }
    sub is_cancelled { $_[0]{state} eq 'cancelled' }
    sub error { $_[0]{error} }
    sub finish {
        my ($self) = @_;
        return unless $self->{state} eq 'active';
        $self->{state} = 'complete';
        $self->{engine}{active}--;
        $self->{cb}{on_finish}->($self);
    }
    sub cancel {
        my ($self) = @_;
        return unless $self->{state} eq 'active';
        $self->{state} = 'cancelled';
        $self->{engine}{active}--;
        $self->{cb}{on_finish}->($self);
    }

    package AdmissionTest::Engine;
    our ($INITIAL_LIMIT, $INITIAL_DRAIN, $NO_H3_STREAM);
    sub new {
        my ($class, %option) = @_;
        bless {
            option => \%option, active => 0, closed => 0, failed => 0,
            peer_limit => defined($INITIAL_LIMIT) ? $INITIAL_LIMIT : 100,
            draining => $INITIAL_DRAIN ? 1 : 0,
            no_stream => $NO_H3_STREAM ? 1 : 0,
            remote_shutdown_id => undef,
        }, $class;
    }
    sub is_closed { $_[0]{closed} }
    sub failed { $_[0]{failed} }
    sub close { $_[0]{closed} = 1 }
    sub draining { $_[0]{draining} }
    sub remote_shutdown_id { $_[0]{remote_shutdown_id} }
    sub shutdown_started { 0 }
    sub start { $_[0]{started}++; $_[0] }
    sub can_open_transaction {
        my ($self) = @_;
        return !$self->{closed} && !$self->{draining}
            && $self->{active} < $self->{peer_limit};
    }
    sub peer_limit {
        my ($self, $value) = @_;
        $self->{peer_limit} = $value;
        my $callback = $self->{option}{on_settings};
        $callback->($self, { max_concurrent_streams => $value },
            { max_concurrent_streams => $value }) if $callback;
    }
    sub request {
        my ($self, $request, %cb) = @_;
        return if $self->{no_stream};
        die 'peer refuses streams' if $self->isa('Unblock::HTTP2::Client')
            && !$self->can_open_transaction;
        $self->{active}++;
        return AdmissionTest::Transaction->new($self, \%cb);
    }
    for my $num (1..3) {
        my $package = 'Unblock::HTTP' . $num . '::Client';
        (my $path = $package) =~ s{::}{/}g;
        $INC{$path . '.pm'} = __FILE__;
        no strict 'refs';
        @{$package . '::ISA'} = ('AdmissionTest::Engine');
    }

    package AdmissionTest::Host;
    sub new { bless {}, shift }
    sub unblock_send { 1 }
    sub unblock_finish {}
    sub unblock_abort {}
    package AdmissionTest::Quic;
    sub new { bless { ready => 1, closed => 0 }, shift }
    sub ready { $_[0]{ready} }
    sub closed { $_[0]{closed} }
}

use Unblock::HTTP::Client;
my @deferred;
my $defer = sub { push @deferred, $_[0] };
my $flush = sub {
    my $budget = 100;
    while (@deferred && $budget--) { shift(@deferred)->() }
    die 'unbounded deferred churn' unless $budget > 0;
};

# SETTINGS concurrency zero is temporary: do not churn live connections.
{
    local $AdmissionTest::Engine::INITIAL_LIMIT = 0;
    my ($calls, @engines) = (0);
    my $client = Unblock::HTTP::Client->new(
        http2 => {}, max_connections_per_origin => 1, defer => $defer,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            $calls++;
            push @engines, $ready->(transport => AdmissionTest::Host->new, alpn => 'h2');
        },
    );
    my $one = $client->request(url => 'https://zero.test/one');
    my $two = $client->request(url => 'https://zero.test/two');
    is($calls, 1, 'H2 peer limit zero does not cause connection churn');
    is($one->state, 'queued', 'connected request waits for peer stream capacity');
    is($two->state, 'queued', 'second request queued');
    is($client->pending_count, 2, 'unadmitted work occupies bounded queue');
    ok(!$engines[0]{closed}, 'idle zero-credit H2 remains open');
    $engines[0]->peer_limit(1);
    $flush->();
    is($one->state, 'active', 'SETTINGS increase admits first request');
    is($two->state, 'queued', 'peer limit of one is respected');
    $one->transaction->finish;
    $flush->();
    is($two->state, 'active', 'second request starts after stream release');
    is($calls, 1, 'same H2 engine reused');
    $two->transaction->finish;
    $flush->();
}

# A drained active connection retains its slot until the last stream ends.
{
    local $AdmissionTest::Engine::INITIAL_LIMIT = 1;
    my @created;
    my $client = Unblock::HTTP::Client->new(
        http2 => {}, max_connections_per_origin => 1, defer => $defer,
        connect_stream => sub {
            push @created, $_[2]->(
                transport => AdmissionTest::Host->new, alpn => 'h2',
            );
        },
    );
    my $one = $client->request(url => 'https://drain.test/one');
    my $old = $one->transaction->{engine};
    $old->{draining} = 1;
    my $two = $client->request(url => 'https://drain.test/two');
    is($two->state, 'queued', 'draining active engine not replaced prematurely');
    is(scalar(@created), 1, 'active connection counts toward cap');
    $one->transaction->finish;
    $flush->();
    is(scalar(@created), 2, 'drained idle engine replaced');
    is($two->state, 'active', 'pending work dispatched to replacement H2');
    isnt(refaddr($two->transaction->{engine}), refaddr($old), 'retired engine not reused');
    $two->transaction->finish;
    $flush->();
}

# Synchronous factory yielding an immediately draining engine must not spin.
{
    local $AdmissionTest::Engine::INITIAL_DRAIN = 1;
    my $calls = 0;
    my $client = Unblock::HTTP::Client->new(
        http2 => {}, max_connections_per_origin => 2, defer => $defer,
        connect_stream => sub {
            $calls++;
            $_[2]->(transport => AdmissionTest::Host->new, alpn => 'h2');
        },
    );
    my $op = $client->request(url => 'https://reentrant.test/');
    ok($calls > 0 && $calls <= 2, 'synchronous factory attempts bounded per pump');
    ok($client->pending_count <= 1, 'no duplicate queue entries created');
    $op->cancel;
    $flush->();
}

# H3 request() may return undef if there is no QUIC bidi stream credit.
{
    local $AdmissionTest::Engine::NO_H3_STREAM = 1;
    my $client = Unblock::HTTP::Client->new(
        http3 => {}, defer => $defer,
        connect_quic => sub { $_[1]->(connection => AdmissionTest::Quic->new) },
    );
    my (@errors, @finishes);
    my $op = $client->request(url => 'https://h3.test/', http_version => '3',
        on_error => sub { push @errors, [@_] },
        on_finish => sub { push @finishes, $_[0] },
    );
    is($op->state, 'error', 'H3 no-stream result is a terminal non-admission');
    like($op->error, qr/not admitted/, 'H3 admission error is explicit');
    ok(!defined($op->transaction), 'no phantom transaction created');
    is($client->pending_count, 0, 'queue slot released');
    is(scalar(@errors), 1, 'one H3 non-admission error');
    is(refaddr($errors[0][0]), refaddr($op), 'error receives operation, not fake tx');
    is(scalar(@finishes), 1, 'one finish notification');
    is($op->{origin}{connections}[0]{active}, 0, 'H3 connection slot released');
    $flush->();
}

# A GOAWAY-marked idle H3 is not reused.
{
    my @engines;
    my $client = Unblock::HTTP::Client->new(
        http3 => {}, defer => $defer, max_connections_per_origin => 1,
        connect_quic => sub { push @engines, $_[1]->(connection => AdmissionTest::Quic->new) },
    );
    my $one = $client->request(url => 'https://goaway.test/', http_version => '3');
    my $old = $one->transaction->{engine};
    $one->transaction->finish;
    $old->{remote_shutdown_id} = 0;
    my $two = $client->request(url => 'https://goaway.test/next', http_version => '3');
    is(scalar(@engines), 2, 'GOAWAY id zero retires idle H3');
    is($two->state, 'active', 'replacement H3 serves next request');
    isnt(refaddr($two->transaction->{engine}), refaddr($old), 'GOAWAY engine not reused');
    $two->transaction->finish;
    $flush->();
}

# Six independent origins progress without a global head-of-line stall.
{
    my @ready;
    my $client = Unblock::HTTP::Client->new(
        http1 => {}, defer => $defer,
        max_connections_per_origin => 1, max_pending_requests => 12,
        connect_stream => sub { push @ready, $_[2] },
    );
    my @ops;
    for my $i (1..6) {
        push @ops, $client->request(url => 'http://origin' . $i . '.test/one');
        push @ops, $client->request(url => 'http://origin' . $i . '.test/two');
    }
    is(scalar(@ready), 6, 'six independent connection factories started');
    is($client->pending_count, 12, 'global pending limit enforced');
    ok(!eval { $client->request(url => 'http://overflow.test/'); 1 }, 'queue overflow rejected');
    for my $cb (@ready) { $cb->(transport => AdmissionTest::Host->new) }
    is($client->pending_count, 6, 'one H1 request per origin dispatched');
    for (my $i=0; $i < @ops; $i+=2) {
        is($ops[$i]->state, 'active', 'first request active');
        $ops[$i]->transaction->finish;
    }
    $flush->();
    for (my $i=1; $i < @ops; $i+=2) {
        is($ops[$i]->state, 'active', 'second request active');
        $ops[$i]->transaction->finish;
    }
    $flush->();
    is($client->pending_count, 0, 'all independent queues drained');
}

done_testing;
