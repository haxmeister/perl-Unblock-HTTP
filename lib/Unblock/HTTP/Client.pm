package Unblock::HTTP::Client;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed refaddr);
use URI;
use Uniform::HTTP::Request;
use Unblock::HTTP::_Policy;
use Unblock::HTTP::_EngineFactory;
use Unblock::HTTP::_ClientOperation;

our $VERSION = '0.01';

sub new {
    my ($class, @args) = @_;
    croak 'new(): expected named arguments' if @args % 2;
    my %option = @args;
    my %protocols;
    for my $name (qw(http1 http2 http3)) {
        $protocols{$name} = delete $option{$name} if exists $option{$name};
    }
    my $policy = Unblock::HTTP::_Policy->new(%protocols);
    my %factory;
    for my $name (qw(connect_stream connect_quic defer)) {
        $factory{$name} = delete $option{$name} if exists $option{$name};
        croak "new(): $name must be a coderef"
            if exists($factory{$name}) && ref($factory{$name}) ne 'CODE';
    }
    croak 'new(): defer callback is required' unless $factory{defer};
    croak 'new(): connect_stream is required for HTTP/1 or HTTP/2'
        if ($policy->enabled('http/1.1') || $policy->enabled('h2'))
            && !$factory{connect_stream};
    croak 'new(): connect_quic is required for HTTP/3'
        if $policy->enabled('h3') && !$factory{connect_quic};

    my %limit;
    for my $key (qw(max_pending_requests max_connections_per_origin max_streams_per_connection)) {
        my $default = $key eq 'max_pending_requests' ? 128
            : $key eq 'max_connections_per_origin' ? 4 : 32;
        my $value = exists($option{$key}) ? delete($option{$key}) : $default;
        croak "new(): $key must be a positive integer"
            unless defined($value) && !ref($value)
                && $value =~ /\A[0-9]+\z/ && $value > 0;
        $limit{$key} = $value;
    }
    croak 'new(): unknown option: ' . join(', ', sort keys %option) if %option;
    return bless {
        policy => $policy,
        factory => \%factory,
        limit => \%limit,
        pending_count => 0,
        pools => {},
    }, $class;
}

sub protocols { $_[0]{policy}->protocols }
sub alpn_protocols { $_[0]{policy}->alpn_protocols }
sub supports { $_[0]{policy}->enabled($_[1]) }
sub pending_count { $_[0]{pending_count} }

sub request {
    my ($self, @args) = @_;
    croak 'request(): expected named arguments' if @args % 2;
    my %field = @args;
    my $url = delete $field{url};
    croak 'request(): url is required' unless defined($url) && !ref($url) && length($url);
    my $uri = URI->new($url);
    my $scheme = lc($uri->scheme || '');
    croak 'request(): URL scheme must be http or https'
        unless $scheme eq 'http' || $scheme eq 'https';
    croak 'request(): URL must not contain userinfo or a fragment'
        if defined($uri->userinfo) || defined($uri->fragment);
    my $host = $uri->host;
    croak 'request(): URL must include a host'
        unless defined($host) && length($host);
    my $port = $uri->port;
    croak 'request(): invalid URL port'
        unless defined($port) && $port =~ /\A[0-9]+\z/
            && $port > 0 && $port <= 65535;
    my $authority = $uri->authority;
    my $target = $uri->path_query;
    $target = '/' unless defined($target) && length($target);
    $target = '/' . $target if substr($target, 0, 1) eq '?';

    my $version = delete $field{http_version};
    if (defined $version) {
        croak 'request(): http_version must be 1.1, 2 or 3'
            if ref($version) || $version !~ /\A(?:1\.1|2|3)\z/;
        $version = { '1.1' => 'http/1.1', '2' => 'h2', '3' => 'h3' }->{$version};
        croak "request(): required protocol '$version' is disabled"
            unless $self->{policy}->enabled($version);
        croak 'request(): HTTP/3 requires https'
            if $version eq 'h3' && $scheme ne 'https';
    } else {
        $version = ($self->{policy}->enabled('h2')
            || $self->{policy}->enabled('http/1.1')) ? 'tcp' : 'h3';
        croak 'request(): HTTP/3 requires https'
            if $version eq 'h3' && $scheme ne 'https';
    }

    my %callbacks;
    for my $name (qw(
        on_response on_data on_end on_error on_finish on_informational on_drain
    )) {
        next unless exists $field{$name};
        my $cb = delete $field{$name};
        croak "request(): $name must be a coderef" unless ref($cb) eq 'CODE';
        $callbacks{$name} = $cb;
    }
    my $stream_body = delete($field{stream_body}) ? 1 : 0;
    croak 'request(): on_drain requires stream_body'
        if $callbacks{on_drain} && !$stream_body;
    croak 'request(): pending queue is full'
        if $self->{pending_count} >= $self->{limit}{max_pending_requests};
    croak 'request(): do not pass scheme, authority or target with url'
        if grep { exists($field{$_}) } qw(scheme authority target);
    $field{method} = 'GET' unless exists $field{method};
    my $request = Uniform::HTTP::Request->new(
        %field, scheme => $scheme, authority => $authority, target => $target,
    );
    my $key = join('|', $scheme, lc($host), $port);
    my $origin = $self->{pools}{$key} ||= {
        info => {
            scheme => $scheme, host => $host, port => 0 + $port,
            authority => $authority,
        },
        pending => [],
        connections => [],
        connecting => 0,
        pumping => 0,
        scheduled => 0,
    };
    my $op = Unblock::HTTP::_ClientOperation->new(
        $self, $request, \%callbacks, $version, $origin,
    );
    $op->{stream_body} = $stream_body;
    push @{ $origin->{pending} }, $op;
    $self->{pending_count}++;
    $self->_pump($origin);
    return $op;
}

