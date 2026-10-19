use strict;
use warnings;
use Test::More;
plan skip_all => "profiling script requires Perl 5.36+" if $] < 5.036;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bench',
    'h3-profile-sweep.pl');
my $base = tempdir(CLEANUP => 1);
my $unused = File::Spec->catdir($base, 'never-created');
sub dry_run {
    my (@option) = @_;
    open my $fh, '-|', $^X, $script, '--dry-run', @option, $unused
        or die "cannot launch sweep dry-run: $!";
    my @lines = <$fh>;
    close $fh;
    my $status = $?;
    return ($status, [grep { !/^#/ } @lines], \@lines);
}

my ($status, $cases, $lines) = dry_run();
is($status, 0, 'default schedule succeeds');
is(scalar(@$cases), 20, '10 workload pairs, two URL patterns each');
my %seen;
for my $line (@$cases) {
    my ($id, $inflight, $body, $url_mode) = split /\s+/, $line;
    $seen{"$inflight:$body:$url_mode"}++;
    like($id, qr/^c(?:01|08|16|32)-b(?:1024|4096-16384|65536)-(?:cycled|unique)$/,
        'safe deterministic scenario identifier');
}
is(scalar(keys %seen), 20, 'no duplicate or missing scenario');
for my $body ('1024', '4096,16384', '65536') {
    for my $inflight ($body eq '65536' ? (1, 8) : (1, 8, 16, 32)) {
        for my $mode (qw(cycled unique)) {
            is($seen{"$inflight:$body:$mode"}, 1,
                "exactly one $body $inflight $mode case");
        }
    }
}
for (my $i = 0; $i < @$cases; $i += 2) {
    my @a = split /\s+/, $cases->[$i];
    my @b = split /\s+/, $cases->[$i + 1];
    is("$a[1]:$a[2]", "$b[1]:$b[2]", 'URL patterns remain adjacent');
    is("$a[3]:$b[3]", 'cycled:unique', 'default pair order is fixed');
}
my (undef, $rotated) = dry_run('--rotate=9', '--swap-url-order');
like($rotated->[0], qr/^c08-b65536-unique /,
    'rotation advances by a whole scenario pair');
like($rotated->[1], qr/^c08-b65536-cycled /,
    'URL order can reverse while pair stays together');
like($rotated->[2], qr/^c01-b1024-unique /,
    'rotation wraps deterministically');
my ($one_status, $one) = dry_run('--only=c08-b65536-unique');
is($one_status, 0, 'one scenario can be selected for real-QUIC smoke');
is(scalar(@$one), 1, 'only option runs one case');
like($one->[0], qr/^c08-b65536-unique /, 'only selects the exact ID');
ok(!-e $unused, 'dry-run leaves no artifact directory');

for my $bad (['--rotate=10'], ['--rounds=0'],
    ['--samples=0'], ['--only=bogus']) {
    my ($bad_status) = dry_run(@$bad);
    isnt($bad_status, 0, 'invalid sweep options rejected');
}
done_testing;
