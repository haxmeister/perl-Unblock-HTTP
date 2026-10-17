use v5.36;
use strict;
use warnings;
use Time::HiRes qw(time);
use Uniform::HTTP::Request;
use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use Unblock::HTTP::Adapter::LinuxEvent;
use Unblock::HTTP1::Client;
use Unblock::HTTP2::Client;

# Live loopback microbenchmark, intentionally not a CI performance gate.
# One connection and one outstanding small GET per iteration, measuring
# application-level client request construction / scheduling as well as
# native engine processing. The server is the same in both modes.
my ($sample, $warmup) = @ARGV;
$sample = 1000 unless defined $sample;
$warmup = 100 unless defined $warmup;
die "usage: perl bench/client-vs-direct.pl [samples>0] [warmup>=0]\n"
    unless $sample =~ /\A[1-9][0-9]*\z/
        && $warmup =~ /\A(?:0|[1-9][0-9]*)\z/
        && $sample <= 100000 && $warmup <= 10000;

our ($LOOP, $SERVER, $PROTOCOL, $MODE, $READY_CALLBACK, $ENGINE, $CLIENT,
    $SOCKET, $FAILED, $DONE, $TOTAL, $WARMUP, $START, $ELAPSED, $RESPONSES,
    $SCHEDULE);

package BenchServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }

package BenchClientStream;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    if ($main::MODE eq 'direct') {
        my $class = $main::PROTOCOL eq 'h2'
            ? 'Unblock::HTTP2::Client' : 'Unblock::HTTP1::Client';
        $self->{engine} = $class->new(
            transport => $self,
            receive_body => 'buffered',
            max_buffered_body_bytes => 1048576,
        );
    } else {
        $self->{engine} = $main::READY_CALLBACK->(
            transport => $self, alpn => $main::PROTOCOL,
        );
    }
    $main::ENGINE = $self->{engine};
    $main::LOOP->defer(sub { main::next_request() });
}
sub on_data ($self, $bytes) { $self->{engine}->input($bytes) }
sub on_eof ($self) {
    $self->{engine}->input_eof
        if $self->{engine} && $self->{engine}->want_read;
}
sub on_error ($self, $reason) {
    $main::FAILED = "transport failed: $reason";
    $main::LOOP->stop;
}
sub on_drain ($self) {
    $self->{engine}->resume_output if $self->{engine};
}
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'client stream closed during send' if $self->is_closed;
    return $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
sub next_request {
    return if $FAILED || $DONE >= $TOTAL;
    my $on_finish = sub ($tx) {
        if (!$tx->is_complete) {
            $FAILED = 'transaction not complete';
            $LOOP->stop;
            return;
        }
        $DONE++;
        $START = time() if $DONE == $WARMUP;
        if ($DONE == $TOTAL) {
            $ELAPSED = time() - $START;
            $LOOP->stop;
            return;
        }
        $LOOP->defer(sub { next_request() });
    };
    my $on_error = sub ($tx, $error) {
        $FAILED = "HTTP error: $error";
        $LOOP->stop;
    };
    if ($MODE eq 'direct') {
        my $request = Uniform::HTTP::Request->new(
            method => 'GET', scheme => 'http',
            authority => 'localhost', target => '/ping',
        );
        $ENGINE->request(
            $request,
            on_error => $on_error,
            on_finish => $on_finish,
        );
    } else {
        $CLIENT->request(
            method => 'GET', url => 'http://localhost/ping',
            http_version => $PROTOCOL eq 'h2' ? '2' : '1.1',
            on_error => $on_error,
            on_finish => $on_finish,
        );
    }
}

sub run_one {
    my ($mode, $protocol) = @_;
    ($MODE, $PROTOCOL, $LOOP, $FAILED, $DONE, $RESPONSES, $ELAPSED,
        $ENGINE, $CLIENT, $SOCKET, $READY_CALLBACK, $START) =
        ($mode, $protocol, Linux::Event::Loop->new, undef, 0, 0, undef,
         undef, undef, undef, undef, undef);
    $TOTAL = $sample + $warmup;
    $WARMUP = $warmup;
    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_request => sub ($tx, $request) {
            $RESPONSES++;
            $tx->respond(status => 200, body => 'ok');
        },
    );
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP, host => '127.0.0.1', port => 0,
        stream => { class => 'BenchServer' },
    );
    if ($mode eq 'unified') {
        $CLIENT = Unblock::HTTP::Client->new(
            http1 => {}, http2 => {},
            max_connections_per_origin => 1,
            max_pending_requests => 1,
            connect_stream => sub {
                my ($origin, $alpn, $ready) = @_;
                $READY_CALLBACK = $ready;
                $SOCKET = BenchClientStream->connect(
                    loop => $LOOP, host => '127.0.0.1',
                    port => $listener->port,
                );
            },
            defer => sub {
                my ($callback) = @_;
                $LOOP->defer($callback);
            },
        );
        # The first request opens the framework connection; the stream's
        # on_ready then schedules subsequent work after handshake.
        $CLIENT->request(
            method => 'GET', url => 'http://localhost/ping',
            http_version => $protocol eq 'h2' ? '2' : '1.1',
            on_error => sub ($tx, $error) {
                $FAILED = "warmup startup: $error";
                $LOOP->stop;
            },
            on_finish => sub ($tx) {
                if (!$tx->is_complete) {
                    $FAILED = 'warmup startup did not complete';
                    $LOOP->stop;
                    return;
                }
                $DONE++;
                $START = time() if $DONE == $WARMUP;
                $LOOP->defer(sub { next_request() });
            },
        );
    } else {
        $SOCKET = BenchClientStream->connect(
            loop => $LOOP, host => '127.0.0.1',
            port => $listener->port,
        );
    }
    my $watchdog = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 30,
        on_timer => sub ($timer) {
            $FAILED = 'benchmark watchdog timeout';
            $LOOP->stop;
        },
    );
    $LOOP->run;
    $watchdog->cancel if $watchdog->is_active;
    $SOCKET->close if $SOCKET && !$SOCKET->is_closed;
    $listener->close if $listener->can('close');
    die "$mode $protocol: $FAILED\n" if $FAILED;
    die "$mode $protocol: completed $DONE/$TOTAL requests\n"
        unless $DONE == $TOTAL;
    die "$mode $protocol: server processed $RESPONSES, expected $TOTAL\n"
        unless $RESPONSES == $TOTAL;
    return $ELAPSED;
}

print "# Real TCP loopback client dispatch; server is identical in both modes.\n";
print "# Includes Uniform request construction, HTTP parsing and framework overhead.\n";
print "# No statistical confidence, copy/allocation counts or slow-receiver claims.\n";
for my $protocol ('http/1.1', 'h2') {
    my %result;
    for my $mode ('direct', 'unified') {
        my $seconds = run_one($mode, $protocol);
        $result{$mode} = $seconds;
        printf "%-9s %-7s %5d requests in %.5f s (%.0f req/s)\n",
            $protocol, $mode, $sample, $seconds, $sample/$seconds;
    }
    printf "# %s unified/direct wall-time ratio (lower is better): %.3f\n",
        $protocol, $result{unified}/$result{direct};
}
