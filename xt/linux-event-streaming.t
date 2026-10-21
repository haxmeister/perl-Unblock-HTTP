use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Digest::SHA qw(sha256_hex);

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Unblock::HTTP::Client;
use Unblock::HTTP::Server;
use FindBin;
use lib "$FindBin::Bin/lib";
use Unblock::HTTP::Adapter::LinuxEvent;

# Larger than the default 1 MiB buffered receive limit on both sides.
# Keep the fixture bounded and repeatable; this is not a benchmark.
my $upload = '0123456789ABCDEF' x 73728;
my $download = 'fedcba9876543210' x 73728;
my $upload_hash = sha256_hex($upload);
my $download_hash = sha256_hex($download);
my $per_protocol = 3;
my $current_protocol;

our ($LOOP, $SERVER, $PROTOCOL, $FAILED, $FINISHED, $SERVER_COUNT,
    $CLIENT_DRAIN, $WATCHDOG, $TIMERS_CANCELLED, $REQUESTS,
    $PRESSURE_INJECTED, $PRESSURE_RELEASES);
our (%SERVER_DIGEST, %SERVER_BYTES, %SERVER_EVENTS, %SERVER_TX,
     %CLIENT_DIGEST, %CLIENT_BYTES, %CLIENT_EVENTS, %CLIENT_CHUNKS,
     %SERVER_CHUNKS, %CLIENT_HEADERS, %SERVER_HEADERS);

# The adapter simulates the documented false-means-accepted boundary once
# per connection, then resumes the real engine on a framework timer.
# This does not pretend to measure real socket congestion.
sub pressure_once ($stream) {
    return 1 if $stream->{pressure_injected}++;
    $PRESSURE_INJECTED++;
    my $timer = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 0.01,
        on_timer => sub ($t) {
            delete $stream->{pressure_timer};
            $PRESSURE_RELEASES++;
            my $engine = $stream->{http} || $stream->{unblock_http};
            $engine->resume_output if $engine && !$stream->is_closed;
            $LOOP->stop if $FINISHED == $REQUESTS
                && $PRESSURE_RELEASES == $PRESSURE_INJECTED;
        },
    );
    $stream->{pressure_timer} = $timer;
    return 0;
}

package StreamingTestServer;
use parent 'Unblock::HTTP::Adapter::LinuxEvent';
sub http_protocol ($self) { $main::PROTOCOL }
sub http_server ($self) { $main::SERVER }
sub unblock_send ($self, $bytes) {
    my $ready = $self->SUPER::unblock_send($bytes);
    return $ready ? main::pressure_once($self) : $ready;
}

package StreamingTestClient;
use parent 'Linux::Event::IO::Sock::Stream';
sub on_ready ($self) {
    my $ready = delete $self->{http_ready}
        or die 'missing waiting HTTP client factory';
    $self->{http} = $ready->(
        transport => $self,
        alpn => $main::PROTOCOL,
    );
}
sub on_data ($self, $bytes) { $self->{http}->input($bytes) }
sub on_eof ($self) {
    $self->{http}->input_eof
        if $self->{http} && $self->{http}->want_read;
}
sub on_error ($self, $error) {
    $main::FAILED = "client transport: $error";
    $main::LOOP->stop;
}
sub on_drain ($self) {
    $self->{http}->resume_output if $self->{http};
    $main::CLIENT_DRAIN++;
}
sub unblock_send ($self, $bytes) {
    my $ready = $self->write($bytes);
    die 'stream closed during HTTP output' if $self->is_closed;
    return $ready ? main::pressure_once($self) : $ready;
}
sub unblock_finish ($self) { $self->end }
sub unblock_abort ($self, $reason) { $self->close }

package main;
is(length($upload) > 1048576, 1, 'uploaded fixture exceeds default buffer limit');
is(length($download) > 1048576, 1, 'downloaded fixture exceeds default buffer limit');

