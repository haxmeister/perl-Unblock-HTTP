use strict;
use warnings;
use Test::More;
plan skip_all => 'benchmark comparator requires Perl 5.36+'
    if $] < 5.036;
use FindBin;
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP ();
use lib "$FindBin::Bin/../bench/lib";
use H3Profile::Summary qw(summarize_trials);

sub write_json {
    my ($path, $value) = @_;
    open my $fh, '>', $path or die $!;
    print {$fh} JSON::PP->new->encode($value);
    close $fh;
}
my $base = tempdir(CLEANUP => 1);
my $a = "$base/a"; my $b = "$base/b";
mkdir $a or die $!; mkdir $b or die $!;
my $id = 'c08-b4096-16384-unique';
sub fixture {
    my ($dir, $unified_wall, %change) = @_;
    my @trials;
    for my $round (1..3) {
        for my $mode (qw(direct unified)) {
            my $wall = $mode eq 'direct' ? 1 : $unified_wall;
            push @trials, {
                round => $round, mode => $mode,
                elapsed => $wall, cpu => $wall,
                call_us => $mode eq 'direct' ? 100 : 130,
                p50 => 100, p95 => $mode eq 'direct' ? 900 : 1000,
                p99 => $mode eq 'direct' ? 1900 : 2000,
                private_start => 1000, private_end => 1020,
            };
        }
    }
    my $sum = summarize_trials(\@trials, 3);
    $sum->{median_paired_wall_ratio} = 99 if $change{bad_median};
    write_json(File::Spec->catfile($dir, "$id.json"), {
        schema_version => 1,
        workload => {
            samples => 20, warmup => 8, rounds => 3,
            inflight => 8, url_mode => 'unique',
            response_bytes => [4096, 16384],
        },
        trials => \@trials, summary => $sum,
    });
    write_json(File::Spec->catfile($dir, 'sweep.json'), {
        schema_version => 1,
        complete => $change{incomplete}
            ? JSON::PP::false : JSON::PP::true,
        host => {
            perl => '5.040', archname => 'linux', cpu_model =>
                $change{cpu_model} || 'synthetic',
            cpu_governor => 'performance',
            upper_commit => 'same', net_quic_version => '0.05',
            uname => ['Linux', 'node', '6.12', 'build', 'x86_64'],
        },
        workload => {samples => 20, warmup => 8, rounds => 3},
        cases => [{
            id => $id, json => "$id.json", done => JSON::PP::true,
            inflight => 8, url_mode => 'unique',
            response_bytes => '4096,16384',
        }],
    });
}
fixture($a, 1.10); fixture($b, 0.95);
my $script = File::Spec->catfile($FindBin::Bin, '..', 'bench',
    'h3-compare-sweeps.pl');
sub run_compare {
    my $result = qx{$^X $script $a $b 2>&1};
    return ($?, $result);
}
my ($exit, $out) = run_compare();
is($exit, 0, 'comparison succeeds for matching completed sweeps');
like($out, qr/reversed=yes/, 'direction change visible');
like($out, qr/setup_delta_us=30\.00\/30\.00/,
    'separate synchronous request delta reported');
like($out, qr/p95_delta_us=100\.0\/100\.0/,
    'per-round tail latency differences compared');
like($out, qr/private_delta_kib=20\/20/,
    'within-process private-memory delta compared');
fixture($b, 1.05, cpu_model => 'different');
($exit, $out) = run_compare();
isnt($exit, 0, 'mismatched host rejected');
like($out, qr/incompatible host cpu_model/, 'clear host mismatch');
fixture($b, 1.05, incomplete => 1);
($exit, $out) = run_compare();
isnt($exit, 0, 'unfinished sweep rejected');
like($out, qr/incomplete sweep/, 'clear incomplete error');
fixture($b, 1.05, bad_median => 1);
($exit, $out) = run_compare();
isnt($exit, 0, 'corrupt saved summary rejected');
like($out, qr/corrupt saved profile summary/,
    'clear corrupted summary error');
done_testing;
