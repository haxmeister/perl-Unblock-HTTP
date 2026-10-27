use strict;
use warnings;
use Test::More;
use Unblock::HTTP::Server;
use Unblock::HTTP1::Server;

{
    package Local::CompletionHost;
    sub new { bless { output => '' }, shift }
    sub unblock_send { $_[0]{output} .= $_[1]; return 1 }
    sub unblock_finish { $_[0]{finished} = 1 }
    sub unblock_abort { $_[0]{aborted} = $_[1] }
}

my @seen;
my $definition = Unblock::HTTP::Server->new(
    http1 => {},
    on_request => sub {
        my ($tx, $request) = @_;
        push @seen, [
            $request->target, $request->body,
            $request->is_complete, $request->is_mutable,
        ];
        $tx->respond(status => 200, body => $request->target);
    },
);
ok(!exists $definition->{callbacks}{on_request},
    'definition does not insert an artificial early callback');
my $host = Local::CompletionHost->new;
my $engine = $definition->attach_stream(transport => $host);
isa_ok($engine, 'Unblock::HTTP1::Server');
ok(!exists $engine->{callbacks}{on_request},
    'HTTP1 connection receives no artificial early callback');
my $input = "POST /body HTTP/1.1\r\nHost: example.test\r\nContent-Length: 3\r\n\r\na";
$engine->input($input);
is_deeply(\@seen, [], 'application waits for entire body');
$engine->input('bc');
is_deeply(\@seen, [ ['/body', 'abc', 1, 0] ],
    'completion-only application gets canonical complete request');
$engine->input("GET /one HTTP/1.1\r\nHost: example.test\r\n\r\n"
    . "GET /two HTTP/1.1\r\nHost: example.test\r\n\r\n");
is_deeply(\@seen,
    [ ['/body', 'abc', 1, 0], ['/one', '', 1, 0], ['/two', '', 1, 0] ],
    'pipelined completed callbacks run once per request');
is(scalar(() = $host->{output} =~ /HTTP\/1\.1 200 OK\r\n/g), 3,
    'all three responses sent via framework-neutral transport');
ok(!$host->{aborted}, 'attached host was not aborted');

my @headers;
my $early = Unblock::HTTP::Server->new(
    http1 => {},
    on_headers => sub { push @headers, $_[1]->target },
    on_request => sub { $_[0]->respond(status => 200, body => '') },
);
my $early_host = Local::CompletionHost->new;
my $early_engine = $early->attach_stream(transport => $early_host);
$early_engine->input("GET /early HTTP/1.1\r\nHost: example.test\r\n\r\n");
is_deeply(\@headers, ['/early'],
    'explicit early header callback remains installed and fires');

done_testing;
