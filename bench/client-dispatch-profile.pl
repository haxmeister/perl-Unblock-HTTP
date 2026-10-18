use strict;
use warnings;
use Time::HiRes qw(time);
use Uniform::HTTP::Request;

# A CPU-only contrast of ready pooled Client request dispatch versus an
# equivalent direct call into a deliberately minimal fake H3 engine.
# Unlike bench/h3-workload-profile.pl, this is NOT a QUIC/network benchmark.
BEGIN {
    package Local::H3::Response;
    sub status { 200 }
    sub header_values { [] }

    package Local::H3::Transaction;
    sub new {
        my ($class, $callbacks) = @_;
        bless {
            callbacks => $callbacks,
            state => 'active',
            response => bless({}, 'Local::H3::Response'),
        }, $class;
    }
    sub response { $_[0]{response} }
    sub is_cancelled { $_[0]{state} eq 'cancelled' }
    sub is_error { $_[0]{state} eq 'error' }
    sub is_complete { $_[0]{state} eq 'complete' }
    sub error { $_[0]{error} }
    sub finish {
        my ($self) = @_;
        die "double finish" unless $self->{state} eq 'active';
        my $cb = $self->{callbacks};
        $cb->{on_response}->($self, $self->{response})
            if $cb->{on_response};
        $cb->{on_complete}->($self) if $cb->{on_complete};
        $self->{state} = 'complete';
        $cb->{on_finish}->($self) if $cb->{on_finish};
    }

    package Local::H3::Engine;
    sub new { bless { closed => 0 }, shift }
    sub start { $_[0] }
    sub failed { $_[0]{closed} }
    sub is_closed { $_[0]{closed} }
    sub close { $_[0]{closed} = 1 }
    sub shutdown_started { 0 }
    sub remote_shutdown_id { undef }
    sub request {
        my ($self, $request, %callbacks) = @_;
        return Local::H3::Transaction->new(\%callbacks);
    }

    package Unblock::HTTP3::Client;
    our @ISA = ('Local::H3::Engine');
    $INC{'Unblock/HTTP3/Client.pm'} = __FILE__;

    package Local::H3::Quic;
    sub new { bless {}, shift }
    sub ready { 1 }
    sub closed { 0 }
}

use Unblock::HTTP::Client;

my ($iterations, $rounds) = @ARGV;
$iterations = 10000 unless defined $iterations;
$rounds = 5 unless defined $rounds;
die "usage: perl bench/client-dispatch-profile.pl [iterations:100..100000] [rounds:1..15]\n"
    unless $iterations =~ /\A[1-9][0-9]*\z/
        && $rounds =~ /\A[1-9][0-9]*\z/
        && $iterations >= 100 && $iterations <= 100000
        && $rounds <= 15;

my $url = 'https://localhost/profile';
my $engine = Local::H3::Engine->new;
my @deferred;
my $client = Unblock::HTTP::Client->new(
    http3 => {},
    max_connections_per_origin => 1,
    max_streams_per_connection => 32,
    connect_quic => sub {
        $_[1]->(connection => Local::H3::Quic->new, verified_origin => 1);
    },
    defer => sub { push @deferred, $_[0] },
);

my ($finished, $responses) = (0, 0);
my $on_response = sub {
    my ($tx, $response) = @_;
    die "bad response" unless $response->status == 200;
    ++$responses;
};
my $on_finish = sub {
    die "bad terminal transaction" unless $_[0]->is_complete;
    ++$finished;
};
my $on_complete = sub {
    my ($tx) = @_;
    $on_response->($tx, $tx->response);
};

# Make both paths use a warm, single H3 connection before timing.
my $seed = $client->request(
    url => $url, http_version => '3',
    on_response => $on_response, on_finish => $on_finish,
);
die "not dispatched" unless $seed->state eq 'active';
$seed->transaction->finish;
die "seed did not complete" unless $seed->state eq 'complete';
undef $seed;
my ($pool) = values %{ $client->{pools} };
die "expected one warm pool" unless $pool
    && @{ $pool->{connections} } == 1;
die "unexpected deferred work after seed" if @deferred;

my %case = (
    direct_mock => sub {
        my $request = Uniform::HTTP::Request->new(
            method => 'GET', scheme => 'https',
            authority => 'localhost', target => '/profile',
        );
        my $tx = $engine->request(
            $request,
            on_complete => $on_complete,
            on_finish => $on_finish,
        );
        $tx->finish;
    },
    unified_mock => sub {
        my $op = $client->request(
            method => 'GET', url => $url, http_version => '3',
            on_response => $on_response, on_finish => $on_finish,
        );
        my $tx = $op->transaction or die "unified operation not dispatched";
        $tx->finish;
    },
);