sub _compatible {
    my ($version, $protocol) = @_;
    return $protocol eq $version if $version ne 'tcp';
    return $protocol eq 'h2' || $protocol eq 'http/1.1';
}

sub _usable {
    my ($self, $conn, $version) = @_;
    return 0 unless _compatible($version, $conn->{protocol});
    my $engine = $conn->{engine};
    my $protocol = $conn->{protocol};
    return 0 if $protocol eq 'h3'
        ? ($engine->failed || $conn->{host}->closed)
        : $engine->is_closed;
    return 0 if $protocol eq 'h2'
        && $engine->can('can_open_transaction')
        && !$engine->can_open_transaction;
    my $capacity = $protocol eq 'http/1.1'
        ? 1 : $self->{limit}{max_streams_per_connection};
    return $conn->{active} < $capacity;
}

sub _pump {
    my ($self, $pool) = @_;
    return if $pool->{pumping};
    local $pool->{pumping} = 1;
    $pool->{connections} = [
        grep {
            $_->{active} ||
            ($_->{protocol} eq 'h3'
                ? !($_->{engine}->failed || $_->{host}->closed)
                : !$_->{engine}->is_closed)
        } @{ $pool->{connections} }
    ];
    while (@{ $pool->{pending} }) {
        my $op = $pool->{pending}[0];
        if ($op->is_terminal) {
            shift @{ $pool->{pending} };
            $self->{pending_count}--;
            next;
        }
        my ($conn) = grep { $self->_usable($_, $op->{version}) }
            @{ $pool->{connections} };
        if ($conn) {
            shift @{ $pool->{pending} };
            $self->{pending_count}--;
            $self->_dispatch($pool, $conn, $op);
            next;
        }
        last if $pool->{connecting};
        last if @{ $pool->{connections} } >= $self->{limit}{max_connections_per_origin};
        $self->_connect($pool, $op);
        last if $pool->{connecting};
    }
}

sub _connect {
    my ($self, $pool, $op) = @_;
    my $version = $op->{version};
    my $quic = $version eq 'h3';
    my $factory = $self->{factory}{ $quic ? 'connect_quic' : 'connect_stream' };
    $pool->{connecting} = 1;
    $op->{state} = 'connecting';
    my $called = 0;
    my $ready = sub {
        return if $called++;
        $pool->{connecting} = 0;
        my %result = @_;
        my $engine;
        my $ok = eval { $engine = $self->_connected($pool, $op, $version, \%result); 1 };
        $self->_fail_pending($pool, $op, "$@") unless $ok;
        $self->_pump($pool);
        return $engine;
    };
    my @alpn = $version eq 'tcp' ? $self->alpn_protocols : ($version);
    my $ok = eval {
        if ($quic) {
            $factory->($pool->{info}, $ready);
        } else {
            $factory->($pool->{info}, \@alpn, $ready);
        }
        1;
    };
    $ready->(error => "$@") unless $ok || $called;
}