for my $protocol ('http/1.1', 'h2') {
    $current_protocol = $protocol;
    ($PROTOCOL, $LOOP, $FAILED, $FINISHED, $SERVER_COUNT,
        $CLIENT_DRAIN, $TIMERS_CANCELLED, $REQUESTS,
        $PRESSURE_INJECTED, $PRESSURE_RELEASES) =
        ($protocol, Linux::Event::Loop->new, undef, 0, 0, 0, 0,
         $per_protocol, 0, 0);
    (%SERVER_DIGEST, %SERVER_BYTES, %SERVER_EVENTS, %SERVER_TX,
     %CLIENT_DIGEST, %CLIENT_BYTES, %CLIENT_EVENTS, %CLIENT_CHUNKS,
     %SERVER_CHUNKS, %CLIENT_HEADERS, %SERVER_HEADERS) = ();

    $SERVER = Unblock::HTTP::Server->new(
        http1 => {}, http2 => {},
        on_headers => sub ($tx, $request) {
            my $path = $request->target;
            $SERVER_HEADERS{$path}++;
            $SERVER_DIGEST{$path} = Digest::SHA->new(256);
            push @{ $SERVER_EVENTS{$path} }, 'headers';
            $SERVER_TX{$path} = $tx;
            $tx->on_data(sub ($actual_tx, $chunk) {
                $FAILED = "server transaction identity changed at $path"
                    unless refaddr($actual_tx) == refaddr($SERVER_TX{$path});
                $SERVER_DIGEST{$path}->add($chunk);
                $SERVER_BYTES{$path} += length($chunk);
                $SERVER_CHUNKS{$path}++;
            });
            $tx->on_finish(sub ($finished_tx) {
                push @{ $SERVER_EVENTS{$path} }, 'finish:' . $finished_tx->state;
            });
        },
        on_request => sub ($tx, $request) {
            my $path = $request->target;
            $SERVER_COUNT++;
            push @{ $SERVER_EVENTS{$path} }, 'request';
            $FAILED = "server request mismatch at $path"
                unless refaddr($tx) == refaddr($SERVER_TX{$path});
            $FAILED = "server request body not frozen at $path"
                unless $request->is_complete && !$request->is_mutable;
            $FAILED = "upload byte count mismatch at $path"
                unless ($SERVER_BYTES{$path} || 0) == length($upload);
            $FAILED = "upload digest mismatch at $path"
                unless $SERVER_DIGEST{$path}->hexdigest eq $upload_hash;
            $tx->respond(status => 200, body => $download);
        },
        on_error => sub ($tx, $error) {
            $FAILED = "server HTTP: $error";
            $LOOP->stop;
        },
    );

    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $LOOP, host => '127.0.0.1', port => 0,
        stream => { class => 'StreamingTestServer' },
    );
    my @streams;
    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {},
        max_connections_per_origin => 2,
        max_streams_per_connection => 8,
        connect_stream => sub {
            my ($origin, $alpn, $ready) = @_;
            my $stream = StreamingTestClient->connect(
                loop => $LOOP, host => '127.0.0.1',
                port => $listener->port,
            );
            $stream->{http_ready} = $ready;
            push @streams, $stream;
        },
        defer => sub {
            my ($callback) = @_;
            $LOOP->defer($callback);
        },
        schedule_timer => sub {
            my ($seconds, $callback) = @_;
            my $timer = Linux::Event::Kernel::Timer->new(
                loop => $LOOP, after => $seconds,
                on_timer => sub ($t) { $callback->() },
            );
            return sub {
                $timer->cancel if $timer->is_active;
                $TIMERS_CANCELLED++;
            };
        },
    );

    for my $index (1 .. $REQUESTS) {
        my $path = "/large$index";
        $CLIENT_DIGEST{$path} = Digest::SHA->new(256);
        $client->request(
            method => 'POST',
            url => "http://localhost$path",
            http_version => $protocol eq 'h2' ? '2' : '1.1',
            body => $upload,
            timeout => 15,
            on_response => sub ($tx, $response) {
                $CLIENT_HEADERS{$path}++;
                push @{ $CLIENT_EVENTS{$path} }, 'headers';
                $FAILED = "unexpected status at $path: " . $response->status
                    unless $response->status == 200;
                # Streaming should never construct the 1+ MiB body.
                my $stored = $response->body;
                $FAILED = "response unexpectedly buffered at $path"
                    if defined($stored) && length($stored) >= length($download);
            },
            on_data => sub ($tx, $bytes) {
                $CLIENT_DIGEST{$path}->add($bytes);
                $CLIENT_BYTES{$path} += length($bytes);
                $CLIENT_CHUNKS{$path}++;
            },
            on_end => sub ($tx) {
                push @{ $CLIENT_EVENTS{$path} }, 'end';
                $FAILED = "stream byte count mismatch at $path"
                    unless ($CLIENT_BYTES{$path} || 0) == length($download);
                $FAILED = "stream SHA mismatch at $path"
                    unless $CLIENT_DIGEST{$path}->hexdigest eq $download_hash;
            },
            on_error => sub ($tx, $error) {
                $FAILED = "client HTTP $path: $error";
                $LOOP->stop;
            },
            on_finish => sub ($tx) {
                push @{ $CLIENT_EVENTS{$path} }, 'finish';
                $FAILED ||= "incomplete transaction at $path"
                    unless $tx->is_complete;
                $FINISHED++;
                $LOOP->stop if $FAILED || ($FINISHED == $REQUESTS
                    && $PRESSURE_RELEASES == $PRESSURE_INJECTED);
            },
        );
    }

    $WATCHDOG = Linux::Event::Kernel::Timer->new(
        loop => $LOOP, after => 20,
        on_timer => sub ($timer) {
            $FAILED = "watchdog expired for $protocol";
            $LOOP->stop;
        },
    );
    $LOOP->run;

    is($FAILED, undef, "$protocol completes streamed transfer without HTTP error");
    is($SERVER_COUNT, $REQUESTS, "$protocol server receives all large uploads");
    is($FINISHED, $REQUESTS, "$protocol client finishes all large downloads");
    is($TIMERS_CANCELLED, $REQUESTS, "$protocol releases each request timer");
    ok($PRESSURE_INJECTED > 0, "$protocol simulated write congestion");
    is($PRESSURE_RELEASES, $PRESSURE_INJECTED,
        "$protocol resumes every accepted-but-blocked write");

    for my $index (1 .. $REQUESTS) {
        my $path = "/large$index";
        is($SERVER_HEADERS{$path}, 1, "$protocol $path server headers once");
        is($CLIENT_HEADERS{$path}, 1, "$protocol $path client headers once");
        is($SERVER_BYTES{$path}, length($upload), "$protocol $path upload bytes");
        is($CLIENT_BYTES{$path}, length($download), "$protocol $path response bytes");
        ok(($SERVER_CHUNKS{$path} || 0) > 1, "$protocol $path upload arrives in chunks");
        ok(($CLIENT_CHUNKS{$path} || 0) > 1, "$protocol $path download arrives in chunks");
        is_deeply($CLIENT_EVENTS{$path}, ['headers', 'end', 'finish'],
            "$protocol $path streamed response lifecycle");
        is_deeply($SERVER_EVENTS{$path},
            ['headers', 'request', 'finish:complete'],
            "$protocol $path streamed request lifecycle");
    }

    # Do not interpret framework on_drain counts as engine copy metrics.
    note("$protocol transport writable/drain notifications: $CLIENT_DRAIN");
    for my $stream (@streams) {
        $stream->close unless $stream->is_closed;
    }
    $listener->close if $listener->can('close');
    $WATCHDOG->cancel if $WATCHDOG->is_active;
}

done_testing;