# This comparison includes the fake engine's finish callbacks in both
# paths. It deliberately excludes network, TLS, QUIC, timers and body IO.
# It is meant to determine whether request setup/Client dispatch warrants
# further measurement, not estimate actual end-to-end H3 overhead.
my %times;
my @names = qw(direct_mock unified_mock);
print "# ready pooled Client vs direct fake HTTP3 engine; same canonical Uniform type\n";
print "# zero network/TLS/QUIC work; callback completion included in both cases\n";
print "# iterations=$iterations rounds=$rounds, alternating order; diagnostic only\n";
for my $round (1 .. $rounds) {
    my @order = $round % 2 ? @names : reverse @names;
    for my $name (@order) {
        my $f = $case{$name};
        my ($prior_finish, $prior_response) = ($finished, $responses);
        $f->() for 1 .. 200;
        my $start = time();
        $f->() for 1 .. $iterations;
        my $elapsed = time() - $start;
        die "callback count mismatch ($name)\n"
            unless $finished - $prior_finish == $iterations + 200
                && $responses - $prior_response == $iterations + 200;
        die "unified pool not quiescent\n"
            if $name eq 'unified_mock'
                && (keys %{ $client->{active_operations} }
                    || $pool->{connections}[0]{active}
                    || @{ $pool->{pending} }
                    || $client->pending_count
                    || @deferred);
        push @{ $times{$name} }, $elapsed;
        printf "%-13s round=%d %.3f us/request (%d completions)\n",
            $name, $round, 1_000_000 * $elapsed / $iterations, $iterations;
    }
}
my %median;
for my $name (@names) {
    my @ordered = sort { $a <=> $b } @{ $times{$name} };
    $median{$name} = $ordered[int(@ordered / 2)];
    printf "# %-13s median %.3f us/request\n",
        $name, 1_000_000 * $median{$name} / $iterations;
}
printf "# unified/direct mock ratio %.3f (not network overhead)\n",
    $median{unified_mock} / $median{direct_mock};

# Optional phase split. This wrapper deliberately samples two clocks
# per boundary per request, and therefore PERTURBS the benchmark.
# Do not compare these instrumented totals to the uninstrumented
# per-request figures above or interpret them as exact production costs.
my $split = $ENV{UNBLOCK_H3_DISPATCH_SPLIT} // '0';
die "UNBLOCK_H3_DISPATCH_SPLIT must be 0 or 1\n"
    unless $split =~ /\A[01]\z/;
if ($split) {
    my $original_dispatch = Unblock::HTTP::Client->can('_dispatch');
    my $original_engine_request = Local::H3::Engine->can('request');
    for my $round (1 .. $rounds) {
        my ($request_time, $dispatch_time, $engine_time) = (0, 0, 0);
        my ($request_count, $dispatch_count, $engine_count) = (0, 0, 0);
        {
            no warnings 'redefine';
            local *Unblock::HTTP::Client::_dispatch = sub {
                my $start = time();
                my $out = $original_dispatch->(@_);
                $dispatch_time += time() - $start;
                $dispatch_count++;
                return $out;
            };
            local *Local::H3::Engine::request = sub {
                my $start = time();
                my $out = $original_engine_request->(@_);
                $engine_time += time() - $start;
                $engine_count++;
                return $out;
            };
            for (1 .. $iterations) {
                my $start = time();
                my $op = $client->request(
                    method => 'GET', url => $url, http_version => '3',
                    on_response => $on_response, on_finish => $on_finish,
                );
                $request_time += time() - $start;
                $request_count++;
                my $tx = $op->transaction
                    or die "split: operation did not dispatch";
                $tx->finish;
            }
        }
        die "split: unexpected request, dispatch or fake engine count\n"
            unless $request_count == $iterations
                && $dispatch_count == $iterations
                && $engine_count == $iterations;
        die "split: request pool was not quiescent\n"
            if keys(%{ $client->{active_operations} })
                || $pool->{connections}[0]{active}
                || $client->pending_count || @deferred;
        printf "# split round=%d request_us=%.3f outside_dispatch_us=%.3f"
            . " dispatch_us=%.3f outside_engine_us=%.3f"
            . " fake_engine_us=%.3f (CLOCK-INSTRUMENTED)\n",
            $round,
            1_000_000 * $request_time / $iterations,
            1_000_000 * ($request_time - $dispatch_time) / $iterations,
            1_000_000 * $dispatch_time / $iterations,
            1_000_000 * ($dispatch_time - $engine_time) / $iterations,
            1_000_000 * $engine_time / $iterations;
    }
}
