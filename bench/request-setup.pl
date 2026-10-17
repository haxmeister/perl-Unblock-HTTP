use strict;
use warnings;
use Time::HiRes qw(time);
use URI;
use Uniform::HTTP::Request;

# Pure user-space setup comparison. It is NOT a full request benchmark:
# it omits sockets, callbacks, protocol engines, pooling and event loops.
my ($iterations, $rounds) = @ARGV;
$iterations = 20000 unless defined $iterations;
$rounds = 3 unless defined $rounds;
die "usage: perl bench/request-setup.pl [iterations>0] [rounds>0]\n"
    unless $iterations =~ /\A[1-9][0-9]*\z/
        && $rounds =~ /\A[1-9][0-9]*\z/
        && $iterations <= 1000000 && $rounds <= 25;

my $url = 'http://localhost/ping';
my $sink = 0;
my %case = (
    uniform_only => sub {
        my $request = Uniform::HTTP::Request->new(
            method => 'GET', scheme => 'http',
            authority => 'localhost', target => '/ping',
        );
        $sink += length($request->target);
    },
    uri_only => sub {
        my $uri = URI->new($url);
        my $scheme = lc($uri->scheme || '');
        die 'bad scheme' unless $scheme eq 'http' || $scheme eq 'https';
        die 'bad userinfo/fragment'
            if defined($uri->userinfo) || defined($uri->fragment);
        my ($host, $port) = ($uri->host, $uri->port);
        die 'bad host or port'
            unless defined($host) && length($host)
                && defined($port) && $port =~ /\A[0-9]+\z/
                && $port > 0 && $port <= 65535;
        my $authority = $uri->authority;
        my $target = $uri->path_query;
        $target = '/' unless defined($target) && length($target);
        $target = '/' . $target if substr($target, 0, 1) eq '?';
        $sink += length($target) + length($authority);
    },
    uri_and_uniform => sub {
        my $uri = URI->new($url);
        my $scheme = lc($uri->scheme || '');
        die 'bad scheme' unless $scheme eq 'http' || $scheme eq 'https';
        die 'bad userinfo/fragment'
            if defined($uri->userinfo) || defined($uri->fragment);
        my ($host, $port) = ($uri->host, $uri->port);
        die 'bad host or port'
            unless defined($host) && length($host)
                && defined($port) && $port =~ /\A[0-9]+\z/
                && $port > 0 && $port <= 65535;
        my $authority = $uri->authority;
        my $target = $uri->path_query;
        $target = '/' unless defined($target) && length($target);
        $target = '/' . $target if substr($target, 0, 1) eq '?';
        my $request = Uniform::HTTP::Request->new(
            method => 'GET', scheme => $scheme,
            authority => $authority, target => $target,
        );
        $sink += length($request->target);
    },
);

print "# Request setup microbenchmark, no transport, parser or pool scheduler.\n";
print "# All three paths do real work; order rotates each round.\n";
my @names = qw(uniform_only uri_only uri_and_uniform);
my %samples;
for my $round (1 .. $rounds) {
    my @order = (@names[$round % 3 .. 2], @names[0 .. ($round % 3) - 1]);
    for my $name (@order) {
        my $f = $case{$name};
        $f->() for 1 .. 500;
        my $start = time();
        $f->() for 1 .. $iterations;
        my $elapsed = time() - $start;
        push @{ $samples{$name} }, 1_000_000 * $elapsed / $iterations;
        printf "%-15s round=%d %.3f us/operation\n",
            $name, $round, $samples{$name}[-1];
    }
}
for my $name (@names) {
    my @v = sort { $a <=> $b } @{ $samples{$name} };
    printf "# %-15s median %.3f us/operation\n",
        $name, $v[int(@v / 2)];
}
die 'benchmark work unexpectedly missing' unless $sink > 0;
