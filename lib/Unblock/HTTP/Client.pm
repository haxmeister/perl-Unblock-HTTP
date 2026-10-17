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
use Unblock::HTTP::_AltSvc;

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
    for my $name (qw(connect_stream connect_quic defer schedule_timer)) {
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

    my $clock = delete $option{alt_svc_clock};
    croak 'new(): alt_svc_clock must be a coderef'
        if defined($clock) && ref($clock) ne 'CODE';
    my $alt_svc = Unblock::HTTP::_AltSvc->new(
        (defined($clock) ? (clock => $clock) : ()),
    );

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
        alt_svc => $alt_svc,
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
    my $strict_version = defined($version) ? 1 : 0;
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
    my $timeout = delete $field{timeout};
    if (defined $timeout) {
        croak 'request(): timeout must be a positive number of seconds'
            if ref($timeout) || $timeout !~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/
                || $timeout <= 0;
        croak 'request(): timeout requires schedule_timer callback'
            unless $self->{factory}{schedule_timer};
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
            key => $key,
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
    if (!$strict_version && $scheme eq 'https'
        && $version eq 'tcp' && $self->{policy}->enabled('h3')) {
        my $advertised = $self->{alt_svc}->lookup($key);
        if ($advertised) {
            $op->{alt_svc} = $advertised;
            $op->{version} = 'h3';
        }
    }
    if (defined $timeout) {
        my $cancel = $self->{factory}{schedule_timer}->(
            0 + $timeout, sub { $self->_request_timeout($op, $timeout) },
        );
        croak 'request(): schedule_timer must return a cancellation coderef'
            unless ref($cancel) eq 'CODE';
        $op->{timer_cancel} = $cancel;
    }
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

# Connection retirement and temporary peer stream exhaustion are different.
# A SETTINGS limit of zero can later increase; do not close an idle H2
# connection merely because it cannot currently open a request.
sub _retired {
    my ($conn) = @_;
    my $engine = $conn->{engine};
    if ($conn->{protocol} eq 'h2') {
        return $engine->can('draining') && $engine->draining ? 1 : 0;
    }
    if ($conn->{protocol} eq 'h3') {
        return 1 if $engine->can('shutdown_started') && $engine->shutdown_started;
        return 1 if $engine->can('remote_shutdown_id')
            && defined $engine->remote_shutdown_id;
    }
    return 0;
}

sub _closed {
    my ($conn) = @_;
    return $conn->{protocol} eq 'h3'
        ? ($conn->{engine}->failed || $conn->{host}->closed)
        : $conn->{engine}->is_closed;
}

sub _usable {
    my ($self, $conn, $version) = @_;
    return 0 unless _compatible($version, $conn->{protocol});
    return 0 if _closed($conn) || _retired($conn);
    my $capacity = $conn->{protocol} eq 'http/1.1'
        ? 1 : $self->{limit}{max_streams_per_connection};
    return 0 if $conn->{active} >= $capacity;
    return 0 if $conn->{protocol} eq 'h2'
        && $conn->{engine}->can('can_open_transaction')
        && !$conn->{engine}->can_open_transaction;
    return 1;
}

sub _pump {
    my ($self, $pool) = @_;
    # Application on_finish can synchronously enqueue another request.
    # Wait for the engine terminal callback to unwind before reusing H1.
    return if $pool->{pumping} || $pool->{callback_depth};
    local $pool->{pumping} = 1;
    my $attempt_budget = $self->{limit}{max_connections_per_origin};
    $pool->{connections} = [
        grep { $_->{active} || (!_closed($_) && !_retired($_)) }
        @{ $pool->{connections} }
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
        if (@{ $pool->{connections} } >= $self->{limit}{max_connections_per_origin}) {
            # Never strand a strict request behind an idle, unusable engine.
            for (my $i = 0; $i < @{ $pool->{connections} }; $i++) {
                my $idle = $pool->{connections}[$i];
                next if $idle->{active};
                my $unusable = !_compatible($op->{version}, $idle->{protocol})
                    || _closed($idle) || _retired($idle);
                next unless $unusable;
                splice @{ $pool->{connections} }, $i, 1;
                $idle->{engine}->close if $idle->{engine}->can('close');
                last;
            }
        }
        last if @{ $pool->{connections} } >= $self->{limit}{max_connections_per_origin};
        # A synchronous factory can produce a connection that immediately
        # refuses streams. Never spin forever creating/replacing engines.
        last unless $attempt_budget--;
        $self->_connect($pool, $op);
        last if $pool->{connecting};
    }
}

sub _connect {
    my ($self, $pool, $op) = @_;
    my $version = $op->{version};
    my $quic = $version eq 'h3';
    my $alt = $op->{alt_svc};
    my $factory = $self->{factory}{ $quic ? 'connect_quic' : 'connect_stream' };
    my $attempt = { op => $op, cancelled => 0, completed => 0 };
    $pool->{connecting} = 1;
    $pool->{attempt} = $attempt;
    $op->{state} = 'connecting';
    my $called = 0;
    my $ready = sub {
        return if $called++;
        # A cancelled/timed-out factory must not attach its late transport.
        return unless $pool->{attempt} && $pool->{attempt} == $attempt;
        $attempt->{completed} = 1;
        delete $pool->{attempt};
        $pool->{connecting} = 0;
        my %result = @_;
        my $engine;
        my $ok = eval { $engine = $self->_connected($pool, $op, $version, \%result); 1 };
        if (!$ok) {
            my $error = "$@";
            if (!$self->_fallback_alternative($pool, $op, $error)) {
                $self->_fail_pending($pool, $op, $error);
            }
        } elsif (!$op->is_terminal && !$op->{transaction}) {
            # Connection establishment is complete. Waiting for peer stream
            # credit is queued work, not another connection in progress.
            $op->{state} = 'queued';
        }
        $self->_pump($pool);
        return $engine;
    };
    my @alpn = $version eq 'tcp'
        ? $self->alpn_protocols : ($version eq 'h3' ? ('h3') : ($version));
    my $cancel;
    my $ok = eval {
        if ($quic) {
            my $info = $pool->{info};
            if ($alt) {
                # The HTTP origin is unchanged. Only the UDP target differs.
                $info = { %$info,
                    alternative_host => $info->{host},
                    alternative_port => $alt->{port},
                };
            }
            $cancel = $factory->($info, $ready);
        } else {
            $cancel = $factory->($pool->{info}, \@alpn, $ready);
        }
        1;
    };
    if (ref($cancel) eq 'CODE' && !$attempt->{completed}) {
        if ($attempt->{cancelled}) {
            eval { $cancel->(); 1 } or warn "connection cancellation failed: $@";
        } else {
            $attempt->{cancel} = $cancel;
        }
    }
    $ready->(error => "$@") unless $ok || $called || $attempt->{cancelled};
}

# A pending request may abandon its own factory without holding the origin
# hostage. The framework may return a cancellation callback from the factory.
sub _abandon_connect {
    my ($self, $pool, $op) = @_;
    my $attempt = $pool->{attempt} or return;
    return unless $attempt->{op} == $op;
    delete $pool->{attempt};
    $pool->{connecting} = 0;
    $attempt->{cancelled} = 1;
    if (my $cancel = delete $attempt->{cancel}) {
        eval { $cancel->(); 1 } or warn "connection cancellation failed: $@";
    }
    return;
}

sub _request_timeout {
    my ($self, $op, $seconds) = @_;
    return if $op->is_terminal;
    my $error = "request timed out after $seconds seconds";
    if (my $tx = $op->{transaction}) {
        # Engine cancellation preserves protocol-specific stream isolation.
        # The operation separately reports expiration as a timeout error.
        $op->{timeout_error} = $error;
        $tx->cancel;
        return;
    }
    $self->_fail_pending($op->{origin}, $op, $error);
    $self->_schedule($op->{origin});
    return;
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
        die "connect_quic: alternative must authenticate the original HTTPS origin\n"
            if $op->{alt_svc}
                && !(defined($result->{verified_origin})
                     && !ref($result->{verified_origin})
                     && $result->{verified_origin} eq '1');
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
    # These advertise Server capabilities; Client constructors reject them.
    delete $options->{enable_connect_protocol} if $protocol eq 'h2';
    delete $options->{enable_extended_connect} if $protocol eq 'h3';
    if ($protocol eq 'h2') {
        # A peer may raise its advertised stream limit later. Wake the pool
        # after processing SETTINGS, not from the byte/stream data path.
        $options->{on_settings} = sub { $self->_schedule($pool) };
    }
    my $engine = Unblock::HTTP::_EngineFactory->create(
        'Client', $protocol, %$options, %arg,
    );
    $engine->start if $protocol eq 'h3';
    push @{ $pool->{connections} }, {
        engine => $engine, host => $host, protocol => $protocol,
        active => 0,
        verified_origin =>
            (defined($result->{verified_origin})
              && !ref($result->{verified_origin})
              && $result->{verified_origin} eq '1') ? 1 : 0,
    };
    return $engine;
}

# Alternative connection failure before dispatch is safe to recover from:
# the engine never saw this request. Once dispatched, no retry is automatic.
sub _fallback_alternative {
    my ($self, $pool, $op, $error) = @_;
    return 0 unless $op->{alt_svc} && !$op->{transaction}
        && !$op->is_terminal
        && ($self->{policy}->enabled('http/1.1') || $self->{policy}->enabled('h2'));
    $self->{alt_svc}->invalidate($op->{origin}{info}{key});
    for my $pending (@{ $pool->{pending} }) {
        next unless $pending->{alt_svc} && !$pending->is_terminal;
        delete $pending->{alt_svc};
        $pending->{version} = 'tcp';
        $pending->{state} = 'queued';
    }
    return 1;
}

sub _learn_alt_svc {
    my ($self, $pool, $conn, $response) = @_;
    return unless $conn->{verified_origin}
        && $pool->{info}{scheme} eq 'https'
        && $self->{policy}->enabled('h3');
    $self->{alt_svc}->observe($pool->{info}{key}, $response);
    return;
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

    if ($pool->{info}{scheme} eq 'https' && $self->{policy}->enabled('h3')) {
        # Once per response headers, not on the body hot path.
        $engine_callback{on_response} = sub {
            my ($tx, $response) = @_;
            $self->_learn_alt_svc($pool, $conn, $response);
            $callbacks->{on_response}->($tx, $response)
                if $callbacks->{on_data} && $callbacks->{on_response};
        };
    } elsif ($callbacks->{on_response} && $callbacks->{on_data}) {
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
        local $pool->{callback_depth} = ($pool->{callback_depth} || 0) + 1;
        $op->{transaction} ||= $tx;
        $op->{state} = $op->{timeout_error} ? 'error'
            : $tx->is_cancelled ? 'cancelled'
            : $tx->is_error ? 'error' : 'complete';
        $op->{error} = $op->{timeout_error} || ($tx->is_error ? $tx->error : undef);
        $op->_cancel_timer;
        $conn->{active}--;
        if ($op->{timeout_error} && $callbacks->{on_error}) {
            eval { $callbacks->{on_error}->($tx, $op->{timeout_error}); 1 }
                or warn $@;
        }
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
        # HTTP/3 returns undef when QUIC has no available bidirectional
        # stream credit. It has not created a Transaction. Do not leave a
        # phantom active slot or replay into an arbitrary engine.
        die "$conn->{protocol} request was not admitted by its engine\n"
            unless defined($op->{transaction}) || $op->is_terminal;
        1;
    };
    unless ($ok) {
        if (!$op->is_terminal) {
            $conn->{active}--;
            $self->_fail_active($op, "$@");
        }
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
    $op->_cancel_timer;
    $self->_pending_callbacks($op, 1);
}

sub _fail_pending {
    my ($self, $pool, $op, $error) = @_;
    $self->_abandon_connect($pool, $op);
    for (my $i = 0; $i < @{ $pool->{pending} }; $i++) {
        next unless $pool->{pending}[$i] == $op;
        splice @{ $pool->{pending} }, $i, 1;
        $self->{pending_count}--;
        last;
    }
    return if $op->is_terminal;
    $op->{state} = 'error';
    $op->{error} = $error;
    $op->_cancel_timer;
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
    $self->_abandon_connect($pool, $op);
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
        schedule_timer => sub {
            my ($seconds, $callback) = @_;
            # Framework schedules a one-shot timer, then returns a coderef
            # that cancels it when the request finishes.
        },
    );

    my $operation = $client->request(
        method => 'GET', url => 'https://example.com/',
        timeout => 15,  # Optional, seconds; requires schedule_timer.
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
For verified HTTPS TLS connections, supply C<verified_origin =E<gt> 1>
only after the framework has validated the peer certificate and matched
it to the original request hostname. Without that explicit assurance,
received Alt-Svc headers are ignored.

C<connect_quic($origin, $ready)> provides a ready, open QUIC connection
and calls C<$ready-E<gt>(connection =E<gt> $quic)> exactly once. The
Client starts the H3 engine; the framework handles Net::QUIC::Driver
UDP and dynamically scheduled timers. Either factory can report
C<$ready-E<gt>(error =E<gt> $reason)>.

When Alt-Svc has advertised HTTP/3, the C<connect_quic> origin hash
additionally contains C<alternative_host> and C<alternative_port>. The
ordinary C<host>, C<port>, C<authority> and request headers still describe
the ORIGINAL origin. The QUIC factory must authenticate its peer against
that original origin, not merely the alternative endpoint, and return
C<verified_origin =E<gt> 1> after that verification. Otherwise the
alternative is rejected and the unsent request may fall back to TCP.

C<defer($callback)> MUST arrange a later event-loop turn, not call inline.
This prevents queued requests from reentering an HTTP/1 engine before its
previous on_finish callback has unwound.

C<schedule_timer($seconds, $callback)> is an optional framework factory
used only when a request has a positive C<timeout> in seconds. It must
schedule a one-shot callback for a future event-loop turn and return a
coderef that cancels that timer. Timer cancellation is invoked once at
terminal cleanup. No event loop, timers or blocking waits are created
inside the core. The timeout covers the ENTIRE request lifetime, including
pending queue time, connection setup and response completion. With no
C<timeout>, no Client operation timer is created.

=head1 REQUESTS AND SCHEDULING

C<request(method =E<gt> 'GET', url =E<gt> $url, ...)> constructs a
Uniform::HTTP::Request with canonical scheme, authority and origin-form
target. HTTP and HTTPS URLs are accepted; userinfo and fragments are not.
C<http_version =E<gt> '1.1'>, C<'2'> or C<'3'> is strict and cannot
silently downgrade. An ordinary cold request prefers TCP/TLS H2/H1
negotiation; H3 without discovery is only chosen explicitly or when
it is the sole enabled protocol. Authenticated same-host Alt-Svc h3 records
can select a later request's QUIC transport. C<clear>, freshness lifetime,
Age and invalidation after failed connections are honored in a bounded
in-memory cache. Cross-host alternatives and DNS HTTPS discovery are not
supported. No connection-establishment racing occurs.

Defaults: max_pending_requests = 128, max_connections_per_origin = 4,
max_streams_per_connection = 32. Every limit must be positive.
The request queue rejects overflow. HTTP/1 handles one request at a
time on each connection; HTTP/2 and HTTP/3 multiplex within the stated
per-connection cap, also obeying available engine admission signals.
Connections are reused by origin and the requested protocol policy.
An operation can be cancelled while still queued/connecting.
A connect factory may return a cancellation coderef to abort establishment
if the initiating operation is cancelled or times out. Later readiness from
an abandoned attempt is ignored, never attached to an HTTP engine, and the
factory is responsible for disposing of any unused transport it created.

With no on_data, the engine buffers the complete response within the
configured per-protocol max_buffered_body_bytes (1 MiB by default);
on_response runs once on successful body completion. With on_data,
streaming is selected automatically; on_response runs at final headers,
on_data($tx, $chunk) receives body bytes, and on_end($tx) runs after the
response body. on_finish runs after terminal state. Engine-issued request
callbacks receive actual engine Transaction objects. Factory failures and
pre-dispatch cancellations cannot have a Transaction: on_error/on_finish
receive the operation handle instead. Cancellation is not an error.
An unsuccessful alternative connection can fall back to TCP BEFORE the
request reaches an HTTP engine, including a POST, because no request has
been transmitted. The Client never automatically replays a dispatched
transaction, even a GET: transport errors cannot establish whether a peer
processed it. A strict HTTP version cannot fall back.

A C<timeout =E<gt> $seconds> requires C<schedule_timer> on the Client.
Expiry before dispatch reports on_error(operation, "request timed out ...")
followed by on_finish(operation); no fake engine Transaction is created.
Expiry after dispatch cancels the real engine transaction using its native
C<cancel()> method, reports on_error($tx, $timeout_error) before
on_finish($tx), and sets the operation state to C<error>. The engine
transaction itself records a cancellation because no protocol parser
error has been invented. An intentional user C<cancel()> remains distinct:
it does not manufacture an on_error callback. No timed-out request is
automatically replayed.

=head1 LIMITATIONS

WebSocket upgrades, cross-host Alt-Svc, retries after dispatch, DNS HTTPS
discovery, pool idle expiry, and optional framework convenience
classes are not implemented. Frameworks must retain their network transports and use
their normal writable readiness/QUIC timer paths. This branch requires the
coordinated receive/lifecycle engine feature branches, not released engines.

=head1 LICENSE

MIT License.

=cut