sub _connected {
    my ($self, $pool, $op, $version, $result) = @_;
    die "$result->{error}" if defined($result->{error}) && length($result->{error});
    my ($protocol, $host, %arg);
    if ($version eq 'h3') {
        $protocol = 'h3';
        $host = $result->{connection};
        die "connect_quic: expected a ready QUIC connection\n"
            unless blessed($host) && $host->can('ready') && $host->can('closed')
                && $host->ready && !$host->closed;
        %arg = (quic => $host);
    } else {
        $protocol = defined($result->{alpn}) && length($result->{alpn})
            ? $result->{alpn} : 'http/1.1';
        die "connect_stream: negotiated unsupported or disabled protocol\n"
            unless ($protocol eq 'h2' || $protocol eq 'http/1.1')
                && $self->{policy}->enabled($protocol)
                && _compatible($version, $protocol);
        $host = $result->{transport};
        die "connect_stream: transport must implement unblock_send, unblock_finish and unblock_abort\n"
            unless blessed($host)
                && $host->can('unblock_send')
                && $host->can('unblock_finish')
                && $host->can('unblock_abort');
        %arg = (transport => $host);
    }
    my $options = $self->{policy}->options($protocol);
    my $engine = Unblock::HTTP::_EngineFactory->create(
        'Client', $protocol, %$options, %arg,
    );
    $engine->start if $protocol eq 'h3';
    push @{ $pool->{connections} }, {
        engine => $engine, host => $host, protocol => $protocol,
        active => 0,
    };
    return $engine;
}

sub _dispatch {
    my ($self, $pool, $conn, $op) = @_;
    $conn->{active}++;
    $op->{state} = 'active';
    my $callbacks = $op->{callbacks};
    my %engine_callback;
    $engine_callback{on_data} = $callbacks->{on_data} if $callbacks->{on_data};
    $engine_callback{on_informational} = $callbacks->{on_informational}
        if $callbacks->{on_informational};
    $engine_callback{on_drain} = $callbacks->{on_drain}
        if $callbacks->{on_drain};

    if ($callbacks->{on_response} && $callbacks->{on_data}) {
        $engine_callback{on_response} = $callbacks->{on_response};
    }
    if ($callbacks->{on_response} || ($callbacks->{on_end} && $callbacks->{on_data})) {
        $engine_callback{on_complete} = sub {
            my ($tx) = @_;
            if ($callbacks->{on_data}) {
                $callbacks->{on_end}->($tx) if $callbacks->{on_end};
            } else {
                $callbacks->{on_response}->($tx, $tx->response)
                    if $callbacks->{on_response};
            }
        };
    }
    if ($callbacks->{on_error}) {
        $engine_callback{on_error} = $callbacks->{on_error};
    }
    $engine_callback{on_finish} = sub {
        my ($tx) = @_;
        return if $op->is_terminal;
        $op->{transaction} ||= $tx;
        $op->{state} = $tx->is_cancelled ? 'cancelled'
            : $tx->is_error ? 'error' : 'complete';
        $op->{error} = $tx->error if $tx->is_error;
        $conn->{active}--;
        my $ok = eval {
            $callbacks->{on_finish}->($tx) if $callbacks->{on_finish};
            1;
        };
        warn $@ unless $ok;
        $self->_schedule($pool);
    };
    my $ok = eval {
        $op->{transaction} = $conn->{engine}->request(
            $op->{request},
            stream_body => $op->{stream_body},
            %engine_callback,
        );
        1;
    };
    unless ($ok) {
        $conn->{active}--;
        $self->_fail_active($op, "$@");
        $self->_schedule($pool);
    }
}

sub _schedule {
    my ($self, $pool) = @_;
    return if $pool->{scheduled}++;
    my $ok = eval {
        $self->{factory}{defer}->(sub {
            $pool->{scheduled} = 0;
            $self->_pump($pool);
        });
        1;
    };
    if (!$ok) {
        $pool->{scheduled} = 0;
        warn "Client defer callback failed: $@";
    }
}

sub _fail_active {
    my ($self, $op, $error) = @_;
    return if $op->is_terminal;
    $op->{state} = 'error';
    $op->{error} = $error;
    $self->_pending_callbacks($op, 1);
}

sub _fail_pending {
    my ($self, $pool, $op, $error) = @_;
    for (my $i = 0; $i < @{ $pool->{pending} }; $i++) {
        next unless $pool->{pending}[$i] == $op;
        splice @{ $pool->{pending} }, $i, 1;
        $self->{pending_count}--;
        last;
    }
    return if $op->is_terminal;
    $op->{state} = 'error';
    $op->{error} = $error;
    $self->_pending_callbacks($op, 1);
}

sub _pending_callbacks {
    my ($self, $op, $failed) = @_;
    my $callbacks = $op->{callbacks};
    if ($failed && $callbacks->{on_error}) {
        eval { $callbacks->{on_error}->($op, $op->{error}); 1 }
            or warn $@;
    }
    if ($callbacks->{on_finish}) {
        eval { $callbacks->{on_finish}->($op); 1 }
            or warn $@;
    }
}

sub _cancel_queued {
    my ($self, $op) = @_;
    my $pool = $op->{origin};
    for (my $i = 0; $i < @{ $pool->{pending} }; $i++) {
        next unless $pool->{pending}[$i] == $op;
        splice @{ $pool->{pending} }, $i, 1;
        $self->{pending_count}--;
        last;
    }
    $self->_pending_callbacks($op, 0);
    $self->_schedule($pool);
}

