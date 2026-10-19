use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../bench/lib";
use H3Profile::Summary qw(summarize_trials);

sub trial {
    my ($round, $mode, $elapsed, $cpu, $call_us) = @_;
    return {
        round => $round, mode => $mode, elapsed => $elapsed,
        cpu => $cpu, call_us => $call_us,
        p50 => 100, p95 => 300, p99 => 700,
    };
}

# Deliberately shuffled completion-order input, without changing round
# pairing. The ratio of separate medians is 1, while the median of the
# paired ratios is 1.1; these are different statistical statements.
my @trials = (
    trial(3, 'unified', 22, 11, 80),
    trial(1, 'direct',   2,  2, 50),
    trial(2, 'unified', 10,  8, 60),
    trial(3, 'direct',  20, 10, 70),
    trial(1, 'unified',  3,  3, 75),
    trial(2, 'direct',  10,  8, 65),
);
my $summary = summarize_trials(\@trials, 3);
is(scalar(@{$summary->{paired}}), 3, 'three paired rounds');
is_deeply([map { $_->{round} } @{$summary->{paired}}],
    [1, 2, 3], 'paired in declared round order');
cmp_ok(abs($summary->{median_paired_wall_ratio} - 1.1),
    '<', 0.00001, 'paired median ratio is not ratio of separate medians');
cmp_ok(abs($summary->{min_paired_wall_ratio} - 1), '<', 0.00001,
    'minimum pair ratio');
cmp_ok(abs($summary->{max_paired_wall_ratio} - 1.5), '<', 0.00001,
    'maximum pair ratio');
cmp_ok(abs($summary->{median_request_delta_us} - 10),
    '<', 0.00001, 'request cost differences are paired');
cmp_ok(abs($summary->{median_paired_cpu_ratio} - 1.1),
    '<', 0.00001, 'client CPU ratios are paired');

my $zero_cpu = summarize_trials([
    trial(1, 'direct', 1, 0, 1),
    trial(1, 'unified', 2, 0, 2),
], 1);
ok(!defined $zero_cpu->{paired}[0]{cpu_ratio},
    'zero direct CPU is reported as missing ratio, not divided by zero');

for my $bad (
    [ [@trials, $trials[0]], 3, qr/duplicate/ ],
    [ [@trials[0 .. 4]], 3, qr/missing/ ],
    [ [trial(1, 'direct', 0, 1, 2), trial(1, 'unified', 1, 1, 2)],
        1, qr/invalid or missing elapsed/ ],
    [ [trial(4, 'direct', 1, 1, 2)], 3, qr/invalid round/ ],
) {
    my ($input, $rounds, $pattern) = @$bad;
    my $ok = eval { summarize_trials($input, $rounds); 1 };
    ok(!$ok && $@ =~ $pattern, "reject malformed or unmatched trials");
}

done_testing;
