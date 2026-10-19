package H3Profile::Summary;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(summarize_trials);

sub _median {
    my (@values) = sort { $a <=> $b } @_;
    my $n = @values;
    die "no values for median\n" unless $n;
    return $n % 2 ? $values[int($n / 2)]
        : ($values[$n / 2 - 1] + $values[$n / 2]) / 2;
}

# Only completed, client-only observations belong here. Comparing
# round-paired elapsed times keeps trial ordering visible rather than
# confusing a ratio of two separate medians with a typical paired ratio.
sub summarize_trials {
    my ($trials, $rounds) = @_;
    die "expected array of trials\n" unless ref($trials) eq 'ARRAY';
    die "rounds must be a positive integer\n"
        unless defined($rounds) && $rounds =~ /\A[1-9][0-9]*\z/;
    my %by_round;
    for my $trial (@$trials) {
        die "expected trial hash\n" unless ref($trial) eq 'HASH';
        my ($round, $mode) = @{$trial}{qw(round mode)};
        die "invalid round\n"
            unless defined($round) && $round =~ /\A[1-9][0-9]*\z/
                && $round <= $rounds;
        die "invalid mode\n"
            unless defined($mode) && ($mode eq 'direct' || $mode eq 'unified');
        die "duplicate trial for round and mode\n"
            if exists $by_round{$round}{$mode};
        for my $metric (qw(elapsed cpu call_us p50 p95 p99)) {
            die "invalid or missing $metric for round $round $mode\n"
                unless defined($trial->{$metric})
                    && $trial->{$metric} =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
                    && ($metric eq 'elapsed'
                        ? $trial->{$metric} > 0
                        : $trial->{$metric} >= 0);
        }
        $by_round{$round}{$mode} = $trial;
    }

    my @paired;
    for my $round (1 .. $rounds) {
        my ($direct, $unified) =
            @{$by_round{$round}}{qw(direct unified)};
        die "missing direct or unified trial for round $round\n"
            unless $direct && $unified;
        push @paired, {
            round => $round,
            direct_wall_s => 0 + $direct->{elapsed},
            unified_wall_s => 0 + $unified->{elapsed},
            wall_ratio => $unified->{elapsed} / $direct->{elapsed},
            cpu_ratio => $direct->{cpu} > 0
                ? $unified->{cpu} / $direct->{cpu} : undef,
            request_delta_us => $unified->{call_us} - $direct->{call_us},
            p50_delta_us => $unified->{p50} - $direct->{p50},
            p95_delta_us => $unified->{p95} - $direct->{p95},
            p99_delta_us => $unified->{p99} - $direct->{p99},
        };
    }
    my @cpu_ratios = map { $_->{cpu_ratio} }
        grep { defined $_->{cpu_ratio} } @paired;
    return {
        paired => \@paired,
        median_paired_wall_ratio => _median(map { $_->{wall_ratio} } @paired),
        median_paired_cpu_ratio => @cpu_ratios
            ? _median(@cpu_ratios) : undef,
        median_request_delta_us => _median(map { $_->{request_delta_us} } @paired),
        min_paired_wall_ratio => (sort { $a <=> $b }
            map { $_->{wall_ratio} } @paired)[0],
        max_paired_wall_ratio => (sort { $b <=> $a }
            map { $_->{wall_ratio} } @paired)[0],
    };
}

1;