1;

__END__

=head1 NAME

Unblock::HTTP::Client - Reusable HTTP client with framework transport factories

=head1 SYNOPSIS

    my $client = Unblock::HTTP::Client->new(
        http1 => {}, http2 => {}, http3 => {},
        connect_stream => sub {
            my ($origin, $alpn_choices, $ready) = @_;
            # Framework opens TCP/TLS and completes asynchronously:
            # $ready->(transport => $stream, alpn => $selected_alpn);
        },
        connect_quic => sub {
            my ($origin, $ready) = @_;
            # Framework establishes QUIC and completes asynchronously:
            # $ready->(connection => $ready_quic);
        },
        defer => sub {
            my ($callback) = @_;
            # Framework schedules callback for a later event-loop turn.
        },
    );

    my $operation = $client->request(
        method => 'GET', url => 'https://example.com/',
        on_response => sub {
            my ($tx, $response) = @_;
            print $response->status, "\n";
        },
    );

=head1 DESCRIPTION

One definition handles requests to many origins. It owns HTTP-aware
scheduling and protocol engine objects, not sockets, TLS or timers.
The attached framework owns transports and calls the real engine's
input(), input_eof(), transport_error() and resume_output() methods.
Factories must retain and feed those returned engines.

C<request()> returns an operation handle immediately. Its C<transaction()>
returns the actual engine transaction after dispatch. No transaction
wrapping, method injection or duplicate receive accumulator is used.

=head1 FACTORIES

C<connect_stream($origin, $alpn_choices, $ready)> is for TCP/TLS. The
origin is a hash with scheme, host, port and authority; ALPN choices are
wire names h2 and/or http/1.1. Call C<$ready-E<gt>(transport =E<gt> $host,
alpn =E<gt> $negotiated)> exactly once after connection establishment.
An empty negotiated ALPN means HTTP/1.1, which must be enabled.
Transport must provide unblock_send/unblock_finish/unblock_abort.

C<connect_quic($origin, $ready)> provides a ready, open QUIC connection
and calls C<$ready-E<gt>(connection =E<gt> $quic)> exactly once. The
Client starts the H3 engine; the framework handles Net::QUIC::Driver
UDP and dynamically scheduled timers. Either factory can report
C<$ready-E<gt>(error =E<gt> $reason)>.

C<defer($callback)> MUST arrange a later event-loop turn, not call inline.
This prevents queued requests from reentering an HTTP/1 engine before its
previous on_finish callback has unwound.

=head1 REQUESTS AND SCHEDULING

C<request(method =E<gt> 'GET', url =E<gt> $url, ...)> constructs a
Uniform::HTTP::Request with canonical scheme, authority and origin-form
target. HTTP and HTTPS URLs are accepted; userinfo and fragments are not.
C<http_version =E<gt> '1.1'>, C<'2'> or C<'3'> is strict and cannot
silently downgrade. An ordinary cold request prefers TCP/TLS H2/H1
negotiation; H3 without discovery is only chosen explicitly or when
it is the sole enabled protocol. Alt-Svc, DNS HTTPS discovery and retries
are future slices, and no connection-establishment racing occurs.

Defaults: max_pending_requests = 128, max_connections_per_origin = 4,
max_streams_per_connection = 32. Every limit must be positive.
The request queue rejects overflow. HTTP/1 handles one request at a
time on each connection; HTTP/2 and HTTP/3 multiplex within the stated
per-connection cap, also obeying available engine admission signals.
Connections are reused by origin and the requested protocol policy.
An operation can be cancelled while still queued/connecting.

With no on_data, the engine buffers the complete response within the
configured per-protocol max_buffered_body_bytes (1 MiB by default);
on_response runs once on successful body completion. With on_data,
streaming is selected automatically; on_response runs at final headers,
on_data($tx, $chunk) receives body bytes, and on_end($tx) runs after the
response body. on_finish runs after terminal state. Engine-issued request
callbacks receive actual engine Transaction objects. Factory failures and
pre-dispatch cancellations cannot have a Transaction: on_error/on_finish
receive the operation handle instead. Cancellation is not an error.
No automatic retry is performed.

=head1 LIMITATIONS

WebSocket upgrades, validated Alt-Svc, retry safety, DNS HTTPS discovery,
timeouts, pool idle expiry, and optional framework convenience classes are
not implemented. Frameworks must retain their network transports and use
their normal writable readiness/QUIC timer paths. This branch requires the
coordinated receive/lifecycle engine feature branches, not released engines.

=head1 LICENSE

MIT License.

=cut
